//
//  ARCTestStatusBus.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 1/3/26.
//


//
//  ARCTestStatusBus.swift
//  SSHSwiftUIDemo
//
//  Shared status bus for ARCTestMiniPanel -> UnifiedDiagnosticsHUDOverlay.
//  Keeps HUD wiring simple and avoids EnvironmentObject churn.
//
//  iOS 16+
//

import Foundation

public actor ARCTestStatusBus {
    public static let shared = ARCTestStatusBus()

    public enum Phase: String, Sendable {
        case idle
        case running
        case cancelled
        case finished
    }

    public struct Snapshot: Sendable, Equatable {
        public var title: String = "—"
        public var summary: String = ""
        public var isPass: Bool? = nil
        public var observed: Int = 0
        public var expected: Int = 0
        public var updatedAt: Date = .distantPast

        // NEW: pipeline status
        public var phase: Phase = .idle
        public var suiteIndex: Int = 0          // 1-based for display
        public var suiteCount: Int = 0
        public var iteration: Int = 0           // 1-based for display
        public var iterationsTotal: Int = 0

        public init() {}
    }

    private var snap = Snapshot()

    private init() {}

    public func set(_ s: Snapshot) {
        snap = s
    }

    public func get() -> Snapshot {
        snap
    }
}
