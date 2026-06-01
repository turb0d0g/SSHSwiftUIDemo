//
//  RPiVoltService.swift
//  SSHSwiftUIDemo
//
//  Diagnostics / fallback reader (NOT intended for high-frequency polling).
//

import Foundation
import OSLog

public enum RPiVoltServiceError: Error, LocalizedError {
    case badBaseURL
    case notFound
    case decodeFailed
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .badBaseURL: return "Invalid base URL"
        case .notFound: return "No rpiVolt endpoint found"
        case .decodeFailed: return "Unable to decode rpiVolt payload"
        case .httpStatus(let c): return "HTTP \(c)"
        }
    }
}

public struct RPiVoltService: Sendable {
    public static let logger = Logger(subsystem: "com.SSHSwiftUIDemo", category: "RPiVolt")

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 3
        return URLSession(configuration: cfg)
    }()

    private static let candidatePaths: [String] = [
        "/cgi-bin/get_rpivolt.cgi",
        "/cgi-bin/monitoring_v12.py?only=volt",
        "/metrics/rpivolt"
    ]

    public struct Reading: Sendable { public let volts: Double }

    private struct VoltProbe: Decodable {
        let rpiVolt: Double?
        let volt: Double?
        let v: Double?
        let core: Double?
        let vcore: Double?
    }

    public static func read(from baseURL: URL, timeout: TimeInterval = 3.0) async throws -> Reading {
        for path in candidatePaths {
            guard let url = URL(string: path, relativeTo: baseURL) else { continue }

            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = timeout

            logger.debug("[RPiVolt] ⇢ GET \(url.absoluteString, privacy: .public)")

            do {
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse else { continue }
                guard (200..<300).contains(http.statusCode) else {
                    logger.error("[RPiVolt] HTTP \(http.statusCode, privacy: .public) for \(url.absoluteString, privacy: .public)")
                    continue
                }

                if let v = parseVoltage(from: data) {
                    logger.debug("[RPiVolt] ✓ \(v, privacy: .public) V from \(url.absoluteString, privacy: .public)")
                    return .init(volts: v)
                } else {
                    let body = String(decoding: data, as: UTF8.self)
                    logger.error("[RPiVolt] decode failed for \(url.absoluteString, privacy: .public) payload=\(String(body.prefix(1200)), privacy: .public)")
                }
            } catch {
                logger.error("[RPiVolt] request error for \(url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        throw RPiVoltServiceError.notFound
    }

    private static func parseVoltage(from data: Data) -> Double? {
        // Try JSON probe first (cheap & typed)
        if let probe = try? JSONDecoder().decode(VoltProbe.self, from: data) {
            if let v = probe.rpiVolt ?? probe.volt ?? probe.v ?? probe.core ?? probe.vcore { return v }
        }

        // Plain text fallback: "0.8625V\n"
        var s = String(decoding: data, as: UTF8.self)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "V", with: "", options: .caseInsensitive)
        return Double(s)
    }
}
