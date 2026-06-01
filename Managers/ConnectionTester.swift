//
//  ConnectionTester.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 7/29/25.
//

//
//  ConnectionTester.swift
//  SSHSwiftUIDemo
//
//  Created by You on 2025-09-14.
//

import Foundation

/// Lightweight, single-shot SSH connection test with friendly classification.
/// Uses your SSHManager under the hood.
@MainActor
struct ConnectionTester {

    enum Result: Equatable {
        case success
        case authFailed                      // bad username/password or auth method refused
        case hostUnreachable                 // no route, DNS failure
        case connectionRefused               // TCP reset / service not listening
        case timeout                         // overall timeout while connecting/authing
        case timedOut                        //
        case hostKeyChanged                  // host key mismatch (fingerprint changed)
        case serverClosedEarly               // EOF / server hung up before/at auth
        case failure
        case disconnected
        case unknown(message: String)        // anything else (we’ll show a readable message)
    }

    /// Test a password-based SSH connection and return a friendly Result.
    /// - Parameters:
    ///   - host / port / username / password: obvious
    ///   - timeout: overall time budget for connect + auth
    static func test(
        host: String,
        port: Int,
        username: String,
        password: String,
        timeout: TimeInterval = 10
    ) async -> Result {

        // Print banner
        print("[ConnectionTester] Starting test → \(username)@\(host):\(port) timeout=\(timeout)s")

        let sessionID = UUID()
        let ssh = SSHManager() // assumes your SSHManager init(sessionID:) exists; if not, use default init

        // Ensure teardown even if errors fly
        defer {
            Task.detached { [sessionID] in
                await ssh.disconnect()
                print("[ConnectionTester] Disconnected test session (session=\(sessionID))")
            }
        }

        // Connect with a one-shot password provider
        await ssh.connect(host: host, port: port, username: username) {
            password
        }

        // Wait for a terminal state or the timeout
        let outcome = await ssh.waitForConnectionResult(timeout: timeout)

        switch outcome {
        case .connected:
            print("[ConnectionTester] ✅ Success")
            return .success

        case .failed(let error):
            let mapped = classify(error)
            logMapping(error, mapped: mapped)
            return mapped

        case .idle, .connecting:
            print("[ConnectionTester] ⏱️ Timeout (no terminal state reached)")
            return .timeout

        case .disconnected:
            // We didn’t expect a clean disconnected here; classify as early close.
            print("[ConnectionTester] 🚪 Server closed early (disconnected)")
            return .serverClosedEarly
        }
    }
}


// MARK: - Error mapping

private func classify(_ error: Error) -> ConnectionTester.Result {
    let ns = error as NSError
    let code = ns.code
    let domain = ns.domain
    let msg = (error as CustomStringConvertible).description.lowercased()

    // Common network buckets first (URLSession-style) — sometimes you’ll see these if
    // you probe HLS/HTTP from the same flow, but we keep them here for completeness.
    if domain == NSURLErrorDomain {
        switch code {
        case NSURLErrorTimedOut:
            return .timeout
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
            return .hostUnreachable
        case NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet:
            return .hostUnreachable
        case NSURLErrorCannotConnectToHost: //  -1004
            return .connectionRefused
        default:
            break
        }
    }

    // NIO-ish hints (string matching; NIO errors aren’t stable/public across versions)
    if msg.contains("refused") || msg.contains("connection refused") || msg.contains("connect failed: 61") {
        return .connectionRefused
    }
    if msg.contains("timed out") || msg.contains("timeout") {
        return .timeout
    }
    if msg.contains("end of file") || msg.contains("eof") {
        // Very frequently OpenSSH closes after MaxAuthTries → treat as auth failed
        return .authFailed
    }
    if msg.contains("permission denied") {
        return .authFailed
    }
    if msg.contains("host key") && msg.contains("mismatch") {
        return .hostKeyChanged
    }
    if msg.contains("no route to host") || msg.contains("network is unreachable") {
        return .hostUnreachable
    }
    if msg.contains("closed") && msg.contains("before authentication") {
        return .serverClosedEarly
    }

    // Fallback
    return .unknown(message: (error as NSError).localizedDescription)
}

private func logMapping(_ error: Error, mapped: ConnectionTester.Result) {
    print("[ConnectionTester] ❌ Failed with error: \(error)")
    switch mapped {
    case .authFailed:
        print("[ConnectionTester] → Classified as AUTH FAILED (bad credentials or server refused password).")
    case .hostUnreachable:
        print("[ConnectionTester] → Classified as HOST UNREACHABLE (DNS / network).")
    case .connectionRefused:
        print("[ConnectionTester] → Classified as CONNECTION REFUSED (service not listening / firewall).")
    case .timeout:
        print("[ConnectionTester] → Classified as TIMEOUT (connect/auth took too long).")
    case .hostKeyChanged:
        print("[ConnectionTester] → Classified as HOST KEY CHANGED (fingerprint mismatch).")
    case .serverClosedEarly:
        print("[ConnectionTester] → Classified as SERVER CLOSED EARLY (hung up at/near auth).")
    case .unknown(let m):
        print("[ConnectionTester] → Classified as UNKNOWN: \(m)")
    case .timedOut:
        print("[ConnectionTester] → Classified as TIMED OUT (connect/auth timed out).")
    case .failure:
        print("[ConnectionTester] → Classified as FAILURE (unknown reason).")
    case .disconnected:
        print("[ConnectionTester] → Classified as DISCONNECTED (connection dropped).")
    case .success:
        break
    }
}
