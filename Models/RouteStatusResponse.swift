//
//  RouteStatusResponse.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 12/14/25.
//


//
//  RouteStatusResponse.swift
//  SSHSwiftUIDemo
//
//  Decodes /cgi-bin/route_status.cgi (schema-proof-ish, tolerant of missing fields)
//
//  Expected JSON (key subset):
//  {
//    "ok": true,
//    "timestamp": "2025-12-14T02:11:22Z",
//    "default_route_line": "...",
//    "default_route_iface": "wwan0",
//    "default_route_via": "10.167.224.237",
//    "route_class": "lte|lan|other|none|unknown",
//    "lan": {
//      "eth0": { "exists": true, "operstate": "up", "up": true, "ip": "192.168.1.10" },
//      "wlan0": { "exists": true, "operstate": "up", "up": true, "ip": "192.168.1.148" }
//    },
//    "wwan": {
//      "iface": "wwan0",
//      "exists": true,
//      "operstate": "unknown",
//      "up": true,
//      "ipaddr": "10.167.224.237",
//      "gateway": "10.167.224.237",
//      "nat_ip": "203.0.113.10",
//      "is_default_route": true
//    },
//    "tunnel": {
//      "enabled": true,
//      "running": true,
//      "id": "hairpi",
//      "edge_connections": 2,
//      "hostnames": ["hairpi.org"],
//      "error": ""
//    }
//  }
//

//
//  RouteStatusResponse.swift
//  SSHSwiftUIDemo
//
//  Decodes /cgi-bin/route_status.cgi (schema-proof-ish, tolerant of missing fields)
//

import Foundation
import OSLog

public struct RouteStatusResponse: Codable, Sendable {

    // MARK: - Logger
    public static let log = Logger(subsystem: "SSHSwiftUIDemo", category: "RouteStatusResponse")

    // MARK: - Top-level
    public let ok: Bool
    public let timestamp: Date?

    public let defaultRouteLine: String?
    public let defaultRouteIface: String?
    public let defaultRouteVia: String?

    public let routeClass: RouteClass?

    /// ✅ Matches JSON: "default_route_stats_iface"
    public let defaultRouteStatsIface: String?

    public let lan: LAN?
    public let wwan: WWAN?
    public let tunnel: Tunnel?

    // MARK: - Coding Keys
    private enum CodingKeys: String, CodingKey {
        case ok
        case timestamp
        case defaultRouteLine = "default_route_line"
        case defaultRouteIface = "default_route_iface"
        case defaultRouteVia  = "default_route_via"
        case routeClass       = "route_class"
        case defaultRouteStatsIface = "default_route_stats_iface"   // ✅ FIXED
        case lan
        case wwan
        case tunnel
    }

    // MARK: - Enums
    public enum RouteClass: String, Codable, Sendable {
        case lte
        case lan
        case other
        case none
        case unknown
    }

    // MARK: - Nested Types

    public struct LAN: Codable, Sendable {
        public let eth0: Interface?
        public let wlan0: Interface?
    }

    public struct Interface: Codable, Sendable {
        public let exists: Bool?
        public let operstate: String?
        public let up: Bool?
        public let ip: String?

        /// Convenience: true when exists && up
        public var isUp: Bool { (exists ?? false) && (up ?? false) }

        /// Convenience: prefer ip when present and non-empty.
        public var ipOrNil: String? {
            guard let ip, !ip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ip
        }
    }

    public struct WWAN: Codable, Sendable {
        public let iface: String?
        public let exists: Bool?
        public let operstate: String?
        public let up: Bool?

        public let ipaddr: String?
        public let gateway: String?
        public let natIP: String?
        public let isDefaultRoute: Bool?

        private enum CodingKeys: String, CodingKey {
            case iface
            case exists
            case operstate
            case up
            case ipaddr
            case gateway
            case natIP = "nat_ip"
            case isDefaultRoute = "is_default_route"
        }

        public var isUp: Bool { (exists ?? false) && (up ?? false) }

        public var ipOrNil: String? {
            guard let ipaddr, !ipaddr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ipaddr
        }

        public var natOrNil: String? {
            guard let natIP, !natIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return natIP
        }

        public var gwOrNil: String? {
            guard let gateway, !gateway.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return gateway
        }
    }

    public struct Tunnel: Codable, Sendable {
        public let enabled: Bool?
        public let running: Bool?
        public let id: String?
        public let edgeConnections: Int?
        public let hostnames: [String]?
        public let error: String?

        private enum CodingKeys: String, CodingKey {
            case enabled
            case running
            case id
            case edgeConnections = "edge_connections"
            case hostnames
            case error
        }

        /// Convenience: first hostname (stable URL like hairpi.org).
        public var primaryHostname: String? {
            hostnames?.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }
    }

    // MARK: - Convenience

    /// Best guess: Which interface is currently "active" per route_class.
    public var activePathLabel: String {
        switch routeClass ?? .unknown {
        case .lte:     return "LTE"
        case .lan:     return "LAN/Wi-Fi"
        case .other:   return "Other"
        case .none:    return "None"
        case .unknown: return "Unknown"
        }
    }

    /// Prefer stable tunnel hostname if present.
    public var tunnelStableHostname: String? {
        tunnel?.primaryHostname
    }

    // MARK: - Decoder/Encoder helpers

    public static func makeJSONDecoder() -> JSONDecoder {
        let d = JSONDecoder()

        // Your CGI uses RFC3339-like Z timestamps.
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)

            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let dt = iso.date(from: s) { return dt }

            let iso2 = ISO8601DateFormatter()
            iso2.formatOptions = [.withInternetDateTime]
            if let dt = iso2.date(from: s) { return dt }

            RouteStatusResponse.log.error("Timestamp decode failed: \(s, privacy: .public)")
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid timestamp: \(s)")
        }

        return d
    }

    public static func decode(from data: Data) throws -> RouteStatusResponse {
        do {
            return try makeJSONDecoder().decode(RouteStatusResponse.self, from: data)
        } catch {
            log.error("Decode failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }
}
