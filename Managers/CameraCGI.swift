//
//  CameraCGI.swift
//  SSHSwiftUIDemo
//
//  Lightweight client for Pi-side CGI endpoints controlling libcamera/HLS.
//  Uses async/await with robust logging and short, bounded timeouts.
//
//  Updated: 2025-12-24
//

//
//  CameraCGI.swift
//  SSHSwiftUIDemo
//
//  Lightweight client for Pi-side CGI endpoints controlling libcamera/HLS.
//  Uses async/await with robust logging and short, bounded timeouts.
//
//  Updated: 2025-12-24
//

import Foundation
import OSLog
import UIKit

public enum CameraCGIError: Error {
    case badURL
    case httpStatus(Int)
    case emptyBody
    case decode
}

public struct CameraCGI {

    private static let log = Logger(
        subsystem: "com.SSHSwiftUIDemo",
        category: "CameraCGI"
    )

    // MARK: - Public storefront paths

    public static let publicPlaylistPath = "/hls/stream.m3u8"
    public static let publicSnapshotPath = "/hls/snapshot.jpg"
    public static let snapshotCGIPath   = "/cgi-bin/snapshot_hls.cgi"

    // MARK: - Backpressure + Coalescing gate

    private static let gate = Gate()

    private actor Gate {
        private let bp = Backpressure.heavy
        private var inFlight: [String: Any] = [:]

        // Ephemeral session: avoid shared caches/cookies for polling endpoints.
        private let session: URLSession = {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            cfg.urlCache = nil
            cfg.httpCookieStorage = nil
            cfg.timeoutIntervalForRequest = 12
            cfg.timeoutIntervalForResource = 12
            cfg.waitsForConnectivity = false
            return URLSession(configuration: cfg)
        }()

        func withPermit<T>(_ tag: String, _ op: () async throws -> T) async rethrows -> T {
            try await bp.withPermit(tag, op)
        }

        func coalesced<T: Sendable>(
            key: String,
            tag: String,
            _ op: @Sendable @escaping () async throws -> T
        ) async throws -> T {
            if let existing = inFlight[key] as? Task<T, Error> {
                CameraCGI.log.debug("[CameraCGI] [coalesce] join key=\(key, privacy: .public) tag=\(tag, privacy: .public)")
                return try await existing.value
            }

            CameraCGI.log.debug("[CameraCGI] [coalesce] start key=\(key, privacy: .public) tag=\(tag, privacy: .public)")
            let task = Task<T, Error> { try await op() }
            inFlight[key] = task

            defer {
                inFlight[key] = nil
                CameraCGI.log.debug("[CameraCGI] [coalesce] end key=\(key, privacy: .public) tag=\(tag, privacy: .public)")
            }

            return try await task.value
        }

        func fetchData(
            url: URL,
            timeout: TimeInterval,
            accept: String?,
            tag: String
        ) async throws -> (Data, HTTPURLResponse) {

            try await withPermit(tag) {
                var req = URLRequest(url: url, timeoutInterval: timeout)
                req.httpMethod = "GET"
                req.cachePolicy = .reloadIgnoringLocalCacheData
                if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }

                let (data, resp) = try await session.data(for: req)

                guard let http = resp as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                guard (200...299).contains(http.statusCode) else {
                    throw CameraCGIError.httpStatus(http.statusCode)
                }
                return (data, http)
            }
        }
    }

    // MARK: - Stream control

    /// Starts or ensures HLS stream is running.
    /// Optional `CameraStreamConfig` is encoded into query params.
    @discardableResult
    public static func startStream(
        host: String,
        port: Int? = nil,
        config: CameraStreamConfig? = nil
    ) async -> Bool {

        let query = config.map { queryItems(for: $0) }

        return await requestOK(
            host: host,
            port: port,
            path: "/cgi-bin/start_hls_stream.cgi",
            query: query,
            timeout: 12,
            label: "startStream"
        )
    }

    @discardableResult
    public static func stopStream(
        host: String,
        port: Int? = nil
    ) async -> Bool {
        await requestOK(
            host: host,
            port: port,
            path: "/cgi-bin/stop_hls_stream.cgi",
            timeout: 10,
            label: "stopStream"
        )
    }

    // MARK: - URLs

    public static func playlistURL(
        host: String,
        port: Int? = nil
    ) -> URL? {
        buildURL(host: host, port: port, path: publicPlaylistPath)
    }

    public static func snapshotURL(
        host: String,
        port: Int? = nil
    ) -> URL? {
        buildURL(host: host, port: port, path: publicSnapshotPath)
    }

    // MARK: - Snapshot

    /// Fetches a snapshot, coalesced per-host so spam calls share one decode.
    public static func snapshot(
        host: String,
        port: Int? = nil
    ) async -> UIImage? {

        let key = "snapshot:\(host):\(port ?? 80)"
        log.debug("[CameraCGI] snapshot host=\(host, privacy: .public) port=\(String(describing: port), privacy: .public)")

        return try? await gate.coalesced(key: key, tag: "snapshot") {
            // Prefer CGI snapshot (fresh + consistent) then fall back to public snapshot.
            if let img = await fetchImage(
                host: host,
                port: port,
                path: snapshotCGIPath,
                timeout: 7,
                label: "snapshot_hls.cgi"
            ) {
                return img
            }

            if let img = await fetchImage(
                host: host,
                port: port,
                path: publicSnapshotPath,
                timeout: 5,
                label: "snapshot.jpg"
            ) {
                return img
            }

            log.error("[CameraCGI]  snapshot failed host=\(host, privacy: .public)")
            throw CameraCGIError.emptyBody
        }
    }

    // MARK: - Recording

    @discardableResult
    public static func startRecord(
        host: String,
        port: Int? = nil,
        label: String = "ios",
        width: Int = 1920,
        height: Int = 1080,
        fps: Int = 30
    ) async -> Bool {

        let q: [URLQueryItem] = [
            .init(name: "label", value: label),
            .init(name: "width", value: String(width)),
            .init(name: "height", value: String(height)),
            .init(name: "fps", value: String(fps))
        ]

        return await requestOK(
            host: host,
            port: port,
            path: "/cgi-bin/start_hls_recording.cgi",
            query: q,
            timeout: 12,
            label: "startRecord"
        )
    }

    @discardableResult
    public static func stopRecord(
        host: String,
        port: Int? = nil
    ) async -> Bool {
        await requestOK(
            host: host,
            port: port,
            path: "/cgi-bin/stop_hls_recording.cgi",
            timeout: 20,
            label: "stopRecord"
        )
    }

    // MARK: - Query mapping

    private static func queryItems(
        for cfg: CameraStreamConfig
    ) -> [URLQueryItem] {

        [
            URLQueryItem(name: "res", value: cfg.resolution.cgiValue),
            URLQueryItem(name: "fps", value: String(cfg.fps)),
            URLQueryItem(name: "dyn", value: cfg.dynamicRange.rawValue),
            URLQueryItem(name: "prores", value: cfg.proRes ? "1" : "0")
        ]
    }

    // MARK: - Transport

    private static func buildURL(
        host: String,
        port: Int?,
        path: String,
        query: [URLQueryItem]? = nil
    ) -> URL? {

        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host
        if let port, port != 80 { comps.port = port }
        comps.path = path.hasPrefix("/") ? path : "/" + path
        if let query, !query.isEmpty { comps.queryItems = query }
        return comps.url
    }

    @discardableResult
    private static func requestOK(
        host: String,
        port: Int?,
        path: String,
        query: [URLQueryItem]? = nil,
        timeout: TimeInterval,
        label: String
    ) async -> Bool {

        guard let url = buildURL(
            host: host,
            port: port,
            path: path,
            query: query
        ) else {
            log.error("[CameraCGI]  \(label): bad URL")
            return false
        }

        do {
            log.info("[CameraCGI] ⇢ \(label) \(url.absoluteString, privacy: .public)")

            let (data, http) = try await gate.fetchData(
                url: url,
                timeout: timeout,
                accept: "*/*",
                tag: "CameraCGI.\(label)"
            )

            log.info("[CameraCGI] ⇠ \(label) \(http.statusCode, privacy: .public) bytes=\(data.count, privacy: .public)")
            return true
        } catch CameraCGIError.httpStatus(let code) {
            log.error("[CameraCGI]  \(label): HTTP \(code, privacy: .public)")
            return false
        } catch {
            log.error("[CameraCGI]  \(label): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Image fetch

    private static func fetchImage(
        host: String,
        port: Int?,
        path: String,
        timeout: TimeInterval,
        label: String
    ) async -> UIImage? {

        guard let url = buildURL(
            host: host,
            port: port,
            path: path
        ) else {
            log.error("[CameraCGI]  \(label): bad URL")
            return nil
        }

        do {
            log.info("[CameraCGI] ⇢ \(label) \(url.absoluteString, privacy: .public)")

            let (data, http) = try await gate.fetchData(
                url: url,
                timeout: timeout,
                accept: "image/*",
                tag: "CameraCGI.\(label)"
            )

            guard !data.isEmpty else {
                log.error("[CameraCGI]  \(label): empty body")
                return nil
            }

            guard let img = UIImage(data: data) else {
                log.error("[CameraCGI]  \(label): decode failed bytes=\(data.count, privacy: .public) http=\(http.statusCode, privacy: .public)")
                return nil
            }

            log.info("[CameraCGI] ⇠ \(label) ok bytes=\(data.count, privacy: .public)")
            return img
        } catch CameraCGIError.httpStatus(let code) {
            log.error("[CameraCGI] \(label): HTTP \(code, privacy: .public)")
            return nil
        } catch {
            log.error("[CameraCGI] \(label): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
