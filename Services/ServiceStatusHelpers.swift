//
//  ServiceStatusHelpers.swift
//  SSHSwiftUIDemo
//

import Foundation

// MARK: - Human-readable name for UI/logs
/*extension DeviceServiceStatus {
    var name: String {
        switch self {
        case .testing:    return "testing"
        case .connecting: return "connecting"
        case .unknown:    return "unknown"
        case .online:     return "online"
        case .offline:    return "offline"
        }
    }
}
*/
// MARK: - SSH Result → DeviceServiceStatus
extension DeviceServiceStatus {
    static func from(_ r: ConnectionTester.Result) -> DeviceServiceStatus {
        switch r {
        case .success:             return .online
        case .authFailed:          return .online   // TCP up + SSH reachable, creds bad ⇒ service itself is online
        case .serverClosedEarly:   return .online   // server reachable but closed ⇒ still classify service reachable
        case .hostUnreachable:     return .offline
        case .connectionRefused:   return .offline
        case .timeout, .timedOut:  return .offline
        case .hostKeyChanged:      return .online   // reachable; surface mismatch elsewhere if you want
        case .failure, .disconnected:
            return .offline
        case .unknown:
            return .unknown
        }
    }
}

// MARK: - Summary helper for your triple
extension ServiceTriple {
    var summary: String { "ssh=\(ssh.name), http=\(http.name), hls=\(hls.name)" }
}
