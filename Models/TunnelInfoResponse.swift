//
//  TunnelInfoResponse.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 12/16/25.
//


import Foundation

public struct TunnelInfoResponse: Decodable {
    public let ok: Bool?
    public let host: String?
    public let timestamp: String?
    public let home: String?

    public let tunnelIdent: String?
    public let tunnelId: String?
    public let tunnelTempURL: String?

    public let info: TunnelInfoPayload?
    public let routes: [TunnelRoute]?

    private enum CodingKeys: String, CodingKey {
        case ok, host, timestamp, home, info, routes, tunnelTempURL
        case tunnelIdent = "tunnel_ident"
        case tunnelId = "tunnel_id"
    }
}

public struct TunnelInfoPayload: Decodable {
    public let id: String?
    public let tunnel: String?
    public let created: String?
    public let connectors: [TunnelConnector]?
}

public struct TunnelHealthConnector: Decodable, Identifiable {
    public let id: String
    public let created: String?
    public let arch: String?
    public let version: String?
    public let originIp: String?
    public let edge: [String]?
}
