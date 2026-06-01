//
//  RecordingStartResponse.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 9/26/25.
//

import Foundation
import OSLog
import Photos

public struct RecordingStartResponse: Decodable {
    public let ok: Bool
    public let base: String?
    public let message: String?
    public let error: String?
}

public struct RecordingStopResponse: Decodable {
    public let ok: Bool
    public let file: String?
    public let url: String?
    public let error: String?
}

public enum RecordingError: Error {
    case remote(String)
    case http(String)
    case photos(String)
    case badURL
}

public final class RecordingService {
    private let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "RecordingService")
    private let httpPort: Int?   // optional override (nil ⇒ 80)

    public init(httpPort: Int? = nil) {
        self.httpPort = httpPort
    }

    // MARK: - Public API

    @discardableResult
    func startRecording(on device: Device,
                        label: String = "capture",
                        width: Int = 1280,
                        height: Int = 720,
                        fps: Int = 30) async throws -> RecordingStartResponse {
        // NOTE: endpoint path aligned with your CGI name “…recording.cgi”
        let url = try endpoint(device, path: "/cgi-bin/start_hls_recording.cgi", query: [
            "label": String(label),
            "width": String(width),
            "height": String(height),
            "fps": String(fps),
        ])

        log.debug("[RecordingService] ▶️ startRecording url=\(url.absoluteString, privacy: .public)")
        print("[RecordingService] ▶️ startRecording url=\(url.absoluteString)")
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "GET"
        let (data, resp) = try await URLSession.shared.data(for: req)
        try validate(resp, fn: #function)
        let parsed = try decode(RecordingStartResponse.self, data: data)
        if !parsed.ok {
            let err = parsed.error ?? "unknown-error"
            log.error("[RecordingService] ❌ start failed error=\(err, privacy: .public)")
            print("[RecordingService] ❌ start failed error=\(err)")
            throw RecordingError.remote(err)
        }
        log.info("[RecordingService] ✅ start ok base=\(parsed.base ?? "-", privacy: .public)")
        print("[RecordingService] ✅ start ok base=\(parsed.base ?? "-")")
        return parsed
    }

    /// Stops server-side recording and returns the **public URL** to the file.
    @discardableResult
    func stopRecording(on device: Device) async throws -> (resp: RecordingStopResponse, fileURLOnServer: URL) {
        // NOTE: endpoint path aligned with your CGI name “…recording.cgi”
        let url = try endpoint(device, path: "/cgi-bin/stop_hls_recording.cgi")
        log.debug("[RecordingService] ⏹️ stopRecording url=\(url.absoluteString, privacy: .public)")
        print("[RecordingService] ⏹️ stopRecording url=\(url.absoluteString)")
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "GET"
        let (data, resp) = try await URLSession.shared.data(for: req)
        try validate(resp, fn: #function)

        let parsed = try decode(RecordingStopResponse.self, data: data)
        guard parsed.ok else {
            let err = parsed.error ?? "unknown-error"
            log.error("[RecordingService] ❌ stop failed error=\(err, privacy: .public)")
            print("[RecordingService] ❌ stop failed error=\(err)")
            throw RecordingError.remote(err)
        }

        // Prefer `url` (like "/hls/recordings/xxx.mp4"); fallback to `file` -> "/recordings/<file>"
        guard let rel = parsed.url ?? (parsed.file.map { "/hls/recordings/\($0)" }) else {
            log.error("[RecordingService] ❌ stop ok but missing url/file")
            throw RecordingError.remote("missing file url")
        }

        let fileURL = try endpoint(device, path: rel)
        log.info("[RecordingService] ✅ stop ok file=\(parsed.file ?? "-", privacy: .public) url=\(fileURL.absoluteString, privacy: .public)")
        print("[RecordingService] ✅ stop ok file=\(parsed.file ?? "-") url=\(fileURL.absoluteString)")
        return (parsed, fileURL)
    }

    /// Downloads the server-produced movie and persists it using **MediaSaver**.
    /// Returns the local Documents URL, Photos localIdentifier, and the final filename (shown in your UI banner).
    @discardableResult
    public func downloadAndSaveWithMediaSaver(_ remoteFileURL: URL) async throws
    -> (documentsURL: URL, localIdentifier: String, filename: String) {

        let logID = UUID().uuidString.prefix(8)
        log.debug("[RecordingService] ⬇️ [\(logID)] Download start \(remoteFileURL.absoluteString, privacy: .public)")
        print("[RecordingService] ⬇️ [\(logID)] Download start \(remoteFileURL.absoluteString)")

        // Stream to disk (download task avoids large in-memory buffers).
        let (tempURL, response) = try await URLSession.shared.download(from: remoteFileURL)
        try validate(response, fn: #function)

        // Choose a solid filename: prefer server name; fallback to a unique local name.
        let suggested = remoteFileURL.lastPathComponent.isEmpty
            ? MediaSaver.uniqueVideoFilename()
            : remoteFileURL.lastPathComponent

        // Move the temporary file to our own tmp path with the final name
        let stage = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(suggested)
        try? FileManager.default.removeItem(at: stage)
        try FileManager.default.moveItem(at: tempURL, to: stage)

        log.info("[RecordingService] ⬇️ [\(logID)] Download ok → \(stage.path, privacy: .public)")
        print("[RecordingService] ⬇️ [\(logID)] Download ok → \(stage.path)")

        // Hand off to MediaSaver for Documents/Photos persistence + validation
        let (docsURL, localID) = try await MediaSaver.saveVideoFileToDocumentsAndPhotos(from: stage, filename: suggested)

        log.info("[RecordingService] 📸 [\(logID)] Saved to Photos ok filename=\(suggested, privacy: .public)")
        print("[RecordingService] 📸 [\(logID)] Saved to Photos ok filename=\(suggested)")

        return (docsURL, localID, suggested)
    }

    // MARK: - Internals

    private func endpoint(_ device: Device, path: String, query: [String:String]? = nil) throws -> URL {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = device.host
        if let p = self.httpPort, p != 80 { comps.port = p }
        comps.path = path.hasPrefix("/") ? path : "/" + path
        if let q = query, !q.isEmpty {
            comps.queryItems = q.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw RecordingError.badURL }
        return url
    }

    private func decode<T: Decodable>(_ t: T.Type, data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let s = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            log.error("[RecordingService] 🧨 JSON decode failed \(String(describing: T.self), privacy: .public) body=\(s, privacy: .public)")
            print("[RecordingService] 🧨 JSON decode failed \(String(describing: T.self)) body=\(s)")
            throw error
        }
    }

    private func validate(_ resp: URLResponse, fn: StaticString) throws {
        guard let http = resp as? HTTPURLResponse else { throw RecordingError.http("non-http") }
        guard (200..<300).contains(http.statusCode) else {
            throw RecordingError.http("status=\(http.statusCode)")
        }
    }
}
