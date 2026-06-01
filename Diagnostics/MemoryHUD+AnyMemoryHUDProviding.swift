//
//  MemoryHUD+AnyMemoryHUDProviding.swift
//  SSHSwiftUIDemo
//
//  Bridges MemoryHUDViewModel -> UnifiedDiagnosticsHUDOverlay memory provider.
//

import Foundation

extension MemoryHUDViewModel: AnyMemoryHUDProviding {

    public var footprintMB: Double {
        state.latest?.footprintMB ?? 0
    }

    public var residentMB: Double {
        state.latest?.residentMB ?? 0
    }

    public var deltaMB: Double {
        state.deltaMB ?? 0
    }

    public var slopeMBPerMin: Double {
        state.slopeMBPerMin ?? 0
    }

    public var statusText: String {
        // Matches your Level + running state
        let lvl = state.level.rawValue.uppercased()
        let run = state.isRunning ? "ON" : "OFF"
        if let err = state.lastError, !err.isEmpty {
            return "\(lvl) • \(run) • \(err)"
        }
        return "\(lvl) • \(run)"
    }
}
