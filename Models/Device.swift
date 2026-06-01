//
//  Device.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 7/26/25.
//

import Foundation

struct Device: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var lteHost: String

    /// Optional base URL for a Cloudflare/Tailscale/other tunnel.
    /// Example: "https://hairpi.example-tunnel.com"
    var tunnelBaseURL: String?

    var lastConnected: Date?
    var lastSeen: Date?

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int,
        username: String,
        lteHost: String,
        tunnelBaseURL: String? = nil,
        lastConnected: Date? = nil,
        lastSeen: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.lteHost = lteHost
        self.tunnelBaseURL = tunnelBaseURL
        self.lastConnected = lastConnected
        self.lastSeen = lastSeen
    }
}
