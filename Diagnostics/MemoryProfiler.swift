//
//  MemoryProfiler.swift
//  SSHSwiftUIDemo
//
//  Runtime memory sampler (Mach task_info) for detecting silent memory drift.
//  - Async/await polling loop (no Timer).
//  - Settled baseline (median window).
//  - AsyncStream<Snapshot> consumer model.
//  - Leak-safe: no cold-start baseline lies.
//
//  iOS 16+
//

import Foundation
import OSLog

#if canImport(Darwin)
import Darwin.Mach
#endif

// MARK: - Public types

public struct MemorySnapshot: Sendable, Equatable {
    public let timestamp: Date
    public let footprintBytes: UInt64
    public let residentBytes: UInt64
    public let virtualBytes: UInt64

    public var footprintMB: Double { Double(footprintBytes) / 1_048_576.0 }
    public var residentMB: Double { Double(residentBytes) / 1_048_576.0 }
    public var virtualMB: Double { Double(virtualBytes) / 1_048_576.0 }

    public init(
        timestamp: Date,
        footprintBytes: UInt64,
        residentBytes: UInt64,
        virtualBytes: UInt64
    ) {
        self.timestamp = timestamp
        self.footprintBytes = footprintBytes
        self.residentBytes = residentBytes
        self.virtualBytes = virtualBytes
    }
}

public struct MemoryProfilerConfig: Sendable, Equatable {
    public var interval: Duration = .seconds(1)
    public var ringBufferCapacity: Int = 180
    public var warnDeltaMB: Double = 25
    public var errorDeltaMB: Double = 75
    public var verbosePrintEachSample: Bool = false
    public init() {}
}

// MARK: - MemoryProfiler

