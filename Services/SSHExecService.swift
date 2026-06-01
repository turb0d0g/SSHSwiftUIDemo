//
//  SSHExecService.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 11/11/25.
//


//  SSHExecService.swift
//  SSHSwiftUIDemo
//
//  Reuses a single SSHManager per account (username@host:port).
//  Provides async `run(command:timeout:)` and `kill(pid:)` on top of a PTY shell.
//  One Combine subscription per pool entry; auto-connects; hard timeouts;
//  bounded buffering to avoid memory blowups.

import Foundation
import Combine
import OSLog

public actor SSHExecService {
    public static let shared = SSHExecService()
    private let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "SSHExec")

    // Pool keyed by account identifier
    private var pool: [Key: Entry] = [:]

    public struct Key: Hashable {
        let host: String
        let port: Int
        let username: String
        var id: String { "\(username)@\(host):\(port)" }
    }

    private final class Entry {
        let key: Key
        let manager: SSHManager
        var outputCancellable: AnyCancellable?
        // Broadcast remote bytes to awaiters; single fan-out per pooled manager
        let outputSubject = PassthroughSubject<Data, Never>()
        init(key: Key, manager: SSHManager) { self.key = key; self.manager = manager }
    }

    // Ensure an Entry exists, connected and subscribed
    private func getEntry(for key: Key, password: String?, timeout: TimeInterval) async throws -> Entry {
        if let e = pool[key] { return e }

        let mgr = SSHManager()
        let e = Entry(key: key, manager: mgr)

        // Bridge manager.output → entry.outputSubject
        e.outputCancellable = mgr.output.sink { [weak e] data in
            // keep the chain short; dropping if entry deallocated
            e?.outputSubject.send(data)
        }

        pool[key] = e

        // Connect if not connected
        await mgr.connect(host: key.host,
                          port: key.port,
                          username: key.username,
                          passwordProvider: {  password })

        let state = await mgr.waitForConnectionResult(timeout: timeout)
        switch state {
        case .connected:
            log.info("[Pool] connected \(key.id, privacy: .public)")
            return e
        case .failed(let err):
            // cleanup on failure
            await remove(key: key)
            throw err
        default:
            await remove(key: key)
            throw NSError(domain: "SSHSwiftUIDemo", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "SSH connect failed: \(state)"])
        }
    }

    private func remove(key: Key) async {
        if let e = pool.removeValue(forKey: key) {
            e.outputCancellable?.cancel()
            Task.detached { await e.manager.disconnect() }
        }
    }

    // Public API: run a command and capture until sentinel
    public func run(host: String,
                    port: Int,
                    username: String,
                    password: String?,
                    command: String,
                    timeout: TimeInterval,
                    maxBytes: Int = 512 * 1024) async throws -> String
    {
        let key = Key(host: host, port: port, username: username)
        let entry = try await getEntry(for: key, password: password, timeout: timeout)

        // Unique sentinel per invocation
        let sentinel = "__END_\(UUID().uuidString)__"
        let fullCmd = "\(command); printf \"\\n\(sentinel)\\n\" 2>&1\n"
        let bytes: [UInt8] = Array(fullCmd.utf8)

        // Async stream for this call; subscribe to the pooled subject
        let stream = AsyncStream<Data> { continuation in
            let c = entry.outputSubject.sink { data in
                continuation.yield(data)
            }
            continuation.onTermination = { _ in c.cancel() }
        }

        // Send
        try await entry.manager.send(bytes[bytes.startIndex..<bytes.endIndex])

        // Accumulate until sentinel, with size and time caps
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        for await chunk in stream {
            buffer.append(chunk)
            if buffer.count > maxBytes {
                throw NSError(domain: "SSHSwiftUIDemo", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "Output exceeded \(maxBytes/1024)KB"])
            }
            if let s = String(data: buffer, encoding: .utf8), s.contains(sentinel) { break }
            if Date() > deadline {
                throw NSError(domain: "SSHSwiftUIDemo", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "Command timeout"])
            }
        }

        var text = String(data: buffer, encoding: .utf8) ?? ""
        if let r = text.range(of: sentinel) { text.removeSubrange(r.lowerBound..<text.endIndex) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func kill(host: String,
                     port: Int,
                     username: String,
                     password: String?,
                     pid: Int,
                     timeout: TimeInterval = 5) async throws
    {
        _ = try await run(host: host,
                          port: port,
                          username: username,
                          password: password,
                          command: "kill -TERM \(pid) 2>&1; printf \"[KILL] done\\n\"",
                          timeout: timeout)
    }

    // Optional: drop a pooled connection explicitly
    public func close(host: String, port: Int, username: String) async {
        await remove(key: Key(host: host, port: port, username: username))
    }
}
