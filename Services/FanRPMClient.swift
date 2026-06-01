//
//  FanRPMClient.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 12/17/25.
//  Updated: shared PollingHTTPClient, correct CGI path, correct response model.
//

import Foundation
import OSLog

actor FanRPMClient {
    private let logger = Logger(subsystem: "com.SSHSwiftUIDemo", category: "FanRPMClient")
    private let baseURL: URL
    private let http: PollingHTTPClient

    init(baseURL: URL) {
        self.baseURL = baseURL
        self.http = PollingHTTPClient(category: "FanRPMClient", config: .init(timeout: 3.0, cacheBuster: false))
        logger.debug("[FanRPMClient] init baseURL=\(baseURL.absoluteString, privacy: .public)")
    }

    struct RPMResponse: Decodable, Sendable, Equatable {
        let ok: Bool
        let rpm: Int
        let rpmRaw: Int?
        let fanStalled: Bool?
        let health: String?
        let lastEdgeAgeSec: Double?
        let timestamp: String?

        enum CodingKeys: String, CodingKey {
            case ok, rpm, health, timestamp
            case rpmRaw = "rpm_raw"
            case fanStalled = "fan_stalled"
            case lastEdgeAgeSec = "last_edge_age_sec"
        }
    }

    func fetch() async throws -> RPMResponse {
        let url = try urlForCGI("get_fan_rpm.cgi")
        logger.debug("[FanRPMClient] ⇢ GET \(url.absoluteString, privacy: .public)")

        let decoded: RPMResponse = try await http.getJSON(RPMResponse.self, url: url, endpoint: "get_fan_rpm")
        logger.debug("[FanRPMClient] ⇠ ok=\(decoded.ok, privacy: .public) rpm=\(decoded.rpm, privacy: .public)")
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
