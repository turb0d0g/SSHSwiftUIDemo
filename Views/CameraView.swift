//
//  CameraView.swift
//  SSHSwiftUIDemo
//
//  Rewritten: 2025-12-24 — Apple Camera-style overlay + pull-up ffmpeg/frames diagnostics
//

//
//  CameraView.swift
//  SSHSwiftUIDemo
//
//  Rewritten: 2025-12-24
//  Updated: 2026-03-06 — title triple-tap debug sheet + timestamp triple-tap night vision
//  Updated: 2026-03-06 — debug sheet shows HLS status + ffmpeg ring log
//  Updated: 2026-03-09 — renamed diagnostics types to avoid ambiguous type lookup
//

import SwiftUI
import AVKit
import UIKit

public struct CameraView: View {

    // MARK: - Inputs

    let device: Device

    // MARK: - VM

    @StateObject private var vm: CameraStreamViewModel

    // MARK: - Clock

    @State private var now: Date = Date()
    private let clock = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    // MARK: - Shutter flash / pulse

    @State private var shutterFlashOpacity: CGFloat = 0.0
    @State private var shutterPulse: Bool = false

    // MARK: - Hidden Night Vision

    @State private var nightVisionEnabled: Bool = false
    @State private var nvToastOpacity: CGFloat = 0.0

    // MARK: - Stream liveness spinner

    @State private var isStreamLive: Bool = false
    @State private var timeControlStatus: AVPlayer.TimeControlStatus = .paused
    @State private var playerObserver: PlayerLivenessObserver?

    // MARK: - Hidden debug sheet

    @State private var showDiagnosticsSheet: Bool = false

    // MARK: - Init

    init(device: Device) {
        self.device = device
        _vm = StateObject(wrappedValue: CameraStreamViewModel(host: device.host))
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            previewLayer
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topOverlay
                Spacer()
                bottomTray
            }
            .ignoresSafeArea(edges: [.bottom])

            Color.white
                .opacity(shutterFlashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack {
                Text(nightVisionEnabled ? "Hollywood Night-Vision: ON" : "Hollywood Night-Vision: OFF")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.quaternary, lineWidth: 0.5))
                    .opacity(nvToastOpacity)
                    .padding(.top, 18)

