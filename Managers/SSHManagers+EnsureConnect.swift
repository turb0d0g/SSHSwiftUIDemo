//
//  SSHManager+EnsureConnected.swift
//  SSHSwiftUIDemo
//
//  Created by You on 11/06/25.
//

import Foundation
import OSLog

extension SSHManager {
    /// Waits briefly for an in-flight connection to settle and throws if not connected.
    /// Does **not** initiate a connection; upstream code is responsible for calling your connect logic.
    /// Returns the final state for optional callers who care.
    @discardableResult
    func ensureConnected(timeout: TimeInterval = 10) async throws -> ConnectionState {
        // Fast path.
        switch state.value {
        case .connected:
            return .connected
        case .failed(let err):
            throw err
        case .disconnected:
            throw SSHError.disconnected
        case .idle, .connecting:
            break
        }

        // Slow path: let any in-flight connect finish.
        let final = await waitForConnectionResult(timeout: timeout)

        switch final {
        case .connected:
            return .connected
        case .failed(let err):
            throw err
        case .disconnected, .idle, .connecting:
            // Treat anything non-connected at this point as a disconnect.
            throw SSHError.disconnected
        }
    }
}
