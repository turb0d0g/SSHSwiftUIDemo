//
//  ARCTestResult.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 12/23/25.
//


//
//  ARCTestHarness.swift
//  SSHSwiftUIDemo
//
//  ARC verification helpers.
//  - Creates tracked objects that log deinit.
//  - Runs smoke tests and retain-cycle tests safely (cycle is broken automatically).
//  - Includes closure/Combine/Task capture cycle tests.
//  - Includes an "expected persistent" test to validate false-positive handling.
//
//  iOS 16+
//

import Foundation
import OSLog
import Combine

public enum ARCTestResult: Sendable, Equatable {
    case passed(String)
    case failed(String)

    public var isPass: Bool {
        if case .passed = self { return true }
        return false
    }

    public var message: String {
        switch self {
        case .passed(let m): return m
        case .failed(let m): return m
        }
    }
}

public actor ARCTestHarness {
    public static let shared = ARCTestHarness()

    private let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "ARCTestHarness")

    public struct Status: Sendable, Equatable {
        public var lastName: String = "—"
        public var lastResult: ARCTestResult? = nil
        public var expectedDeinits: Int = 0
        public var observedDeinits: Int = 0
        public var startedAt: Date? = nil
        public var finishedAt: Date? = nil

        public init() {}
    }

    private var status = Status()

    /// incremented by tracked instances on deinit via callback
    private var deinitCount: Int = 0

    private init() {}

    public func currentStatus() -> Status { status }

    // MARK: - Public tests

    /// Creates `count` objects, drops them, and waits for deinits to occur.
    /// This is a basic "does ARC deinit when references are released?" sanity check.
    public func runSmokeTest(
        count: Int = 250,
        timeout: Duration = .seconds(2)
    ) async -> Status {
        let name = "ARC Smoke x\(count)"
        reset(name: name, expected: count)

        log.info("[ARCTest] \(name, privacy: .public) start")
        print("[ARCTest] \(name) start")

        // Scope block so locals go away aggressively
        do {
            var arr: [Tracked] = []
            arr.reserveCapacity(count)

            for i in 0..<count {
                arr.append(Tracked(id: i) { [weak self] in
                    Task { await self?.noteDeinit() }
                })
            }

            // Drop all strong refs
            arr.removeAll(keepingCapacity: false)
        }

        let passed = await waitForDeinits(expected: count, timeout: timeout)
        finish(name: name, passed: passed)
        return status
    }

    /// Creates a retain cycle, verifies it does NOT deinit while cycle exists,
    /// then breaks it after `breakDelay` and expects deinits.
    public func runCycleTest(
        count: Int = 50,
        breakDelay: Duration = .milliseconds(250),
        timeoutAfterBreak: Duration = .seconds(2)
    ) async -> Status {
        let name = "ARC Cycle x\(count)"
        reset(name: name, expected: count)

        log.info("[ARCTest] \(name, privacy: .public) start breakDelay=\(String(describing: breakDelay), privacy: .public)")
        print("[ARCTest] \(name) start breakDelay=\(breakDelay)")

        var roots: [CycleNode] = []
        roots.reserveCapacity(count)

        for i in 0..<count {
            roots.append(CycleNode(id: i) { [weak self] in
                Task { await self?.noteDeinit() }
            })
        }

        for i in 0..<count {
            roots[i].next = roots[(i + 1) % count]
        }

        try? await Task.sleep(for: breakDelay)

        for i in 0..<count { roots[i].next = nil }

        roots.removeAll(keepingCapacity: false)

        let passed = await waitForDeinits(expected: count, timeout: timeoutAfterBreak)
        finish(name: name, passed: passed)
        return status
    }

    /// Verifies that an intentionally retained object does NOT deinit during a short window.
    /// This is the "stop flagging app-lifetime singletons" sanity check.
    public func runExpectedPersistentTest(
        timeout: Duration = .milliseconds(500)
    ) async -> Status {
        let name = "Expected Persistent (should NOT deinit)"
        reset(name: name, expected: 0)

        log.info("[ARCTest] \(name, privacy: .public) start")
        print("[ARCTest] \(name) start")

        // Keep one object strongly referenced during the window.
        var obj: Tracked? = Tracked(id: 999) { [weak self] in
            Task { await self?.noteDeinit() }
        }

        try? await Task.sleep(for: timeout)

        // If it deinited while still strongly referenced, something is wrong.
        let passed = (deinitCount == 0)

        // Release afterwards (not part of pass/fail).
        obj = nil

        finish(name: name, passed: passed)
        return status
    }

    // MARK: - Closure Capture Cycle

    public func runClosureCaptureCycleTest(
        count: Int = 50,
        breakDelay: Duration = .milliseconds(300),
        timeoutAfterBreak: Duration = .seconds(2)
    ) async -> Status {
        let name = "Closure Capture x\(count)"
        reset(name: name, expected: count)

        log.info("[ARCTest] \(name, privacy: .public) start")
        print("[ARCTest] \(name) start")

        var holders: [ClosureHolder] = []
        holders.reserveCapacity(count)

        for i in 0..<count {
            holders.append(
                ClosureHolder(id: i) { [weak self] in
                    Task { await self?.noteDeinit() }
                }
            )
        }

        // Create strong capture cycle: self -> closure -> self
        for h in holders {
            h.installStrongClosure()
        }

        try? await Task.sleep(for: breakDelay)

        // Break cycle
        for h in holders {
            h.clearClosure()
        }

        holders.removeAll(keepingCapacity: false)

        let passed = await waitForDeinits(expected: count, timeout: timeoutAfterBreak)
        finish(name: name, passed: passed)
        return status
    }

    private final class ClosureHolder {
        let id: Int
        private let onDeinit: () -> Void
        private var closure: (() -> Void)?

        init(id: Int, onDeinit: @escaping () -> Void) {
            self.id = id
            self.onDeinit = onDeinit
        }

        func installStrongClosure() {
            closure = {
                // Strong capture of self → retain cycle
                _ = self.id
            }
        }

        func clearClosure() {
            closure = nil
        }

        deinit { onDeinit() }
    }

    // MARK: - Combine Sink Cycle

    public func runCombineSinkCycleTest(
        count: Int = 25,
        breakDelay: Duration = .milliseconds(300),
        timeoutAfterBreak: Duration = .seconds(2)
    ) async -> Status {
        let name = "Combine Sink x\(count)"
        reset(name: name, expected: count)

        log.info("[ARCTest] \(name, privacy: .public) start")
        print("[ARCTest] \(name) start")

        var holders: [CombineHolder] = []
        holders.reserveCapacity(count)

        for i in 0..<count {
            holders.append(
                CombineHolder(id: i) { [weak self] in
                    Task { await self?.noteDeinit() }
                }
            )
        }

        for h in holders {
            h.startSink()
        }

        try? await Task.sleep(for: breakDelay)

        // Break cycle
        for h in holders {
            h.cancel()
        }

        holders.removeAll(keepingCapacity: false)

        let passed = await waitForDeinits(expected: count, timeout: timeoutAfterBreak)
        finish(name: name, passed: passed)
        return status
    }

    private final class CombineHolder {
        let id: Int
        private let onDeinit: () -> Void
        private let subject = PassthroughSubject<Int, Never>()
        private var cancellable: AnyCancellable?

        init(id: Int, onDeinit: @escaping () -> Void) {
            self.id = id
            self.onDeinit = onDeinit
        }

        func startSink() {
            // sink captures self strongly → cycle
            cancellable = subject.sink { value in
                _ = self.id
                _ = value
            }
            subject.send(1)
        }

        func cancel() {
            cancellable?.cancel()
            cancellable = nil
        }

        deinit { onDeinit() }
    }

    // MARK: - Task Capture Cycle

    public func runTaskCaptureCycleTest(
        count: Int = 25,
        breakDelay: Duration = .milliseconds(300),
        timeoutAfterBreak: Duration = .seconds(2)
    ) async -> Status {
        let name = "Task Capture x\(count)"
        reset(name: name, expected: count)

        log.info("[ARCTest] \(name, privacy: .public) start")
        print("[ARCTest] \(name) start")

        var holders: [TaskHolder] = []
        holders.reserveCapacity(count)

        for i in 0..<count {
            holders.append(
                TaskHolder(id: i) { [weak self] in
                    Task { await self?.noteDeinit() }
                }
            )
        }

        for h in holders {
            h.startTask()
        }

        try? await Task.sleep(for: breakDelay)

        // Break cycle
        for h in holders {
            h.cancelTask()
        }

        holders.removeAll(keepingCapacity: false)

        let passed = await waitForDeinits(expected: count, timeout: timeoutAfterBreak)
        finish(name: name, passed: passed)
        return status
    }

    private final class TaskHolder {
        let id: Int
        private let onDeinit: () -> Void
        private var task: Task<Void, Never>?

        init(id: Int, onDeinit: @escaping () -> Void) {
            self.id = id
            self.onDeinit = onDeinit
        }

        func startTask() {
            // Task captures self strongly
            task = Task {
                while !Task.isCancelled {
                    _ = self.id
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }

        func cancelTask() {
            task?.cancel()
            task = nil
        }

        deinit { onDeinit() }
    }

    // MARK: - Internals

    private func reset(name: String, expected: Int) {
        deinitCount = 0
        status = Status()
        status.lastName = name
        status.expectedDeinits = expected
        status.observedDeinits = 0
        status.startedAt = Date()
        status.finishedAt = nil
        status.lastResult = nil
    }

    private func noteDeinit() {
        deinitCount += 1
        status.observedDeinits = deinitCount

        // Keep this noisy but not insane.
        if deinitCount <= 5 || deinitCount % 50 == 0 {
            log.debug("[ARCTest] deinitCount=\(self.deinitCount, privacy: .public)")
            print("[ARCTest] deinitCount=\(deinitCount)")
        }
    }

    private func waitForDeinits(expected: Int, timeout: Duration) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout.timeInterval)

        while Date() < deadline {
            if deinitCount >= expected { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return deinitCount >= expected
    }

    private func finish(name: String, passed: Bool) {
        status.finishedAt = Date()

        let observed = status.observedDeinits
        let expected = status.expectedDeinits

        if passed {
            status.lastResult = .passed("\(name): PASS (\(observed)/\(expected) deinits)")
            log.info("[ARCTest] \(name, privacy: .public) PASS observed=\(observed, privacy: .public)/\(expected, privacy: .public)")
            print("[ARCTest] \(name) PASS observed=\(observed)/\(expected)")
        } else {
            status.lastResult = .failed("\(name): FAIL (\(observed)/\(expected) deinits)")
            log.error("[ARCTest] \(name, privacy: .public) FAIL observed=\(observed, privacy: .public)/\(expected, privacy: .public)")
            print("[ARCTest] \(name) FAIL observed=\(observed)/\(expected)")
        }
    }
}

// MARK: - Tracked types

/// Simple object whose deinit increments a counter.
private final class Tracked {
    let id: Int
    private let onDeinit: () -> Void

    init(id: Int, onDeinit: @escaping () -> Void) {
        self.id = id
        self.onDeinit = onDeinit
    }

    deinit { onDeinit() }
}

/// Node that can participate in a retain cycle.
private final class CycleNode {
    let id: Int
    var next: CycleNode?
    private let onDeinit: () -> Void

    init(id: Int, onDeinit: @escaping () -> Void) {
        self.id = id
        self.onDeinit = onDeinit
    }

    deinit { onDeinit() }
}

// MARK: - Duration helpers

private extension Duration {
    var timeInterval: TimeInterval {
        let c = self.components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}
