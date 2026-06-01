//
//  RPiVoltCGI.swift
//  SSHSwiftUIDemo
//

//
//  RPiVoltCGI.swift
//  SSHSwiftUIDemo
//
//  Talks to /cgi-bin/get_rpivolt.cgi
//  Example response:
//  {
//    "rpiVolt": 0.946,
//    "unit": "V",
//    "timestamp": "2026-02-05T16:56:00",
//    "source": "vcgencmd"
//  }
//

import Foundation
import OSLog

public struct RPiVoltStatus: Codable, Sendable, Equatable {
    public let ok: Bool
    public let coreVolts: Double?
    public let throttledHex: String

    public let undervoltNow: Int
    public let freqCappedNow: Int
    public let throttledNow: Int
    public let softTempLimitNow: Int

    public let undervoltHist: Int
    public let freqCappedHist: Int
    public let throttledHist: Int
    public let softTempLimitHist: Int

    enum CodingKeys: String, CodingKey {
        case ok
        case coreVolts = "core_volts"
        case throttledHex = "throttled_hex"
        case undervoltNow = "undervolt_now"
        case freqCappedNow = "freq_capped_now"
        case throttledNow = "throttled_now"
        case softTempLimitNow = "soft_temp_limit_now"
        case undervoltHist = "undervolt_hist"
        case freqCappedHist = "freq_capped_hist"
        case throttledHist = "throttled_hist"
        case softTempLimitHist = "soft_temp_limit_hist"
    }

    // MARK: - Flags (Bool helpers)

    public var isUndervoltedNow: Bool { undervoltNow != 0 }
    public var wasEverUndervolted: Bool { undervoltHist != 0 }

    public var isFreqCappedNow: Bool { freqCappedNow != 0 }
    public var wasEverFreqCapped: Bool { freqCappedHist != 0 }

    public var isSoftTempLimitedNow: Bool { softTempLimitNow != 0 }
    public var wasEverSoftTempLimited: Bool { softTempLimitHist != 0 }

    public var isThrottledNow: Bool {
        throttledNow != 0 || freqCappedNow != 0 || softTempLimitNow != 0
    }

    public var wasEverThrottled: Bool {
        throttledHist != 0 || freqCappedHist != 0 || softTempLimitHist != 0
    }

    // MARK: - Sanity

    public var hasValidCoreVolts: Bool {
        guard let v = coreVolts, v.isFinite else { return false }
        // Pi core volt typically ~0.80–1.20ish; keep wide to avoid false negatives.
        return v > 0.4 && v < 2.0
    }

    // MARK: - Logging helpers

    /// Compact human log string (avoid repeating formatting everywhere).
    public var logSummary: String {
        let v = coreVolts.map { String(format: "%.4fV", $0) } ?? "nil"
        return "ok=\(ok) core=\(v) uvNow=\(undervoltNow) uvHist=\(undervoltHist) throttledHex=\(throttledHex)"
    }
}


public actor RPiVoltCGI {
    private let baseURL: URL
    private let logger = Logger(subsystem: "com.SSHSwiftUIDemo", category: "RPiVoltCGI")
    private let http: PollingHTTPClient

    public init(baseURL: URL) {
        self.baseURL = baseURL
        self.http = PollingHTTPClient(category: "RPiVoltCGI", config: .init(timeout: 3, cacheBuster: false))
        logger.log("[RPiVoltCGI] init baseURL=\(self.baseURL.absoluteString, privacy: .public)")
    }

    // GET /cgi-bin/get_rpivolt.cgi
    public func status() async throws -> RPiVoltStatus {
        let final = try urlForCGI("get_rpivolt.cgi")
        logger.log("[RPiVoltCGI] ⇢ status \(final.absoluteString, privacy: .public)")

        let decoded: RPiVoltStatus = try await http.getJSON(RPiVoltStatus.self, url: final, endpoint: "get_rpivolt.cgi")

        logger.log("[RPiVoltCGI] ⇠ status \(decoded.logSummary, privacy: .public)")
        return decoded
    }

    private func urlForCGI(_ script: String) throws -> URL {
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        let clean = script.hasPrefix("/") ? String(script.dropFirst()) : script
        comps.path = "/cgi-bin/\(clean)"
        comps.queryItems = nil
        guard let url = comps.url else { throw URLError(.badURL) }
        return url
    }
}
