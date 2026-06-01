//
//  ExecError.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 12/25/25.
//


//
//  SSHManager+Exec.swift
//  SSHSwiftUIDemo
//
//  Adds a simple "exec a command and capture stdout until sentinel" on top of the
//  existing interactive shell channel.
//
//  NOTE: This is not a true "exec channel" (NIOSSH has separate channel types),
//  but for your app (remote file viewer) it’s perfect: send command -> read until marker.
//
//
//  SSHManager+Exec.swift
//  SSHSwiftUIDemo
//
//  Adds a simple "exec a command and capture stdout until sentinel" on top of the
//  existing interactive shell channel.
//
//  NOTE: This is not a true "exec channel" (NIOSSH has separate channel types),
//  but for your app (remote file viewer) it’s perfect: send command -> read until marker.
//

import Foundation
import Combine

extension SSHManager {

    enum ExecError: Error, CustomStringConvertible {
        case notConnected
        case timedOut(TimeInterval)
        case cancelled
        case remoteNonZeroExit(Int)
        case outputDecode

        var description: String {
            switch self {
            case .notConnected: return "SSH not connected"
            case .timedOut(let t): return "Command timed out after \(t)s"
            case .cancelled: return "Command cancelled"
            case .remoteNonZeroExit(let code): return "Remote command failed (exit=\(code))"
            case .outputDecode: return "Failed to decode output"
            }
        }
    }

    /// Executes a command by sending it through the interactive shell and collecting bytes
    /// until a unique sentinel line is observed.
    ///
    /// - Important: This assumes the remote shell prints the sentinel reliably.
    /// - Returns: stdout+stderr as captured by the shell channel (as `String`).
    func exec(
        command: String,
        timeout: TimeInterval = 8.0,
        requireZeroExit: Bool = false
    ) async throws -> String {

        // Sanity: ensure connected
        let s = state.value
        guard case .connected = s else {
            print("[SSHManager.exec] not connected; state=\(s)")
            throw ExecError.notConnected
        }

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let sentinelPrefix = "__SSH_SWIFT_UIDEMO_DONE__"
        let sentinelLine = "\(sentinelPrefix)\(token)__"

        print("[SSHManager.exec] start session=\(sessionID) timeout=\(timeout)s token=\(token)")
        print("[SSHManager.exec] command=\(command)")

        // Wrap command so we always emit sentinel + exit code.
        // Use printf (portable). Add a leading newline before sentinel to avoid it gluing to output.
        // We also redirect `printf` to stdout.
        let wrapped =
        """
        ( \(command) ); EC=$?; printf "\\n\(sentinelLine)%d\\n" "$EC"
        """

        // Collector state
        var buffer = Data()
        var finished = false
        var exitCode: Int? = nil

        // Convert sentinel to bytes once
        let sentinelBytes = Data((sentinelLine).utf8)

        // Subscribe to only THIS session’s bytes
        var cancellable: AnyCancellable?

        // A small helper to scan for sentinel in the accumulated buffer
        func tryConsumeSentinel() {
            guard !finished else { return }
            // Look for sentinel prefix bytes anywhere
            if let range = buffer.range(of: sentinelBytes) {
                // We found sentinel start. Now find end-of-line after it (newline).
                // We expect: \n__SSH...__<exit>\n
                let afterSentinelStart = range.upperBound
                if let nlRange = buffer[afterSentinelStart...].firstRange(of: Data([0x0A])) { // '\n'
                    let codeData = buffer[afterSentinelStart..<nlRange.lowerBound]
                    let codeStr = String(decoding: codeData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let code = Int(codeStr) {
                        exitCode = code
                    }

                    // Keep everything BEFORE the sentinel (and drop the newline that preceded it if present)
                    let before = buffer[..<range.lowerBound]
                    buffer = Data(before)
                    finished = true
                }
            }
        }

        // Waiter task (timeout)
        let deadline = Date().addingTimeInterval(timeout)

        // Use a continuation so we can resolve from Combine callback
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in

                cancellable = outputTagged
                    .sink { (sid, chunk) in
                        guard sid == self.sessionID else { return }
                        guard !finished else { return }
                        buffer.append(chunk)
                        tryConsumeSentinel()
                        if finished {
                            cancellable?.cancel()
                            cancellable = nil

                            let outStr = String(decoding: buffer, as: UTF8.self)

                            let code = exitCode ?? -999
                            print("[SSHManager.exec] done token=\(token) exit=\(code) bytes=\(buffer.count)")

                            if requireZeroExit, code != 0 {
                                cont.resume(throwing: ExecError.remoteNonZeroExit(code))
                            } else {
                                cont.resume(returning: outStr)
                            }
                        }
                    }

                // Fire the command
                Task {
                    do {
                        // Ensure newline at end so shell executes it
                        let line = wrapped.hasSuffix("\n") ? wrapped : (wrapped + "\n")
                        try await self.send(ArraySlice(line.utf8))
                    } catch {
                        print("[SSHManager.exec] send failed token=\(token) err=\(error)")
                        cancellable?.cancel()
                        cancellable = nil
                        cont.resume(throwing: error)
                    }
                }

                // Timeout watchdog
                Task {
                    while !finished {
                        if Task.isCancelled {
                            cancellable?.cancel()
                            cancellable = nil
                            cont.resume(throwing: ExecError.cancelled)
                            return
                        }
                        if Date() >= deadline {
                            print("[SSHManager.exec] timeout token=\(token) collectedBytes=\(buffer.count)")
                            cancellable?.cancel()
                            cancellable = nil
                            cont.resume(throwing: ExecError.timedOut(timeout))
                            return
                        }
                        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                    }
                }
            }
        } onCancel: {
            print("[SSHManager.exec] cancelled token=\(token)")
        }
    }
}