                Spacer()
            }
            .allowsHitTesting(false)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                titleBar
            }
        }
        .sheet(isPresented: $showDiagnosticsSheet) {
            CameraDiagnosticsSheet(
                host: device.host,
                deviceName: device.name.isEmpty ? device.host : device.name
            )
        }
        .onReceive(clock) { t in
            now = t
        }
        .task {
            await vm.appear(config: .init())
            attachPlayerObserverIfNeeded(reason: "task/appear")
        }
        .onChange(of: vm.player) { _ in
            attachPlayerObserverIfNeeded(reason: "player_changed")
        }
        .onDisappear {
            vm.disappear()
            detachPlayerObserver(reason: "onDisappear")
        }
    }

    // MARK: - Title Bar

    private var titleBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.aperture")
            Text("Camera")
                .font(.headline)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 3) {
            print("[CameraView] title triple-tap -> show diagnostics sheet")
            showDiagnosticsSheet = true
        }
        .accessibilityHint("Triple tap to open camera diagnostics")
    }

    // MARK: - Preview

    private var previewLayer: some View {
        ZStack {
            Color.black

            if let player = vm.player {
                VideoPlayer(player: player)
                    .modifier(LiveNightVisionModifier(enabled: nightVisionEnabled))
                    .onAppear {
                        attachPlayerObserverIfNeeded(reason: "VideoPlayer.onAppear")
                    }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)

                    Text("Starting stream…")
                        .foregroundStyle(.white.opacity(0.75))
                        .font(.caption)
                }
            }

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.black.opacity(0.55), .clear, .black.opacity(0.65)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .blendMode(.multiply)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Top Overlay

    private var topOverlay: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name.isEmpty ? device.host : device.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let status = vm.status {
                        Text(status.text)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    } else {
                        Text(" ")
                            .font(.caption2)
                    }
                }

                Spacer()

                timestampBlock
                    .contentShape(Rectangle())
                    .onTapGesture(count: 3) {
                        toggleNightVision()
                    }

                Group {
                    if vm.player != nil {
                        if isStreamLive || timeControlStatus == .waitingToPlayAtSpecifiedRate {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                                .scaleEffect(0.9)
                        } else {
                            Image(systemName: "circle.dotted")
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            if vm.isRecording {
                HStack {
                    RecBadge(elapsed: format(vm.recordingElapsed))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var timestampBlock: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(now.formatted(date: .abbreviated, time: .omitted))
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Text(now.formatted(date: .omitted, time: .standard))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white.opacity(0.92))
        .monospacedDigit()
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Bottom Tray

    private var bottomTray: some View {
        VStack(spacing: 14) {
            modeStrip
                .padding(.top, 10)

            HStack {
                Spacer()

                Button {
                    shutterWithHapticsAndFlash()
                } label: {
                    ShutterButton(
                        kind: vm.mode == .photo
                            ? .photo
                            : (vm.isRecording ? .videoStop : .videoStart),
                        pulsing: shutterPulse
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    vm.mode == .photo
                        ? "Take Snapshot"
                        : (vm.isRecording ? "Stop Recording" : "Start Recording")
                )

                Spacer()
            }
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private var modeStrip: some View {
        HStack(spacing: 18) {
            modeItem("VIDEO", active: vm.mode == .video) {
                vm.setMode(.video)
            }

            modeItem("PHOTO", active: vm.mode == .photo) {
                vm.setMode(.photo)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 14)
        .background(Capsule().fill(Color.white.opacity(0.10)))
        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
        .foregroundStyle(.white)
    }

    private func modeItem(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .opacity(active ? 1.0 : 0.55)
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background(Capsule().fill(active ? Color.yellow.opacity(0.18) : .clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func shutterWithHapticsAndFlash() {
        let impact = UIImpactFeedbackGenerator(style: .rigid)
        impact.prepare()
        impact.impactOccurred(intensity: 0.95)

        shutterPulse = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            shutterPulse = false
        }

        Task { @MainActor in
            await shutterFlash()
            vm.shutter()
        }
    }

    @MainActor
    private func shutterFlash() async {
        withAnimation(.easeOut(duration: 0.04)) {
            shutterFlashOpacity = 0.88
        }

        try? await Task.sleep(nanoseconds: 55_000_000)

        withAnimation(.easeOut(duration: 0.18)) {
            shutterFlashOpacity = 0.0
        }
    }

    private func toggleNightVision() {
        nightVisionEnabled.toggle()

        let soft = UIImpactFeedbackGenerator(style: .soft)
        soft.prepare()
        soft.impactOccurred(intensity: 0.75)

        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.14)) {
                nvToastOpacity = 1.0
            }

            try? await Task.sleep(nanoseconds: 900_000_000)

            withAnimation(.easeOut(duration: 0.22)) {
                nvToastOpacity = 0.0
            }
        }

        print("[CameraView] nightVisionEnabled=\(nightVisionEnabled)")
    }

    // MARK: - Player liveness

    private func attachPlayerObserverIfNeeded(reason: String) {
        guard let player = vm.player else { return }
        if playerObserver?.player === player { return }

        detachPlayerObserver(reason: "reattach/\(reason)")
        print("[CameraView] attachPlayerObserver reason=\(reason)")

        playerObserver = PlayerLivenessObserver(player: player) { live, status in
            self.isStreamLive = live
            self.timeControlStatus = status
        }
    }

    private func detachPlayerObserver(reason: String) {
        if playerObserver != nil {
            print("[CameraView] detachPlayerObserver reason=\(reason)")
        }

        playerObserver?.invalidate()
        playerObserver = nil
        isStreamLive = false
        timeControlStatus = .paused
    }

    // MARK: - Helpers

    private func format(_ t: TimeInterval) -> String {
        let total = Int(t)
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Combined Diagnostics Sheet

private struct CameraDiagnosticsSheet: View {
    let host: String
    let deviceName: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm: CameraDebugSheetViewModel

    init(host: String, deviceName: String) {
        self.host = host
        self.deviceName = deviceName
        _vm = StateObject(wrappedValue: CameraDebugSheetViewModel(host: host))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headerCard
                    hlsHealthCard
                    ffmpegLogCard
                }
                .padding(14)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Camera Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await vm.refreshAll() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(vm.isRefreshing)
                }
            }
            .task {
                await vm.refreshAll()
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(deviceName)
                .font(.headline)

            Text(host)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                pill("HLS \(vm.hlsHealth.uppercased())", color: vm.hlsHealthColor)
                pill(vm.ffmpegExists ? "FFMPEG LOG PRESENT" : "NO FFMPEG LOG", color: vm.ffmpegExists ? .green : .orange)

                if vm.isRefreshing {
                    ProgressView()
                        .scaleEffect(0.85)
                        .padding(.leading, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var hlsHealthCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HLS Health")
                .font(.headline)

            if let error = vm.hlsError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    pill(vm.hlsPlaylistExists ? "PLAYLIST YES" : "PLAYLIST NO", color: vm.hlsPlaylistExists ? .green : .orange)
                    pill(vm.hlsPlaylistHTTP ? "HTTP 200" : "HTTP FAIL", color: vm.hlsPlaylistHTTP ? .green : .orange)
                    pill("SEGMENTS \(vm.hlsSegmentCount)", color: vm.hlsSegmentCount > 0 ? .green : .orange)
                }

                HStack(spacing: 8) {
                    pill("RECENT ON DISK \(vm.hlsRecentExistCount)/\(vm.hlsRecentSegmentCount)", color: vm.hlsRecentAllExist ? .green : .orange)
                    pill("RECENT HTTP \(vm.hlsRecentHTTPCount)/\(vm.hlsRecentSegmentCount)", color: vm.hlsRecentAllHTTP ? .green : .orange)
                }

                if let age = vm.hlsPlaylistAge {
                    metricRow("Playlist age", "\(age)s")
                }

                if let latest = vm.hlsLatestSegment, !latest.isEmpty {
                    metricRow("Latest segment", latest)
                }

                if let age = vm.hlsLatestSegmentAge {
                    metricRow("Latest segment age", "\(age)s")
                }

                if let size = vm.hlsLatestSegmentSize {
                    metricRow("Latest segment size", byteString(size))
                }

                if !vm.hlsRecentSegments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recent playlist segments")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(vm.hlsRecentSegments, id: \.self) { segment in
                            Text(segment)
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var ffmpegLogCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FFmpeg Ring Log")
                .font(.headline)

            HStack(spacing: 10) {
                Picker("Lines", selection: $vm.ffmpegRequestedLines) {
                    Text("40").tag(40)
                    Text("80").tag(80)
                    Text("120").tag(120)
                    Text("200").tag(200)
                }
                .pickerStyle(.segmented)
                .onChange(of: vm.ffmpegRequestedLines) { _ in
                    Task { await vm.refreshFFmpeg() }
                }
            }

            if let error = vm.ffmpegError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                pill(vm.ffmpegExists ? "LOG YES" : "LOG NO", color: vm.ffmpegExists ? .green : .orange)

                if let age = vm.ffmpegAgeSeconds {
                    pill("AGE \(age)s", color: age < 20 ? .green : .orange)
                }

                if let size = vm.ffmpegSizeBytes {
                    pill(byteString(size), color: .blue)
                }

                pill("LINES \(vm.ffmpegLines.count)", color: .blue)
            }

            if vm.ffmpegLines.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.page.slash")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)

                    Text("No ffmpeg log lines yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(vm.ffmpegLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 260, maxHeight: 420)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func pill(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.16), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(color.opacity(0.40), lineWidth: 0.8)
            )
    }

    private func metricRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 132, alignment: .leading)

            Text(value)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Diagnostics Sheet ViewModel

@MainActor
private final class CameraDebugSheetViewModel: ObservableObject {
    @Published var isRefreshing: Bool = false

    // HLS
    @Published var hlsHealth: String = "unknown"
    @Published var hlsPlaylistExists: Bool = false
    @Published var hlsPlaylistHTTP: Bool = false
    @Published var hlsPlaylistAge: Int?
    @Published var hlsSegmentCount: Int = 0
    @Published var hlsLatestSegment: String?
    @Published var hlsLatestSegmentAge: Int?
    @Published var hlsLatestSegmentSize: Int?
    @Published var hlsRecentSegments: [String] = []
    @Published var hlsRecentSegmentCount: Int = 0
    @Published var hlsRecentExistCount: Int = 0
    @Published var hlsRecentHTTPCount: Int = 0
    @Published var hlsRecentAllExist: Bool = false
    @Published var hlsRecentAllHTTP: Bool = false
    @Published var hlsError: String?

    // FFmpeg
    @Published var ffmpegRequestedLines: Int = 80
    @Published var ffmpegExists: Bool = false
    @Published var ffmpegSizeBytes: Int?
    @Published var ffmpegAgeSeconds: Int?
    @Published var ffmpegLines: [String] = []
    @Published var ffmpegError: String?

    let host: String

    init(host: String) {
        self.host = host
    }

    var hlsHealthColor: Color {
        switch hlsHealth.lowercased() {
        case "good":
            return .green
        case "degraded":
            return .orange
        case "bad":
            return .red
        default:
            return .gray
        }
    }

    func refreshAll() async {
        isRefreshing = true
        async let hlsTask: Void = refreshHLS()
        async let ffmpegTask: Void = refreshFFmpeg()
        _ = await (hlsTask, ffmpegTask)
        isRefreshing = false
    }

    func refreshHLS() async {
        hlsError = nil

        let urlString = "http://\(host)/cgi-bin/status_hls_stream.cgi"
        print("[CameraDebugSheetViewModel] refreshHLS url=\(urlString)")

        guard let url = URL(string: urlString) else {
            hlsError = "Bad HLS status URL"
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw CameraDebugSheetError.invalidResponse("Non-HTTP HLS response")
            }

            print("[CameraDebugSheetViewModel] HLS status=\(http.statusCode) bytes=\(data.count)")

            guard (200...299).contains(http.statusCode) else {
                throw CameraDebugSheetError.invalidResponse("HLS HTTP \(http.statusCode)")
            }

            let decoded = try JSONDecoder().decode(CameraHLSStatusResponse.self, from: data)

            hlsHealth = decoded.hls?.health ?? decoded.status
            hlsPlaylistExists = decoded.hls?.playlistExists ?? false
            hlsPlaylistHTTP = decoded.hls?.playlistHTTPOk ?? false
            hlsPlaylistAge = decoded.hls?.playlistAgeSeconds
            hlsSegmentCount = decoded.hls?.segmentCount ?? 0
            hlsLatestSegment = decoded.hls?.latestSegment
            hlsLatestSegmentAge = decoded.hls?.latestSegmentAgeSeconds
            hlsLatestSegmentSize = decoded.hls?.latestSegmentSizeBytes
            hlsRecentSegments = decoded.hls?.playlistRecentSegments ?? []
            hlsRecentSegmentCount = decoded.hls?.playlistRecentSegmentCount ?? 0
            hlsRecentExistCount = decoded.hls?.playlistRecentSegmentsExistCount ?? 0
            hlsRecentHTTPCount = decoded.hls?.playlistRecentSegmentsHTTPCount ?? 0
            hlsRecentAllExist = decoded.hls?.playlistRecentSegmentsAllExist ?? false
            hlsRecentAllHTTP = decoded.hls?.playlistRecentSegmentsAllHTTPOk ?? false
        } catch {
            print("[CameraDebugSheetViewModel] refreshHLS failed error=\(error)")
            hlsError = error.localizedDescription
        }
    }

    func refreshFFmpeg() async {
        ffmpegError = nil

        let urlString = "http://\(host)/cgi-bin/ffmpeg_ring_status.cgi?lines=\(ffmpegRequestedLines)"
        print("[CameraDebugSheetViewModel] refreshFFmpeg url=\(urlString)")

        guard let url = URL(string: urlString) else {
            ffmpegError = "Bad ffmpeg debug URL"
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw CameraDebugSheetError.invalidResponse("Non-HTTP ffmpeg response")
            }

            print("[CameraDebugSheetViewModel] ffmpeg status=\(http.statusCode) bytes=\(data.count)")

            guard (200...299).contains(http.statusCode) else {
                throw CameraDebugSheetError.invalidResponse("FFmpeg HTTP \(http.statusCode)")
            }

            let decoded = try JSONDecoder().decode(CameraFFmpegRingResponse.self, from: data)

            ffmpegExists = decoded.exists
            ffmpegSizeBytes = decoded.sizeBytes
            ffmpegAgeSeconds = decoded.ageSeconds
            ffmpegLines = decoded.tail
        } catch {
            print("[CameraDebugSheetViewModel] refreshFFmpeg failed error=\(error)")
            ffmpegError = error.localizedDescription
            ffmpegExists = false
            ffmpegSizeBytes = nil
            ffmpegAgeSeconds = nil
            ffmpegLines = []
        }
    }
}

// MARK: - HLS Status Models

private struct CameraHLSStatusResponse: Decodable {
    let status: String
    let hls: HLSPayload?

    struct HLSPayload: Decodable {
        let health: String
        let playlistExists: Bool
        let playlistHTTPOk: Bool
        let playlistAgeSeconds: Int?
        let segmentCount: Int
        let latestSegment: String?
        let latestSegmentAgeSeconds: Int?
        let latestSegmentSizeBytes: Int?
        let playlistRecentSegments: [String]
        let playlistRecentSegmentCount: Int
        let playlistRecentSegmentsExistCount: Int
        let playlistRecentSegmentsHTTPCount: Int
        let playlistRecentSegmentsAllExist: Bool
        let playlistRecentSegmentsAllHTTPOk: Bool

        enum CodingKeys: String, CodingKey {
            case health
            case playlistExists = "playlist_exists"
            case playlistHTTPOk = "playlist_http_ok"
            case playlistAgeSeconds = "playlist_age_seconds"
            case segmentCount = "segment_count"
            case latestSegment = "latest_segment"
            case latestSegmentAgeSeconds = "latest_segment_age_seconds"
            case latestSegmentSizeBytes = "latest_segment_size_bytes"
            case playlistRecentSegments = "playlist_recent_segments"
            case playlistRecentSegmentCount = "playlist_recent_segment_count"
            case playlistRecentSegmentsExistCount = "playlist_recent_segments_exist_count"
            case playlistRecentSegmentsHTTPCount = "playlist_recent_segments_http_count"
            case playlistRecentSegmentsAllExist = "playlist_recent_segments_all_exist"
            case playlistRecentSegmentsAllHTTPOk = "playlist_recent_segments_all_http_ok"
        }
    }
}

// MARK: - FFmpeg Ring Response

private struct CameraFFmpegRingResponse: Decodable {
    let status: String
    let exists: Bool
    let sizeBytes: Int?
    let ageSeconds: Int?
    let requestedLines: Int?
    let lineCount: Int?
    let tail: [String]

    enum CodingKeys: String, CodingKey {
        case status
        case exists
        case sizeBytes = "size_bytes"
        case ageSeconds = "age_seconds"
        case requestedLines = "requested_lines"
        case lineCount = "line_count"
        case tail
    }
}

// MARK: - Errors

private enum CameraDebugSheetError: LocalizedError {
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let message):
            return message
        }
    }
}

// MARK: - Night Vision look

private struct LiveNightVisionModifier: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .saturation(0.22)
                .contrast(1.30)
                .brightness(0.06)
                .overlay(
                    Rectangle()
                        .fill(Color.green.opacity(0.16))
                        .blendMode(.screen)
                )
        } else {
            content
        }
    }
}

