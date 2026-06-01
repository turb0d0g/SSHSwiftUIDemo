//
//  CameraStreamViewModel.swift
//  SSHSwiftUIDemo
//

//
//  CameraStreamViewModel.swift
//  SSHSwiftUIDemo
//

import Foundation
import AVFoundation
import SwiftUI
import UIKit
import OSLog
import Photos

@MainActor
final class CameraStreamViewModel: NSObject, ObservableObject {

    // MARK: - Types

    struct StatusMessage: Equatable {
        enum Level { case info, success, warning, error }
        let text: String
        let level: Level
    }

    enum Mode { case photo, video }

    private struct StopResp: Decodable {
        let ok: Bool
        let file: String?
        let url: String?
        let error: String?
    }

    // MARK: - Public

    let host: String
    
    private var arcToken: ARCTracker.Token?

    @Published private(set) var player: AVPlayer?
    @Published private(set) var hlsURL: URL?

    @Published var mode: Mode = .photo
    @Published var isRecording = false
    @Published var recordingElapsed: TimeInterval = 0
    @Published var status: StatusMessage?

    @Published private(set) var snapshotInFlight = false

    // MARK: - Private state

    private var itemStatusObserver: NSKeyValueObservation?
    private var timeObs: Any?

    private var recordingStart: Date?
    private var recordingTicker: Task<Void, Never>?
    private var statusClearTask: Task<Void, Never>?

    // latest-wins tasks
    private var appearTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var stopRecordTask: Task<Void, Never>?

    private let appearGate = LatestOnlyGate()
    private let applyGate = LatestOnlyGate()

    private let bp = Backpressure.heavy
    private let log = Logger(subsystem: "SSHSwiftUIDemo", category: "CameraStreamVM")

    // MARK: - Init

    init(host: String) {
        self.host = host
        super.init()

        let obj: AnyObject = self
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.arcToken = await ARCTracker.shared.registerToken(
                self,
                note: String(reflecting: type(of: self)),
                expectedLifetime: .transient
            )
        }

