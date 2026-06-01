//
//  MemoryHUDViewModel.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 12/23/25.
//


//
//  MemoryHUDViewModel.swift
//  SSHSwiftUIDemo
//
//  Leak-truth HUD consumer.
//  - Uses recovered (lowest recent) footprint vs baseline.
//  - Preserves ARC test API used by MemoryHUDOverlay.
//  - Ignores transient spikes (AVPlayer, image decode) unless they don’t recover.
//
//  iOS 16+
//

import Foundation
import OSLog
import SwiftUI

@MainActor
public final class MemoryHUDViewModel: ObservableObject {

    public struct State: Equatable, Sendable {
        public var latest: MemorySnapshot?
        public var baseline: MemorySnapshot?

        /// Leak signal: (recoveredMB - baselineMB)
        public var deltaMB: Double?

        /// Leak signal slope: slope of recovered minima
        public var slopeMBPerMin: Double?

        public var level: Level = .ok
        public var isRunning: Bool = false
        public var lastUpdated: Date?
        public var lastError: String?

        // ARC test status (overlay expects these)
        public var arcIsRunning: Bool = false
        public var arcLastName: String = "—"
        public var arcLastMessage: String = "—"
        public var arcExpectedDeinits: Int = 0
        public var arcObservedDeinits: Int = 0
        public var arcLastFinishedAt: Date?

        public init() {}
    }

    public enum Level: String, CaseIterable, Sendable {
        case ok, warn, error
    }

