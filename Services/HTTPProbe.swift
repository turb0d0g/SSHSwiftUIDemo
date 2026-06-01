//
//  HTTPProbe.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 11/7/25.
//


//
//  HTTPProbe.swift
//  SSHSwiftUIDemo
//

import Foundation
import OSLog

enum HTTPProbe {
    private static let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "HTTPProbe")

    static func probe(_ url: URL, timeout: TimeInterval = 3.0) async -> DeviceServiceStatus {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                log.debug("[HTTPProbe] \(url.absoluteString, privacy: .public) -> \(http.statusCode, privacy: .public) OK")
                return .online
            } else if let http = resp as? HTTPURLResponse {
                log.debug("[HTTPProbe] \(url.absoluteString, privacy: .public) -> \(http.statusCode, privacy: .public) not OK")
                return .offline
            }
            log.debug("[HTTPProbe] \(url.absoluteString, privacy: .public) -> non-HTTP response")
            return .offline
        } catch {
            log.debug("[HTTPProbe] \(url.absoluteString, privacy: .public) error: \(error.localizedDescription, privacy: .public)")
            return .offline
        }
    }
}