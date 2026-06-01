//
//  FanCGI.swift
//  SSHSwiftUIDemo
//

import Foundation
import OSLog

public enum FanCurve: String, Sendable, Codable {
    case quiet, balanced, aggressive
}

/// Lightweight client for Pi-side fan CGIs.
/// Uses PollingHTTPClient (ephemeral session, consistent timeouts, optional cache-buster).
public actor FanCGI {
    private let baseURL: URL
    private let logger = Logger(subsystem: "com.SSHSwiftUIDemo", category: "FanCGI")
    private let http: PollingHTTPClient

    // Backpressure: cap heavy work (network + JSON decode) across the whole app.
    private let bp = Backpressure.heavy

    // Coalescing: spammy endpoints should share a single in-flight Task.
    private var inFlight: [String: Any] = [:]

    /// baseURL should be the device root, e.g. `http://192.168.1.149`
    public init(baseURL: URL) {
        self.baseURL = baseURL
        // Fan endpoints are polled; keep no-cache and short timeouts.
        self.http = PollingHTTPClient(category: "FanCGI", config: .init(timeout: 3.0, cacheBuster: false))
        logger.info("[FanCGI] init baseURL=\(self.baseURL.absoluteString, privacy: .public)")
    }

    // MARK: - Models (tach endpoint)

    /// Matches `/cgi-bin/get_fan_rpm.cgi` (daemon-backed is ideal).
    /// Schema-tolerant: extra keys are ignored.
    public struct FanRPMStatus: Decodable, Sendable, Equatable {
        public let ok: Bool
        public let rpm: Int
        public let rpmRaw: Int?
        public let fanStalled: Bool?
        public let health: String?
        public let lastEdgeAgeSec: Double?
        public let timestamp: String?

        enum CodingKeys: String, CodingKey {
            case ok, rpm, health, timestamp
            case rpmRaw = "rpm_raw"
            case fanStalled = "fan_stalled"
            case lastEdgeAgeSec = "last_edge_age_sec"
        }
    }

    // MARK: - Public API (fan_control.cgi)

    /// GET /cgi-bin/fan_control.cgi?action=status
    func status() async throws -> FanStatus {
        let final = try urlForFanControl(action: "status", query: [])
        let tag = "fan_control(status)"

        // This one is commonly polled; coalesce.
        return try await coalesced(tag: tag) {
            self.logger.info("[FanCGI] ⇢ status \(final.absoluteString, privacy: .public)")
            let decoded: FanStatus = try await self.bp.withPermit(tag) {
                try await self.http.getJSON(FanStatus.self, url: final, endpoint: tag)
            }
            self.logger.info("[FanCGI] ⇠ status ok=\(decoded.ok, privacy: .public) mode=\(String(describing: decoded.mode), privacy: .public) duty=\(decoded.dutyLogString, privacy: .public) rpm=\(decoded.rpm, privacy: .public)")
            return decoded
        }
    }

    /// GET /cgi-bin/fan_control.cgi?action=set&duty=NN
    func set(duty: Int) async throws -> FanStatus {
        let clamped = min(max(duty, 0), 100)
        let final = try urlForFanControl(action: "set", query: [
            URLQueryItem(name: "duty", value: String(clamped))
        ])
        let tag = "fan_control(set)"

        // Intentionally NOT coalesced: each set is meaningful.
        logger.info("[FanCGI] ⇢ set duty=\(clamped, privacy: .public) \(final.absoluteString, privacy: .public)")
        let decoded: FanStatus = try await bp.withPermit(tag) {
            try await http.getJSON(FanStatus.self, url: final, endpoint: tag)
        }
        logger.info("[FanCGI] ⇠ set ok=\(decoded.ok, privacy: .public) mode=\(String(describing: decoded.mode), privacy: .public) duty=\(decoded.dutyLogString, privacy: .public) rpm=\(decoded.rpm, privacy: .public)")
        return decoded
    }

    /// GET /cgi-bin/fan_control.cgi?action=auto&curve=quiet|balanced|aggressive
    func startAuto(curve: FanCurve) async throws -> FanStatus {
        let final = try urlForFanControl(action: "auto", query: [
            URLQueryItem(name: "curve", value: curve.rawValue)
        ])
        let tag = "fan_control(auto)"

        logger.info("[FanCGI] ⇢ auto curve=\(curve.rawValue, privacy: .public) \(final.absoluteString, privacy: .public)")
        let decoded: FanStatus = try await bp.withPermit(tag) {
            try await http.getJSON(FanStatus.self, url: final, endpoint: tag)
        }
        logger.info("[FanCGI] ⇠ auto ok=\(decoded.ok, privacy: .public) mode=\(String(describing: decoded.mode), privacy: .public) duty=\(decoded.dutyLogString, privacy: .public) rpm=\(decoded.rpm, privacy: .public)")
        return decoded
    }

    /// GET /cgi-bin/fan_control.cgi?action=stopauto
    func stopAuto() async throws -> FanStatus {
        let final = try urlForFanControl(action: "stopauto", query: [])
        let tag = "fan_control(stopauto)"

        logger.info("[FanCGI] ⇢ stopauto \(final.absoluteString, privacy: .public)")
        let decoded: FanStatus = try await bp.withPermit(tag) {
            try await http.getJSON(FanStatus.self, url: final, endpoint: tag)
        }
        logger.info("[FanCGI] ⇠ stopauto ok=\(decoded.ok, privacy: .public) mode=\(String(describing: decoded.mode), privacy: .public) duty=\(decoded.dutyLogString, privacy: .public) rpm=\(decoded.rpm, privacy: .public)")
        return decoded
    }

    // MARK: - Tach endpoint (get_fan_rpm.cgi)

    /// GET /cgi-bin/get_fan_rpm.cgi
    public func tachStatus() async throws -> FanRPMStatus {
        let final = try urlForCGI(path: "get_fan_rpm.cgi")
        let tag = "get_fan_rpm"

        // Also commonly polled; coalesce.
        return try await coalesced(tag: tag) {
            self.logger.info("[FanCGI] ⇢ get_fan_rpm \(final.absoluteString, privacy: .public)")
            let decoded: FanRPMStatus = try await self.bp.withPermit(tag) {
                try await self.http.getJSON(FanRPMStatus.self, url: final, endpoint: tag)
            }
            self.logger.info("[FanCGI] ⇠ get_fan_rpm ok=\(decoded.ok, privacy: .public) rpm=\(decoded.rpm, privacy: .public) health=\(decoded.health ?? "nil", privacy: .public) stalled=\(String(describing: decoded.fanStalled), privacy: .public) lastEdgeAge=\(String(describing: decoded.lastEdgeAgeSec), privacy: .public)")
            return decoded
        }
    }

    // MARK: - Coalescing helper

    /// Coalesce calls by `tag` so N callers share one in-flight Task (no queue storm, no decode storm).
    private func coalesced<T: Sendable>(tag: String, _ op: @Sendable @escaping () async throws -> T) async throws -> T {
        if let existing = inFlight[tag] as? Task<T, Error> {
            logger.debug("[FanCGI] [coalesce] join tag=\(tag, privacy: .public)")
            return try await existing.value
        }

        logger.debug("[FanCGI] [coalesce] start tag=\(tag, privacy: .public)")
        let task = Task<T, Error> {
            try await op()
        }
        inFlight[tag] = task

        defer {
            // Clean up regardless of outcome.
            inFlight[tag] = nil
            logger.debug("[FanCGI] [coalesce] end tag=\(tag, privacy: .public)")
        }

        return try await task.value
    }

    // MARK: - URL building

    /// Builds `http://host/cgi-bin/<path>`
    private func urlForCGI(path: String) throws -> URL {
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }

        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        comps.path = "/cgi-bin/\(cleanPath)"
        comps.queryItems = nil

        guard let url = comps.url else { throw URLError(.badURL) }
        return url
    }

    private func urlForFanControl(action: String, query: [URLQueryItem]) throws -> URL {
        var items = [URLQueryItem(name: "action", value: action)]
        items.append(contentsOf: query)

        guard var comps = URLComponents(url: try urlForCGI(path: "fan_control.cgi"), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        comps.queryItems = items

        guard let url = comps.url else { throw URLError(.badURL) }
        return url
    }
}