    private let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "MemoryHUDVM")

    @Published public private(set) var state = State()

    private var recent: [MemorySnapshot] = []
    private let recentCapacity: Int = 180

    /// Window used to compute “recovered” memory (min over last N seconds).
    private let recoveryWindowSeconds: TimeInterval = 30

    private var consumeTask: Task<Void, Never>?
    private var arcTask: Task<Void, Never>?
    private var isAttached = false

    private let warnDeltaMB: Double
    private let errorDeltaMB: Double
    private let warnSlopeMBPerMin: Double
    private let errorSlopeMBPerMin: Double

    public init(
        warnDeltaMB: Double = 25,
        errorDeltaMB: Double = 75,
        warnSlopeMBPerMin: Double = 20,
        errorSlopeMBPerMin: Double = 50
    ) {
        self.warnDeltaMB = warnDeltaMB
        self.errorDeltaMB = errorDeltaMB
        self.warnSlopeMBPerMin = warnSlopeMBPerMin
        self.errorSlopeMBPerMin = errorSlopeMBPerMin

        print("[MemoryHUDVM] init warnDelta=\(warnDeltaMB)MB errDelta=\(errorDeltaMB)MB warnSlope=\(warnSlopeMBPerMin)MB/min errSlope=\(errorSlopeMBPerMin)MB/min")
    }

    deinit {
        print("[MemoryHUDVM] deinit → cancelling tasks")
        consumeTask?.cancel()
        arcTask?.cancel()
    }

    // MARK: - Stream wiring

    public func attach(to stream: AsyncStream<MemorySnapshot>, reason: String) {
        guard !isAttached else {
            print("[MemoryHUDVM] attach IGNORED (already attached)")
            return
        }
        isAttached = true
        state.isRunning = true
        print("[MemoryHUDVM] attach ACCEPTED reason=\(reason)")

        consumeTask = Task { [weak self] in
            guard let self else { return }
            print("[MemoryHUDVM] consume begin")
            for await snap in stream {
                self.ingest(snap)
                if Task.isCancelled { break }
            }
            print("[MemoryHUDVM] consume end")
        }
    }

    public func detach(reason: String = "detach") {
        print("[MemoryHUDVM] detach reason=\(reason)")
        consumeTask?.cancel()
        consumeTask = nil
        state.isRunning = false
        isAttached = false
    }

    public func resetBaseline(reason: String = "manualReset") {
        guard let latest = state.latest else {
            print("[MemoryHUDVM] resetBaseline skipped (no latest)")
            return
        }
        state.baseline = latest
        state.deltaMB = 0
        state.slopeMBPerMin = 0
        recomputeLevel()

        print(String(format: "[MemoryHUDVM] baseline reset reason=%@ footprintMB=%.2f", reason, latest.footprintMB))
    }

    // MARK: - ARC Tests (overlay buttons call these)

    public func runARCSmoke(count: Int = 250) {
        startARCTest(name: "Smoke x\(count)") { harness in
            await harness.runSmokeTest(count: count)
        }
    }

    public func runARCCycle(count: Int = 50) {
        startARCTest(name: "Cycle x\(count)") { harness in
            await harness.runCycleTest(count: count)
        }
    }

    public func runARCClosureCycle() {
        startARCTest(name: "Closure Capture") { harness in
            await harness.runClosureCaptureCycleTest()
        }
    }

    public func runARCCombineCycle() {
        startARCTest(name: "Combine Sink") { harness in
            await harness.runCombineSinkCycleTest()
        }
    }

    public func runARCTaskCycle() {
        startARCTest(name: "Task Capture") { harness in
            await harness.runTaskCaptureCycleTest()
        }
    }

    private func startARCTest(
        name: String,
        op: @escaping (ARCTestHarness) async -> ARCTestHarness.Status
    ) {
        if state.arcIsRunning {
            print("[MemoryHUDVM] ARC test already running; ignoring new request \(name)")
            return
        }

        arcTask?.cancel()
        state.arcIsRunning = true
        state.arcLastName = name
        state.arcLastMessage = "Running…"
        state.arcExpectedDeinits = 0
        state.arcObservedDeinits = 0
        state.arcLastFinishedAt = nil

        print("[MemoryHUDVM] ARC test start \(name)")

        arcTask = Task { [weak self] in
            guard let self else { return }

            let harness = ARCTestHarness.shared
            let st = await op(harness)

            await MainActor.run {
                self.state.arcIsRunning = false
                self.state.arcExpectedDeinits = st.expectedDeinits
                self.state.arcObservedDeinits = st.observedDeinits
                self.state.arcLastFinishedAt = st.finishedAt
                self.state.arcLastMessage = st.lastResult?.message ?? "Finished (no result?)"
            }

            print("[MemoryHUDVM] ARC test finished \(name)")
        }
    }

    // MARK: - Leak-truth ingest

    private func ingest(_ snap: MemorySnapshot) {
        state.latest = snap
        state.lastUpdated = snap.timestamp

        recent.append(snap)
        if recent.count > recentCapacity {
            recent.removeFirst(recent.count - recentCapacity)
        }

        // Baseline should be set explicitly (or at first sample if you want “something”).
        // For leak-truth, you’ll usually reset baseline manually before a test.
        if state.baseline == nil {
            state.baseline = snap
            print(String(format: "[MemoryHUDVM] baseline set footprintMB=%.2f", snap.footprintMB))
        }

        guard let base = state.baseline else { return }

        let recovered = recoveredFootprintMB()
        state.deltaMB = recovered.map { $0 - base.footprintMB }
        state.slopeMBPerMin = recoveredSlopeMBPerMin()

        recomputeLevel()
    }

    /// Min footprint over last N seconds = “recovered” floor.
    private func recoveredFootprintMB() -> Double? {
        let cutoff = Date().addingTimeInterval(-recoveryWindowSeconds)
        let window = recent.filter { $0.timestamp >= cutoff }
        return window.map(\.footprintMB).min()
    }

    /// Slope of the recovered minima (leak trend).
    private func recoveredSlopeMBPerMin() -> Double? {
        let cutoff = Date().addingTimeInterval(-recoveryWindowSeconds)
        let window = recent.filter { $0.timestamp >= cutoff }
        guard window.count >= 2 else { return nil }

        let first = window.first!
        let minSnap = window.min { $0.footprintMB < $1.footprintMB }!
        let dt = minSnap.timestamp.timeIntervalSince(first.timestamp)
        guard dt > 1 else { return nil }

        let dMB = minSnap.footprintMB - first.footprintMB
        return (dMB / dt) * 60.0
    }

    private func recomputeLevel() {
        let delta = state.deltaMB ?? 0
        let slope = state.slopeMBPerMin ?? 0

        let deltaLevel: Level = delta >= errorDeltaMB ? .error : (delta >= warnDeltaMB ? .warn : .ok)
        let slopeLevel: Level = slope >= errorSlopeMBPerMin ? .error : (slope >= warnSlopeMBPerMin ? .warn : .ok)

        let newLevel: Level = (deltaLevel == .error || slopeLevel == .error) ? .error
            : (deltaLevel == .warn || slopeLevel == .warn) ? .warn
            : .ok

        if newLevel != state.level {
            state.level = newLevel
            print(String(format: "[MemoryHUDVM] level → %@ recoveredΔ=%.2fMB slope=%.2fMB/min",
                         newLevel.rawValue, delta, slope))
        }
    }
}
