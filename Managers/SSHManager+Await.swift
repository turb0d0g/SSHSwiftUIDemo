//
//  SSHManager+Await.swift
//  SSHSwiftUIDemo
//

//  SSHManager+Await.swift
//  SSHSwiftUIDemo
//
//  Async helpers for SSHManager: waitForConnectionResult(timeout:)
//  Non-blocking: uses Combine → Async and a timeout watchdog. No semaphores, no main-thread stalls.

import Foundation
import Combine
import OSLog

extension SSHManager {
    /// Wait until the SSH session transitions to `.connected` or a terminal failure.
    /// - Returns: `.connected` or `.failed(...)` (also treats `.disconnected` as failure)
    /// - Important: Non-blocking; safe to call from @MainActor contexts.
    func waitForConnectionResult(timeout: TimeInterval) async -> ConnectionState {
        let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "SSHManagerAwait")

        // Fast path: if already connected/failed, finish immediately
        let initial = await state.value
        switch initial {
        case .connected:
            log.debug("[SSHAwait] fast-path: already connected")
            return .connected
        case .failed(let err):
            log.debug("[SSHAwait] fast-path: already failed \(String(describing: err), privacy: .public)")
            return .failed(err)
        default:
            break
        }

        // Bridge CurrentValueSubject → AsyncStream inside the actor
        let stream: AsyncStream<ConnectionState> = await {
            var cancellable: AnyCancellable?
            return AsyncStream { continuation in
                // Start by yielding current state so callers see the immediate picture
                continuation.yield(self.state.value)

                cancellable = self.state.sink { newState in
                    continuation.yield(newState)
                }
                continuation.onTermination = { _ in
                    cancellable?.cancel()
                    cancellable = nil
                }
            }
        }()

        // Race: (1) state stream to reach terminal state, (2) timeout
        do {
            return try await withThrowingTaskGroup(of: ConnectionState.self) { group in
                // 1) State listener task
                group.addTask {
                    for await s in stream {
                        switch s {
                        case .connected:
                            log.debug("[SSHAwait] connected")
                            return .connected
                        case .failed(let e):
                            log.debug("[SSHAwait] failed \(String(describing: e), privacy: .public)")
                            return .failed(e)
                        case .disconnected:
                            log.debug("[SSHAwait] disconnected before connect")
                            return .failed(NSError(domain: "SSHSwiftUIDemo",
                                                   code: -101,
                                                   userInfo: [NSLocalizedDescriptionKey: "SSH disconnected"]))
                        default:
                            // keep waiting on .idle / .connecting
                            break
                        }
                    }
                    // Stream ended unexpectedly: treat as failure
                    return .failed(NSError(domain: "SSHSwiftUIDemo",
                                           code: -102,
                                           userInfo: [NSLocalizedDescriptionKey: "SSH state stream ended"]))
                }

                // 2) Timeout watchdog
                group.addTask {
                    let ns = UInt64(max(0, timeout) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: ns)
                    log.debug("[SSHAwait] timeout after \(timeout, privacy: .public)s")
                    return .failed(NSError(domain: "SSHSwiftUIDemo",
                                           code: -100,
                                           userInfo: [NSLocalizedDescriptionKey: "SSH connect timeout"]))
                }

                // First task to finish wins
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch {
            log.error("[SSHAwait] unexpected error \(error.localizedDescription, privacy: .public)")
            return .failed(error)
        }
    }
}
