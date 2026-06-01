//
//  SSHManager+Pool.swift
//  SSHSwiftUIDemo
//
//  Created by You on 11/06/25.
//

import Foundation

// MARK: - Lightweight singleton pool for per-device SSHManager instances
extension SSHManager {
    private struct Key: Hashable {
        let host: String
        let port: Int
        let username: String

        init(device: Device) {
            self.host = device.host
            self.port = device.port
            self.username = device.username
        }
    }

    private static var _lock = NSLock()
    private static var _pool: [Key: SSHManager] = [:]

    /// Returns a stable `SSHManager` instance keyed by (host, port, username).
    /// Thread-safe and synchronous so you can call it from SwiftUI without `await`.
    static func shared(for device: Device) -> SSHManager {
        let key = Key(device: device)

        _lock.lock()
        defer { _lock.unlock() }

        if let existing = _pool[key] {
            return existing
        }

        // Prefer your designated initializer. If your `SSHManager` uses a different init,
        // change the line below accordingly (e.g., SSHManager(device:), or SSHManager(host:port:username:)).
        let created = SSHManager()
        _pool[key] = created
        return created
    }
}
