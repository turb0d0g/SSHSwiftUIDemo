//
//  RouteConfig.swift
//  SSHSwiftUIDemo
//
//  Created by You on 11/02/25.
//

import Foundation

public enum RouteOverride: String, CaseIterable, Sendable {
    case auto, lte, lan, tunnel
}

public enum EffectiveRoute: String, Sendable, CaseIterable, Hashable {
    case lte, lan, tunnel
}

public struct RouteConfig: Sendable, Hashable {
    public let lanHost: String
    public let lteHost: String?
    public let tunnelBaseURL: URL?
    public let hlsPath: String
    public let autoOrder: [EffectiveRoute]

    public init(
        lanHost: String,
        lteHost: String?,
        tunnelBaseURL: URL?,
        hlsPath: String = "/hls/stream.m3u8",
        autoOrder: [EffectiveRoute] = [.lte, .lan, .tunnel]
    ) {
        self.lanHost = lanHost
        self.lteHost = lteHost
        self.tunnelBaseURL = tunnelBaseURL
        self.hlsPath = hlsPath.hasPrefix("/") ? hlsPath : "/" + hlsPath
        self.autoOrder = autoOrder
    }

    /// Build a full HLS URL for a concrete route.
    @inlinable
    public func url(for route: EffectiveRoute) -> URL {
        switch route {
        case .lte:
            return Self.makeHTTPURL(host: lteHost ?? lanHost, path: hlsPath)
        case .lan:
            return Self.makeHTTPURL(host: lanHost, path: hlsPath)
        case .tunnel:
            if let base = tunnelBaseURL,
               var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) {
                comps.scheme = comps.scheme ?? "http"
                comps.path = hlsPath
                return comps.url ?? Self.makeHTTPURL(host: "127.0.0.1", path: hlsPath)
            }
            return Self.makeHTTPURL(host: "127.0.0.1", path: hlsPath)
        }
    }

    /// Routes to try in Auto mode, respecting provided fields.
    @inlinable
    public var autoCandidates: [EffectiveRoute] {
        var list: [EffectiveRoute] = []
        for r in autoOrder {
            switch r {
            case .lte    where lteHost == nil:        continue
            case .tunnel where tunnelBaseURL == nil:  continue
            default: list.append(r)
            }
        }
        if !list.contains(.lan) { list.append(.lan) } // safety
        return list
    }

    // MARK: - Inlinable helper for URL building

    /// Visible to inlined callers; not public API surface.
    @usableFromInline
    static func makeHTTPURL(host: String, path: String) -> URL {
        // Allow "host:port" inline (e.g., "127.0.0.1:8080").
        if host.contains(":"), let u = URL(string: "http://\(host)\(path)") {
            return u
        }
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host
        comps.path = path
        return comps.url ?? URL(string: "http://\(host)\(path)")!
    }
}

public extension RouteConfig {
    @inlinable
    func url(for route: EffectiveRoute, path: String) -> URL {
        let p = path.hasPrefix("/") ? path : "/"+path
        switch route {
        case .lte:
            return Self.makeHTTPURL(host: lteHost ?? lanHost, path: p)
        case .lan:
            return Self.makeHTTPURL(host: lanHost, path: p)
        case .tunnel:
            if let base = tunnelBaseURL, var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) {
                comps.scheme = comps.scheme ?? "http"
                comps.path = p
                return comps.url ?? Self.makeHTTPURL(host: "127.0.0.1", path: p)
            }
            return Self.makeHTTPURL(host: "127.0.0.1", path: p)
        }
    }
}
