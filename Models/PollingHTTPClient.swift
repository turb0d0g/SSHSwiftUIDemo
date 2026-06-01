//
//  PollingHTTPClient.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 12/25/25.
//
//
//  PollingHTTPClient.swift
//  SSHSwiftUIDemo
//
//  Shared HTTP client for high-frequency polling.
//  - Ephemeral session (no URLCache/cookies)
//  - Consistent timeouts + validation + logging
//  - Optional cache-buster query (`_ts=`)
//  - Reusable JSONDecoder
//
//  iOS 16+
//

import Foundation
import OSLog

public struct PollingHTTPClient: Sendable {

    // MARK: - Types

    public struct Config: Sendable {
        public var timeout: TimeInterval
        public var cacheBuster: Bool
        public var userAgent: String?
        public var maxBodyPreviewBytes: Int

        public init(
            timeout: TimeInterval = 3.0,
            cacheBuster: Bool = false,
            userAgent: String? = nil,
            maxBodyPreviewBytes: Int = 1400
        ) {
            self.timeout = timeout
            self.cacheBuster = cacheBuster
            self.userAgent = userAgent
            self.maxBodyPreviewBytes = maxBodyPreviewBytes
        }
    }

    public struct HTTPFailure: Error, Sendable, LocalizedError, CustomStringConvertible {
        public let url: URL
        public let endpoint: String
        public let statusCode: Int
        public let contentType: String?
        public let location: String?
        public let bodyPreview: String

        public var errorDescription: String? {
            // This is what ends up in your VM/UI if you propagate it.
            var parts: [String] = []
            parts.append("HTTP \(statusCode) \(endpoint)")
            if let ct = contentType { parts.append("ct=\(ct)") }
            if let loc = location { parts.append("loc=\(loc)") }
            if !bodyPreview.isEmpty { parts.append("body=\(bodyPreview)") }
            return parts.joined(separator: " | ")
        }

        public var description: String {
            errorDescription ?? "HTTPFailure(\(statusCode))"
        }
    }

    public struct NonHTTPFailure: Error, Sendable, LocalizedError, CustomStringConvertible {
        public let url: URL
        public let endpoint: String

        public var errorDescription: String? { "Non-HTTP response for \(endpoint) url=\(url.absoluteString)" }
        public var description: String { errorDescription ?? "NonHTTPFailure" }
    }

    public struct DecodeFailure: Error, Sendable, LocalizedError, CustomStringConvertible {
        public let url: URL
        public let endpoint: String
        public let underlying: String
        public let bodyPreview: String

        public var errorDescription: String? {
            "Decode failed \(endpoint) | err=\(underlying) | body=\(bodyPreview)"
        }

        public var description: String { errorDescription ?? "DecodeFailure" }
    }

    // MARK: - State

    private let log: Logger
    private let config: Config

    // Ephemeral session shared process-wide (cheap, stable)
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false

        // Don't lie via config: make session defaults generous, use per-request timeout.
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        d.keyDecodingStrategy = .useDefaultKeys
        return d
    }()

    public init(
        subsystem: String = "com.SSHSwiftUIDemo",
        category: String,
        config: Config = .init()
    ) {
        self.log = Logger(subsystem: subsystem, category: category)
        self.config = config
    }

    // MARK: - Public API

    public func getData(_ url: URL, endpoint: String) async throws -> Data {
        let final = withCacheBusterIfNeeded(url)

        var req = URLRequest(url: final)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = config.timeout
        if let ua = config.userAgent {
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
        }

        log.debug("[HTTP] ⇢ GET \(endpoint, privacy: .public) url=\(final.absoluteString, privacy: .public) timeout=\(config.timeout, privacy: .public)s")

        let (data, resp) = try await Self.session.data(for: req)
        try validate(resp: resp, endpoint: endpoint, url: final, body: data)

        log.debug("[HTTP] ⇠ GET \(endpoint, privacy: .public) ok bytes=\(data.count, privacy: .public)")
        return data
    }

    public func getJSON<T: Decodable>(_ type: T.Type, url: URL, endpoint: String) async throws -> T {
        let data = try await getData(url, endpoint: endpoint)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            let preview = bodyPreviewString(from: data, maxBytes: config.maxBodyPreviewBytes)
            let underlying = String(describing: error)
            log.error("[HTTP] ! decode \(endpoint, privacy: .public) url=\(url.absoluteString, privacy: .public) err=\(underlying, privacy: .public) body=\(preview, privacy: .public)")
            throw DecodeFailure(url: url, endpoint: endpoint, underlying: underlying, bodyPreview: preview)
        }
    }

    // MARK: - Helpers

    private func validate(resp: URLResponse, endpoint: String, url: URL, body: Data) throws {
        guard let http = resp as? HTTPURLResponse else {
            log.error("[HTTP] ! \(endpoint, privacy: .public) non-HTTP response url=\(url.absoluteString, privacy: .public)")
            throw NonHTTPFailure(url: url, endpoint: endpoint)
        }

        let ct = http.value(forHTTPHeaderField: "Content-Type")
        let loc = http.value(forHTTPHeaderField: "Location")
        let status = http.statusCode

        guard (200..<300).contains(status) else {
            let preview = bodyPreviewString(from: body, maxBytes: config.maxBodyPreviewBytes)

            // Log with key headers.
            log.error("[HTTP] ! \(endpoint, privacy: .public) HTTP \(status, privacy: .public) ct=\(ct ?? "nil", privacy: .public) loc=\(loc ?? "nil", privacy: .public) url=\(url.absoluteString, privacy: .public) body=\(preview, privacy: .public)")

            throw HTTPFailure(
                url: url,
                endpoint: endpoint,
                statusCode: status,
                contentType: ct,
                location: loc,
                bodyPreview: preview
            )
        }
    }

    private func withCacheBusterIfNeeded(_ url: URL) -> URL {
        guard config.cacheBuster else { return url }
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "_ts", value: String(Int(Date().timeIntervalSince1970 * 1000))))
        comps.queryItems = items
        return comps.url ?? url
    }

    private func bodyPreviewString(from data: Data, maxBytes: Int) -> String {
        guard !data.isEmpty else { return "" }
        let slice = data.prefix(maxBytes)
        // Trim nulls; CGI sometimes yields binary-ish junk.
        var s = String(decoding: slice, as: UTF8.self)
        s = s.replacingOccurrences(of: "\0", with: "")
        return String(s.prefix(maxBytes))
    }
}
