//
//  CloudflaredTunnelHealth.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 12/11/25.
//


//
//  CloudflaredTunnelHealth.swift
//  SSHSwiftUIDemo
//
//  Created by ChatGPT on 2025-12-09.
//

import Foundation

/// Top-level response from /cgi-bin/tunnel_health.cgi
struct CloudflaredTunnelHealth: Decodable, Identifiable {
    let ok: Bool
    let stableURL: String?
    let tunnels: [CloudflaredTunnel]
    let error: String?
    let details: String?

    // For Identifiable
    var id: String { "cloudflared-health" }

    var tunnelCount: Int { tunnels.count }

    var connectorCount: Int {
        tunnels.reduce(0) { $0 + $1.connections.count }
    }

    var primaryStatusSummary: String {
        if ok {
            if tunnelCount == 0 {
                return "OK but no tunnels reported"
            } else {
                return "Online: \(tunnelCount) tunnel\(tunnelCount == 1 ? "" : "s"), \(connectorCount) connector\(connectorCount == 1 ? "" : "s")"
            }
        } else if let error {
            return "Error: \(error)"
        } else {
            return "Unknown"
        }
    }
}

/// A single tunnel entry under "tunnels"
struct CloudflaredTunnel: Decodable, Identifiable {
    let id: String              // UUID
    let name: String
    let createdAt: String       // ISO8601
    let deletedAt: String?      // Often "0001-01-01..." or null
    let connections: [CloudflaredConnection]

    var isDeleted: Bool {
        guard let deletedAt,
              deletedAt != "0001-01-01T00:00:00Z"
        else { return false }
        return true
    }
}

/// A single tunnel connection (Cloudflare colo to origin)
struct CloudflaredConnection: Decodable, Identifiable {
    let coloName: String
    let id: String
    let isPendingReconnect: Bool
    let originIP: String
    let openedAt: String

    var idStringShort: String {
        String(id.prefix(8))
    }

    // Conform to Identifiable
    var identifier: String { id }
    var identity: String { id } // just to be extra clear

    var identityShort: String {
        idStringShort
    }

    // Identifiable requirement
    var idValue: String { id }

    // SwiftUI uses 'id', so we alias:
    var id_forSwiftUI: String { id }

    // Actually satisfy Identifiable:
    //var id: String { idValue }
}
