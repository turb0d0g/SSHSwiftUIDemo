//
//  TunnelHealthResponse.swift
//  SSHSwiftUIDemo
//
//  Schema-proof-ish model for Cloudflared tunnel health + info.
//  Designed to tolerate your evolving CGI JSON without breaking builds.
//
//  Supports two common shapes:
//
//  (A) tunnel_health.cgi style (summary-ish):
//  {
//    "ok": true,
//    "id": "...",
//    "name": "...",
//    "stable_url": "https://hairpi.org",
//    "tunnel_stable_url": "https://hairpi.org",
//    "tunnel_temp_url": "https://random.trycloudflare.com",
//    "tunnel_count": 1,
//    "connector_count": 2
//  }
//
//  (B) tunnel_info.cgi / richer “info” payload style:
//  {
//    "ok": true,
//    "tunnel_ident": "hairpi2",
//    "info": {
//      "id": "...",
//      "name": "...",
//      "tunnel": "...",
//      "created_at": "...",
//      "connectors": [ ...edges... ]
//    }
//  }
//

import Foundation
import OSLog

public struct TunnelHealthResponse: Decodable {

    // MARK: - Logger
    public static let log = Logger(subsystem: "SSHSwiftUIDemo", category: "TunnelHealthResponse")

    // MARK: - Top-level
    public let ok: Bool?
    public let error: String?

    // Flexible identifiers (some scripts emit these at top-level)
    public let id: String?
    public let name: String?

    // Stable URL fields (you’ve used multiple keys historically)
    public let stableURL: String?
    public let tunnelStableURL: String?

    // Temporary URL (trycloudflare) sometimes emitted
    public let tunnelTempURL: String?

    // Counts (varied keys across scripts)
    public let tunnelCount: Int?
    public let connectorCount: Int?
    public let tunnelsCountAlt: Int?
    public let connectorsCountAlt: Int?

    // Some code expects “tunnel_ident” (legacy naming)
    public let tunnelIdent: String?

    // Rich info payload (connectors/edges)
    public let info: TunnelInfo?

    // MARK: - CodingKeys
    private enum CodingKeys: String, CodingKey {
        case ok, error
        case id, name

        case stableURL = "stable_url"
        case tunnelStableURL = "tunnel_stable_url"
        case tunnelTempURL = "tunnel_temp_url"

        case tunnelCount = "tunnel_count"
        case connectorCount = "connector_count"
        case tunnelsCountAlt = "tunnels"
        case connectorsCountAlt = "connectors"

        case tunnelIdent = "tunnel_ident"
        case info
    }
}

// MARK: - Rich Info Types (must be Codable for TunnelHealthResponse to be Encodable)

public struct TunnelInfo: Decodable {
    public let id: String?
    public let name: String?
    public let tunnel: String?
    public let created: String?
    public let url: String?
    public let createdAt: String?
    public let status: String?
    public let connectors: [TunnelConnector]?

    private enum CodingKeys: String, CodingKey {
        case id, name, tunnel, created, url, status, connectors
        case createdAt = "created_at"
    }
}

public struct TunnelConnector: Decodable {
    public let id: String?
    public let created: String?
    public let arch: String?
    public let version: String?
    public let runAt: String?
    public let features: [String]?
    public let edges: [TunnelEdge]?

    private enum CodingKeys: String, CodingKey {
        case id, created, arch, version, features, edges
        case runAt = "run_at"
    }
}

public struct TunnelEdge: Decodable, Identifiable {
    public var id: String { "\(colo ?? "?")-\(originIp ?? "?")-\(openedAt ?? "")" }

    public let colo: String?
    public let originIp: String?
    public let openedAt: String?
    public let isPendingReconnect: Bool?

    private enum CodingKeys: String, CodingKey {
        case colo
        case originIp = "origin_ip"
        case openedAt = "opened_at"
        case isPendingReconnect = "is_pending_reconnect"
    }
}

public struct TunnelRoute: Decodable, Identifiable {
    public let hostname: String
    public let tunnelID: String?
    public let tunnelName: String?

    public var id: String { hostname }

    private enum CodingKeys: String, CodingKey {
        case hostname
        case tunnelID = "tunnel_id"
        case tunnelName = "tunnel_name"
    }
}

// MARK: - Convenience (what the ViewModels want)

public extension TunnelHealthResponse {

    /// Unified connectors list regardless of schema.
    var connectorsList: [TunnelConnector] {
        info?.connectors ?? []
    }

    var allEdges: [TunnelEdge] {
        connectorsList.flatMap { $0.edges ?? [] }
    }

    var connectorCountUnified: Int {
        connectorCount
        ?? connectorsCountAlt
        ?? connectorsList.count
    }

    var tunnelCountUnified: Int {
        tunnelCount
        ?? tunnelsCountAlt
        ?? (info == nil ? 0 : 1)
    }

    /// Prefer something human-readable for UI title.
    var displayName: String? {
        // Prefer rich info name/tunnel, then top-level name, then ident, then id.
        if let s = info?.name, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        if let s = info?.tunnel, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        if let s = name, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        if let s = tunnelIdent, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        if let s = id, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        return nil
    }

    /// Group edges by colo.
    var edgesByColo: [(colo: String, edges: [TunnelEdge])] {
        let grouped = Dictionary(grouping: allEdges) { edge in
            let c = edge.colo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return c.isEmpty ? "unknown" : c
        }
        return grouped
            .map { (colo: $0.key, edges: $0.value) }
            .sorted { $0.colo.localizedStandardCompare($1.colo) == .orderedAscending }
    }

    var uniqueOriginIPs: [String] {
        Array(Set(allEdges.compactMap(\.originIp))).sorted()
    }

    var edgeCount: Int { allEdges.count }

    /// Best-effort stable URL string.
    var stableURLString: String? {
        if let s = stableURL, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        if let s = tunnelStableURL, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        return nil
    }

    /// Best-effort temp URL string.
    var tempURLString: String? {
        guard let s = tunnelTempURL, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}