private extension Data {
    /// Finds first range of `needle` within self (simple helper)
    func firstRange(of needle: Data) -> Range<Data.Index>? {
        return self.range(of: needle)
    }
}
/*
 import Foundation
import Combine

extension SSHManager {

    enum ExecError: Error, CustomStringConvertible {
        case notConnected
        case timedOut(TimeInterval)
        case cancelled
        case remoteNonZeroExit(Int)
        case outputDecode

        var description: String {
            switch self {
            case .notConnected: return "SSH not connected"
            case .timedOut(let t): return "Command timed out after \(t)s"
            case .cancelled: return "Command cancelled"
            case .remoteNonZeroExit(let code): return "Remote command failed (exit=\(code))"
            case .outputDecode: return "Failed to decode output"
            }
        }
    }

    /// Executes a command by sending it through the interactive shell and collecting bytes
    /// until a unique sentinel line is observed.
    ///
    /// - Important: This assumes the remote shell prints the sentinel reliably.
    /// - Returns: stdout+stderr as captured by the shell channel (as `String`).
    func exec(
        command: String,
        timeout: TimeInterval = 8.0,
        requireZeroExit: Bool = false
    ) async throws -> String {

        // Sanity: ensure connected
        let s = state.value
        guard case .connected = s else {
            print("[SSHManager.exec] ❌ not connected; state=\(s)")
            throw ExecError.notConnected
        }

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let sentinelPrefix = "__SSH_SWIFT_UIDEMO_DONE__"
        let sentinelLine = "\(sentinelPrefix)\(token)__"

        print("[SSHManager.exec] ▶️ start session=\(sessionID) timeout=\(timeout)s token=\(token)")
        print("[SSHManager.exec] ▶️ command=\(command)")

        // Wrap command so we always emit sentinel + exit code.
        // Use printf (portable). Add a leading newline before sentinel to avoid it gluing to output.
        // We also redirect `printf` to stdout.
        let wrapped =
        """
        ( \(command) ); EC=$?; printf "\\n\(sentinelLine)%d\\n" "$EC"
        """

        // Collector state
        var buffer = Data()
        var finished = false
        var exitCode: Int? = nil

        // Convert sentinel to bytes once
        let sentinelBytes = Data((sentinelLine).utf8)

        // Subscribe to only THIS session’s bytes
        var cancellable: AnyCancellable?

        // A small helper to scan for sentinel in the accumulated buffer
        func tryConsumeSentinel() {
            guard !finished else { return }
            // Look for sentinel prefix bytes anywhere
            if let range = buffer.range(of: sentinelBytes) {
                // We found sentinel start. Now find end-of-line after it (newline).
                // We expect: \n__SSH...__<exit>\n
                let afterSentinelStart = range.upperBound
                if let nlRange = buffer[afterSentinelStart...].firstRange(of: Data([0x0A])) { // '\n'
                    let codeData = buffer[afterSentinelStart..<nlRange.lowerBound]
                    let codeStr = String(decoding: codeData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let code = Int(codeStr) {
                        exitCode = code
                    }

                    // Keep everything BEFORE the sentinel (and drop the newline that preceded it if present)
                    let before = buffer[..<range.lowerBound]
                    buffer = Data(before)
                    finished = true
                }
            }
        }

        // Waiter task (timeout)
        let deadline = Date().addingTimeInterval(timeout)

        // Use a continuation so we can resolve from Combine callback
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in

                cancellable = outputTagged
                    .sink { (sid, chunk) in
                        guard sid == self.sessionID else { return }
                        guard !finished else { return }
                        buffer.append(chunk)
                        tryConsumeSentinel()
                        if finished {
                            cancellable?.cancel()
                            cancellable = nil

                            let outStr = String(decoding: buffer, as: UTF8.self)

                            let code = exitCode ?? -999
                            print("[SSHManager.exec] ✅ done token=\(token) exit=\(code) bytes=\(buffer.count)")

                            if requireZeroExit, code != 0 {
                                cont.resume(throwing: ExecError.remoteNonZeroExit(code))
                            } else {
                                cont.resume(returning: outStr)
                            }
                        }
                    }

                // Fire the command
                Task {
                    do {
                        // Ensure newline at end so shell executes it
                        let line = wrapped.hasSuffix("\n") ? wrapped : (wrapped + "\n")
                        try await self.send(ArraySlice(line.utf8))
                    } catch {
                        print("[SSHManager.exec] ❌ send failed token=\(token) err=\(error)")
                        cancellable?.cancel()
                        cancellable = nil
                        cont.resume(throwing: error)
                    }
                }

                // Timeout watchdog
                Task {
                    while !finished {
                        if Task.isCancelled {
                            cancellable?.cancel()
                            cancellable = nil
                            cont.resume(throwing: ExecError.cancelled)
                            return
                        }
                        if Date() >= deadline {
                            print("[SSHManager.exec] ⏰ timeout token=\(token) collectedBytes=\(buffer.count)")
                            cancellable?.cancel()
                            cancellable = nil
                            cont.resume(throwing: ExecError.timedOut(timeout))
                            return
                        }
                        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                    }
                }
            }
        } onCancel: {
            print("[SSHManager.exec] 🛑 cancelled token=\(token)")
        }
    }
}

private extension Data {
    /// Finds first range of `needle` within self (simple helper)
    func firstRange(of needle: Data) -> Range<Data.Index>? {
        return self.range(of: needle)
    }
}
*/
