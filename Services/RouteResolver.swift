//
//  RouteResolver.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 11/2/25.
//


//
//  RouteResolver.swift
//  SSHSwiftUIDemo
//
//  Created by You on 11/02/25.
//

import Foundation
import os.log

public actor RouteResolver {
    public let config: RouteConfig
    private let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "RouteResolver")

    // Simple sticky cache so we don’t probe every tap:
    private var lastGood: [String: EffectiveRoute] = [:]   // key = path

    public init(config: RouteConfig) {
        self.config = config
    }

    /// Resolve a concrete URL for a path using either a fixed override or Auto (probe in order).
    /// Returns the chosen route and the full URL.
    public func resolve(override: RouteOverride, path: String, timeout: TimeInterval = 2.0) async -> (EffectiveRoute, URL) {
        switch override {
        case .lan:    return (.lan,    config.url(for: .lan,    path: path))
        case .lte:    return (.lte,    config.url(for: .lte,    path: path))
        case .tunnel: return (.tunnel, config.url(for: .tunnel, path: path))
        case .auto:
            // Try sticky winner first
            if let sticky = lastGood[path] {
                let u = config.url(for: sticky, path: path)
                if await checkReachable(u, timeout: timeout) {
                    return (sticky, u)
                }
            }
            // Probe in declared Auto order
            for r in config.autoCandidates {
                let u = config.url(for: r, path: path)
                if await checkReachable(u, timeout: timeout) {
                    lastGood[path] = r
                    return (r, u)
                }
            }
            // Fallback: LAN URL even if dead (so caller can show error)
            let fb = config.url(for: .lan, path: path)
            log.debug("[Route][Auto][Fallback] \(fb.absoluteString, privacy: .public)")
            return (.lan, fb)
        }
    }

    // MARK: - HEAD/GET probe

    private func checkReachable(_ url: URL, timeout: TimeInterval) async -> Bool {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD" // cheap for HLS/CGI; servers that dislike HEAD still often return 200/405
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse {
                // Accept 2xx and 405 (method not allowed) — 405 means GET would work.
                let ok = (200...299).contains(http.statusCode) || http.statusCode == 405
                if ok { return true }
            }
        } catch {}
        // Try GET if HEAD failed (some CGI scripts don’t like HEAD)
        do {
            var r = req; r.httpMethod = "GET"
            let (_, resp) = try await URLSession.shared.data(for: r)
            if let http = resp as? HTTPURLResponse {
                return (200...299).contains(http.statusCode)
            }
        } catch {}
        return false
    }
}