public actor MemoryProfiler {
    public static let shared = MemoryProfiler()

    private let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "MemoryProfiler")

    private var config = MemoryProfilerConfig()
    private var samplerTask: Task<Void, Never>?

    /// Multi-subscriber fan-out.
    private var subscribers: [UUID: AsyncStream<MemorySnapshot>.Continuation] = [:]

    /// In-memory history.
    private var ring: [MemorySnapshot] = []

    // ✅ Settled baseline state
    private var baseline: MemorySnapshot?
    private var settleWindow: [MemorySnapshot] = []
    private let settleSampleCount = 10
    private var baselineIsSettled = false

    private let instanceID = UUID().uuidString
    private var isRunning = false

    private init() {
        log.info("[MemoryProfiler] init instanceID=\(self.instanceID, privacy: .public)")
        print("[MemoryProfiler] init instanceID=\(instanceID)")
    }

    // MARK: - Public API

    public func configure(_ newConfig: MemoryProfilerConfig) {
        config = newConfig
        log.info("[MemoryProfiler] configure instanceID=\(self.instanceID, privacy: .public) interval=\(String(describing: newConfig.interval), privacy: .public) ring=\(newConfig.ringBufferCapacity, privacy: .public)")
        print("[MemoryProfiler] configure instanceID=\(instanceID) interval=\(newConfig.interval) ring=\(newConfig.ringBufferCapacity)")
    }

    /// Subscribe to snapshots. This does NOT start the profiler; call `start(...)` elsewhere (AppInit).
    public func subscribe(reason: String) -> AsyncStream<MemorySnapshot> {
        let subID = UUID()
        log.info("[MemoryProfiler] subscribe ACCEPTED id=\(subID.uuidString, privacy: .public) reason=\(reason, privacy: .public)")

        return AsyncStream<MemorySnapshot>(bufferingPolicy: .bufferingNewest(64)) { cont in
            // Store continuation on actor
            Task { [weak self] in
                guard let self else { return }
                await self._addSubscriber(id: subID, cont: cont)
            }

            cont.onTermination = { @Sendable termination in
                Task { [weak self] in
                    guard let self else { return }
                    await self._removeSubscriber(id: subID, termination: termination)
                }
            }
        }
    }

    public func start(reason: String) {
        guard !isRunning else {
            print("[MemoryProfiler] start ignored (already running) reason=\(reason)")
            return
        }
        isRunning = true
        print("[MemoryProfiler] start accepted reason=\(reason)")

        samplerTask = Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
        }
    }

    public func stop(reason: String) {
        print("[MemoryProfiler] stop requested reason=\(reason)")
        samplerTask?.cancel()
        samplerTask = nil
        isRunning = false

        // Finish all subscribers and clear.
        for (_, cont) in subscribers { cont.finish() }
        subscribers.removeAll()
    }

    public func latest() -> MemorySnapshot? { ring.last }
    public func history() -> [MemorySnapshot] { ring }

    public func resetBaseline(reason: String = "manual") async {
        baseline = nil
        baselineIsSettled = false
        settleWindow.removeAll()
        print("[MemoryProfiler] baseline reset requested reason=\(reason)")
    }

    // MARK: - Internals (subscriber mgmt + broadcast)

    private func _addSubscriber(id: UUID, cont: AsyncStream<MemorySnapshot>.Continuation) {
        subscribers[id] = cont
        log.info("[MemoryProfiler] subscriber ADD id=\(id.uuidString, privacy: .public) count=\(self.subscribers.count, privacy: .public)")

        // Immediately emit latest sample so new subscribers don't wait a whole interval.
        if let last = ring.last {
            cont.yield(last)
        }
    }

    private func _removeSubscriber(id: UUID, termination: AsyncStream<MemorySnapshot>.Continuation.Termination) {
        subscribers[id] = nil
        log.info("[MemoryProfiler] subscriber REMOVE id=\(id.uuidString, privacy: .public) term=\(String(describing: termination), privacy: .public) count=\(self.subscribers.count, privacy: .public)")
    }

    private func _broadcast(_ snap: MemorySnapshot) {
        for (_, cont) in subscribers {
            cont.yield(snap)
        }
    }

    // MARK: - Loop

    private func runLoop() async {
        print("[MemoryProfiler] runLoop begin")

        while !Task.isCancelled {
            let snap = Self.readSnapshot()
            await recordAndEmit(snap, source: "poll")

            // Convert Duration to nanoseconds safely.
            let ns = Self.durationToNanoseconds(config.interval)
            try? await Task.sleep(nanoseconds: max(ns, 100_000_000)) // >= 100ms safety
        }

        print("[MemoryProfiler] runLoop end")
    }

    private func recordAndEmit(_ snap: MemorySnapshot, source: String) async {
        // --- baseline settle phase ---
        if !baselineIsSettled {
            settleWindow.append(snap)

            if settleWindow.count >= settleSampleCount {
                let sorted = settleWindow.sorted { $0.footprintBytes < $1.footprintBytes }
                let median = sorted[sorted.count / 2]
                baseline = median
                baselineIsSettled = true

                log.info("[MemoryProfiler] baseline SETTLED instanceID=\(self.instanceID, privacy: .public) footprintMB=\(median.footprintMB, privacy: .public)")
                print(String(format: "[MemoryProfiler] baseline SETTLED footprintMB=%.2f", median.footprintMB))
            }
        }

        ring.append(snap)
        if ring.count > config.ringBufferCapacity {
            ring.removeFirst(ring.count - config.ringBufferCapacity)
        }

        if config.verbosePrintEachSample {
            print(String(format: "[MemoryProfiler] sample source=%@ footprintMB=%.2f residentMB=%.2f virtualMB=%.2f",
                         source, snap.footprintMB, snap.residentMB, snap.virtualMB))
        }

        _broadcast(snap)
    }

    private static func durationToNanoseconds(_ d: Duration) -> UInt64 {
        // Duration has (seconds, attoseconds). Convert carefully.
        let comps = d.components
        let sec = max(0, comps.seconds)
        let attos = max(0, comps.attoseconds)

        // 1 second = 1_000_000_000 ns
        // 1 attosecond = 1e-18 s = 1e-9 ns
        // nsFromAttos = attoseconds / 1_000_000_000
        let nsFromSec = UInt64(sec) * 1_000_000_000
        let nsFromAttos = UInt64(attos / 1_000_000_000)

        return nsFromSec &+ nsFromAttos
    }

    // MARK: - Mach sampler

    private static func readSnapshot() -> MemorySnapshot {
        let now = Date()

        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride
        )

        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }

        if kerr == KERN_SUCCESS {
            return MemorySnapshot(
                timestamp: now,
                footprintBytes: UInt64(info.phys_footprint),
                residentBytes: UInt64(info.resident_size),
                virtualBytes: UInt64(info.virtual_size)
            )
        }
        #endif

        return MemorySnapshot(timestamp: now, footprintBytes: 0, residentBytes: 0, virtualBytes: 0)
    }
}