        log.debug("[CameraStreamVM] init host=\(self.host, privacy: .public)")
    }

    deinit {
        let token = arcToken
        print("[DEINIT] CameraStreamViewModel host=\(host)")
        print("[CameraStreamVM] deinit -> cancel tasks + best-effort stop stream")

        appearTask?.cancel()
        appearTask = nil
        applyTask?.cancel()
        applyTask = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        stopRecordTask?.cancel()
        stopRecordTask = nil
        recordingTicker?.cancel()
        recordingTicker = nil
        statusClearTask?.cancel()
        statusClearTask = nil

        if let token {
            Task {
                await ARCTracker.shared.unregister(token: token)
            }
        }

        Task.detached { [host] in
            _ = await CameraCGI.stopStream(host: host)
        }
    }

    private func tearDownPlayerState(reason: String) {
        if let player {
            player.pause()

            if let token = timeObs {
                player.removeTimeObserver(token)
                timeObs = nil
            }

            player.replaceCurrentItem(with: nil)
        }

        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        player = nil

        log.info("[CameraStreamVM] tearDownPlayerState reason=\(reason, privacy: .public)")
    }
    
    // MARK: - Lifecycle

    func appear(config: CameraStreamConfig) async {
        appearTask?.cancel()
        appearTask = Task { [weak self] in
            guard let self else { return }
            await self.appearGate.runLatest("camera.appear") {
                await self._appearLatest(config: config)
            }
        }
        await appearTask?.value
    }

    private func _appearLatest(config: CameraStreamConfig) async {
        let playlist = URL(string: "http://\(host)\(CameraCGI.publicPlaylistPath)")!
        hlsURL = playlist

        postStatus("Starting stream…", level: .info, autoClear: 1.2)

        let ok = await CameraCGI.startStream(host: host, config: config)
        guard ok else {
            postStatus("Stream start failed", level: .error, autoClear: 3.0)
            log.error("[CameraStreamVM] startStream failed host=\(self.host, privacy: .public)")
            return
        }

        do {
            try await bp.withPermit("CameraStreamVM.waitForHLS") {
                try await waitForHLSPlaylist(playlist, timeout: 7.0)
            }
        } catch {
            postStatus("HLS not ready", level: .error, autoClear: 3.0)
            log.error("[CameraStreamVM] HLS playlist not ready url=\(playlist.absoluteString, privacy: .public) err=\(String(describing: error), privacy: .public)")
            return
        }

        resetPlayerPipeline(reason: "appearLatest.prepare")
        preparePlayer(playlistURL: playlist, config: config)

        log.info("[CameraStreamVM] prepared AVPlayer url=\(playlist.absoluteString, privacy: .public) cfg=\(String(describing: config), privacy: .public)")
    }

    func applyStreamConfig(_ config: CameraStreamConfig) async {
        applyTask?.cancel()
        applyTask = Task { [weak self] in
            guard let self else { return }
            await self.applyGate.runLatest("camera.applyConfig") {
                await self._applyLatest(config)
            }
        }
        await applyTask?.value
    }

    private func _applyLatest(_ config: CameraStreamConfig) async {
        log.info("[CameraStreamVM] applyStreamConfig prores=\(config.proRes) dyn=\(config.dynamicRange.rawValue, privacy: .public) res=\(config.resolution.rawValue, privacy: .public) fps=\(config.fps)")
        postStatus("Applying stream settings…", level: .info, autoClear: 1.2)

        let ok = await CameraCGI.startStream(host: host, config: config)
        if ok {
            postStatus("Settings applied", level: .success, autoClear: 1.2)
        } else {
            postStatus("Apply failed", level: .error, autoClear: 2.2)
        }
    }

    func disappear() {
        appearTask?.cancel()
        appearTask = nil

        applyTask?.cancel()
        applyTask = nil

        snapshotTask?.cancel()
        snapshotTask = nil

        stopRecordTask?.cancel()
        stopRecordTask = nil

        recordingTicker?.cancel()
        recordingTicker = nil

        statusClearTask?.cancel()
        statusClearTask = nil

        isRecording = false
        recordingStart = nil
        recordingElapsed = 0

        tearDownPlayerState(reason: "disappear")

        Task.detached { [host] in
            _ = await CameraCGI.stopStream(host: host)
        }
    }

    // MARK: - Actions

    func setMode(_ m: Mode) {
        mode = m
        postStatus(m == .photo ? "Photo mode" : "Video mode", level: .info, autoClear: 1.4)
    }

    func shutter() {
        switch mode {
        case .photo:
            takeSnapshot()
        case .video:
            isRecording ? stopRecording() : startRecording()
        }
    }

    // MARK: - Snapshot

    private func takeSnapshot() {
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            await self._snapshotLatest()
        }
    }

    private func _snapshotLatest() async {
        snapshotInFlight = true
        defer { snapshotInFlight = false }

        log.debug("[CameraStreamVM] snapshot start")

        do {
            let image: UIImage? = try await bp.withPermit("CameraStreamVM.snapshot") {
                await CameraCGI.snapshot(host: host)
            }

            guard let image else {
                postStatus("Snapshot failed", level: .error, autoClear: 2.8)
                log.error("[CameraStreamVM] snapshot returned nil image")
                return
            }

            let data: Data = try await bp.withPermit("CameraStreamVM.snapshot.encode") {
                guard let d = image.jpegData(compressionQuality: 0.95) else {
                    throw CameraCGIError.decode
                }
                return d
            }

            let filename = MediaSaver.uniqueImageFilename()
            _ = try await MediaSaver.saveJPEGToDocumentsAndPhotos(data, filename: filename)

            postStatus("Saved: \(filename)", level: .success, autoClear: 2.2)
            log.info("[CameraStreamVM] snapshot saved \(filename, privacy: .public) bytes=\(data.count, privacy: .public)")
        } catch is CancellationError {
            log.debug("[CameraStreamVM] snapshot cancelled (latest-wins)")
        } catch {
            postStatus("Snapshot failed", level: .error, autoClear: 2.8)
            log.error("[CameraStreamVM] snapshot error: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Recording

    private func startRecording() {
        Task { [weak self] in
            guard let self else { return }

            let ok = await CameraCGI.startRecord(host: self.host)
            guard ok else {
                self.postStatus("Start recording failed", level: .error, autoClear: 3.0)
                self.log.error("[CameraStreamVM] startRecord failed")
                return
            }

            self.isRecording = true
            self.recordingStart = Date()
            self.recordingElapsed = 0
            self.postStatus("Recording…", level: .info, autoClear: nil)

            self.recordingTicker?.cancel()
            self.recordingTicker = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await MainActor.run {
                        if let start = self.recordingStart {
                            self.recordingElapsed = Date().timeIntervalSince(start)
                        }
                    }
                }
            }

            self.log.info("[CameraStreamVM] recording started")
        }
    }

    private func stopRecording() {
        stopRecordTask?.cancel()
        stopRecordTask = Task { [weak self] in
            guard let self else { return }
            await self._stopRecordingLatest()
        }
    }

    private func _stopRecordingLatest() async {
        do {
            let total = recordingElapsed
            postStatus("Finalizing…", level: .info, autoClear: nil)

            let (remoteURL, serverFileName) = try await bp.withPermit("CameraStreamVM.stopOnServer") {
                try await stopOnServerAndGetURL()
            }

            let stageID = UUID().uuidString.prefix(6)
            log.debug("[CameraStreamVM] [\(stageID)] download \(remoteURL.absoluteString, privacy: .public)")

            let (tempURL, httpResp) = try await bp.withPermit("CameraStreamVM.download") {
                try await URLSession.shared.download(from: remoteURL)
            }

            guard let http = httpResp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }

            let finalName = serverFileName ?? remoteURL.lastPathComponent
            let stage = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(finalName)
            try? FileManager.default.removeItem(at: stage)
            try FileManager.default.moveItem(at: tempURL, to: stage)

            log.info("[CameraStreamVM] [\(stageID)] download ok -> \(stage.path, privacy: .public)")

            _ = try await bp.withPermit("CameraStreamVM.saveVideo") {
                try await MediaSaver.saveVideoFileToDocumentsAndPhotos(from: stage, filename: finalName)
            }

            isRecording = false
            recordingTicker?.cancel()
            recordingTicker = nil
            recordingStart = nil
            recordingElapsed = 0

            postStatus("Recording saved: \(finalName) (\(format(total)))", level: .success, autoClear: 2.6)
            log.info("[CameraStreamVM] recording stopped; saved \(finalName, privacy: .public) duration=\(total, privacy: .public)")
        } catch is CancellationError {
            log.debug("[CameraStreamVM] stopRecording cancelled (latest-wins)")
        } catch {
            isRecording = false
            recordingTicker?.cancel()
            recordingTicker = nil
            postStatus("Stop/save failed", level: .error, autoClear: 3.0)
            log.error("[CameraStreamVM] stopRecording error: \(String(describing: error), privacy: .public)")
        }
    }

    private func stopOnServerAndGetURL() async throws -> (URL, String?) {
        guard let stopURL = URL(string: "http://\(host)/cgi-bin/stop_hls_recording.cgi") else {
            throw URLError(.badURL)
        }

        var req = URLRequest(url: stopURL, timeoutInterval: 30)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let parsed = try parseStopResponse(data)

        guard parsed.ok else {
            throw NSError(
                domain: "StopRecording",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: parsed.error ?? "stop failed"]
            )
        }

        if let rel = parsed.url, let abs = URL(string: "http://\(host)\(rel)") {
            return (abs, URL(string: rel)?.lastPathComponent)
        } else if let file = parsed.file {
            guard let abs = URL(string: "http://\(host)/hls/recordings/\(file)") else {
                throw URLError(.badURL)
            }
            return (abs, file)
        } else {
            throw NSError(
                domain: "StopRecording",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "missing file URL"]
            )
        }
    }

    private func parseStopResponse(_ data: Data) throws -> StopResp {
        if let obj = try? JSONDecoder().decode(StopResp.self, from: data) {
            return obj
        }

        guard let s = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "StopRecording",
                code: 100,
                userInfo: [NSLocalizedDescriptionKey: "non-utf8 response"]
            )
        }

        print("[CameraStreamVM][stop] raw body:")
        print(s)

        func capture(_ pattern: String, in text: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
            let ns = text as NSString
            guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges >= 2 else { return nil }
            var val = ns.substring(with: m.range(at: 1))
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 {
                val.removeFirst()
                val.removeLast()
            }
            return val.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let filePat = #"\"file\"\s*:\s*(\"[^\"]+\"|[^,\}\s]+)"#
        let urlPat  = #"\"url\"\s*:\s*(\"[^\"]+\"|[^,\}\s]+)"#

        let file = capture(filePat, in: s)
        let url = capture(urlPat, in: s)

        if file != nil || url != nil {
            return StopResp(ok: true, file: file, url: url, error: nil)
        }

        throw NSError(
            domain: "StopRecording",
            code: 101,
            userInfo: [NSLocalizedDescriptionKey: "invalid JSON: \(s.prefix(200))…"]
        )
    }

    // MARK: - Player

    private func preparePlayer(playlistURL: URL, config: CameraStreamConfig) {
        let item = AVPlayerItem(url: playlistURL)
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = false

        itemStatusObserver?.invalidate()
        itemStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                switch item.status {
                case .readyToPlay:
                    self.log.info("[CameraStreamVM] ready — calling play()")
                    self.player?.play()
                    self.postStatus("HLS online", level: .success, autoClear: 2.0)

                case .failed:
                    let msg = item.error?.localizedDescription ?? "Unknown AV error"
                    self.log.error("[CameraStreamVM] item failed: \(msg, privacy: .public)")
                    self.postStatus("Playback failed: \(msg)", level: .error, autoClear: 3.0)

                case .unknown:
                    self.log.debug("[CameraStreamVM] item status unknown")

                @unknown default:
                    self.log.debug("[CameraStreamVM] item status unknown default")
                }
            }
        }

        let interval = CMTime(seconds: 1.0, preferredTimescale: 600)
        timeObs = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.isRecording, let start = self.recordingStart {
                self.recordingElapsed = Date().timeIntervalSince(start)
            }
        }

        player = p
        log.info("[CameraStreamVM] player prepared url=\(playlistURL.absoluteString, privacy: .public) cfg=\(String(describing: config), privacy: .public)")
    }

    private func resetPlayerPipeline(reason: String) {
        tearDownPlayerState(reason: reason)

        log.info("[CameraStreamVM] resetPlayerPipeline reason=\(reason, privacy: .public)")
    }

    // MARK: - Status

    private func postStatus(_ text: String, level: StatusMessage.Level, autoClear seconds: TimeInterval?) {
        status = .init(text: text, level: level)
        statusClearTask?.cancel()

        if let seconds {
            statusClearTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                await MainActor.run {
                    self?.status = nil
                }
            }
        } else {
            statusClearTask = nil
        }
    }

    private func format(_ t: TimeInterval) -> String {
        let total = Int(t)
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - HLS readiness probe

    private func waitForHLSPlaylist(_ url: URL, timeout: TimeInterval) async throws {
        let start = Date()
        var attempt = 0
        let delays: [Double] = [0.15, 0.25, 0.40, 0.60, 0.90, 1.20, 1.50]

        while Date().timeIntervalSince(start) < timeout {
            try Task.checkCancellation()
            attempt += 1

            if await headOK(url) {
                log.debug("[CameraStreamVM] ✅ playlist ready attempt=\(attempt) url=\(url.absoluteString, privacy: .public)")
                return
            }

            let delay = delays[min(attempt - 1, delays.count - 1)]
            log.debug("[CameraStreamVM] ⏳ playlist not ready attempt=\(attempt) sleep=\(delay, privacy: .public)s url=\(url.absoluteString, privacy: .public)")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        struct HLSNotReady: Error {}
        throw HLSNotReady()
    }

    private func headOK(_ url: URL) async -> Bool {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 2.0
        req.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse {
                return (200...299).contains(http.statusCode)
            }
            return false
        } catch {
            return false
        }
    }
}

// MARK: - LatestOnlyGate

public actor LatestOnlyGate {
    private let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "Backpressure")
    private var running = false
    private var pending = false

    public init() {}

    public func runLatest(_ tag: String, _ work: @Sendable () async -> Void) async {
        if running {
            pending = true
            log.debug("[Latest] tag=\(tag, privacy: .public) -> marked pending")
            return
        }

        running = true
        defer { running = false }

        repeat {
            pending = false
            log.debug("[Latest] tag=\(tag, privacy: .public) -> run")
            await work()
        } while pending

        log.debug("[Latest] tag=\(tag, privacy: .public) -> idle")
    }
}