// MARK: - REC pill

private struct RecBadge: View {
    let elapsed: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)

            Text("REC • \(elapsed)")
                .font(.caption2)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.red.opacity(0.5), lineWidth: 0.5))
        .foregroundColor(.red)
    }
}

// MARK: - Shutter button

private enum ShutterKind {
    case photo
    case videoStart
    case videoStop
}

private struct ShutterButton: View {
    let kind: ShutterKind
    let pulsing: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(.white, lineWidth: 5)
                .frame(width: 86, height: 86)

            switch kind {
            case .photo:
                Circle()
                    .fill(.white.opacity(0.95))
                    .frame(width: 72, height: 72)

            case .videoStart:
                Circle()
                    .fill(Color.red)
                    .frame(width: 64, height: 64)

            case .videoStop:
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.red)
                    .frame(width: 54, height: 54)
            }
        }
        .scaleEffect(pulsing ? 0.94 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.62), value: pulsing)
        .contentShape(Rectangle())
    }
}

// MARK: - Player liveness observer

private final class PlayerLivenessObserver {
    let player: AVPlayer
    private var timeObserver: Any?
    private var kvo: NSKeyValueObservation?
    private var lastTime: CMTime = .zero
    private let onUpdate: (_ live: Bool, _ status: AVPlayer.TimeControlStatus) -> Void

    init(player: AVPlayer, onUpdate: @escaping (_ live: Bool, _ status: AVPlayer.TimeControlStatus) -> Void) {
        self.player = player
        self.onUpdate = onUpdate

        self.kvo = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.onUpdate(self.isProbablyLive(player), player.timeControlStatus)
            }
        }

        self.timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let advancing = time != self.lastTime
            self.lastTime = time
            self.onUpdate(advancing, player.timeControlStatus)
        }
    }

    func invalidate() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        kvo?.invalidate()
        kvo = nil
    }

    private func isProbablyLive(_ player: AVPlayer) -> Bool {
        player.rate > 0 && player.timeControlStatus != .paused
    }

    deinit {
        invalidate()
    }
}
