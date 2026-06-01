//
//  ARCTestMiniPanel.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 1/3/26.
//


//
//  ARCTestMiniPanel.swift
//  SSHSwiftUIDemo
//
//  Mini HUD panel for running ARCTestHarness tests.
//  - Async polling loop (no Timer).
//  - Buttons trigger tests on the actor.
//  - Run All (serial) + Stress xN mode.
//  - Publishes compact status + progress to ARCTestStatusBus for HUD header display.
//
//  iOS 16+
//  Updated: 2026-01-02
//

import SwiftUI

public struct ARCTestMiniPanel: View {

    public struct Config: Sendable {
        public var pollIntervalSeconds: Double = 0.5
        public var buttonCornerRadius: CGFloat = 10
        public var stressIterations: Int = 10
        public init() {}
    }

    private let config: Config

    @State private var status: ARCTestHarness.Status = .init()
    @State private var pollTask: Task<Void, Never>?
    @State private var runTask: Task<Void, Never>?

    @State private var stressEnabled: Bool = false

    public init(config: Config = .init()) {
        self.config = config
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            statusBlock
            controls
        }
        .onAppear { startPolling() }
        .onDisappear { stopAll() }
    }

    // MARK: - UI

    private var header: some View {
        HStack(spacing: 10) {
            Text("ARC Tests")
                .font(.headline)

            Spacer()

            // Stress toggle (compact)
            Toggle(isOn: $stressEnabled) {
                Text("Stress x\(config.stressIterations)")
                    .font(.caption.weight(.semibold))
            }
            .toggleStyle(.switch)
            .labelsHidden()

            Text(stressEnabled ? "x\(config.stressIterations)" : "x1")
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial)
                .clipShape(Capsule())
                .opacity(0.9)

            phaseBadge
        }
    }

    private var phaseBadge: some View {
        Group {
            if let t = runTask, !t.isCancelled {
                Text("RUNNING")
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial)
                    .clipShape(Capsule())
                    .opacity(0.95)
            } else if let r = status.lastResult {
                Text(r.isPass ? "PASS" : "FAIL")
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial)
                    .clipShape(Capsule())
                    .opacity(0.9)
            } else {
                Text("—")
                    .font(.system(.caption, design: .monospaced))
                    .opacity(0.6)
            }
        }
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 6) {

            HStack {
                Text(status.lastName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                Text(progressText)
                    .font(.system(.caption, design: .monospaced))
                    .opacity(0.75)
            }

            if let result = status.lastResult {
                Text(result.message)
                    .font(.caption)
                    .opacity(result.isPass ? 0.85 : 0.95)
                    .lineLimit(3)
            } else {
                Text("Tap a test or hit Run All. I’ll report deinits observed.")
                    .font(.caption)
                    .opacity(0.7)
            }

            if let started = status.startedAt {
                Text("started \(formatTime(started))\(status.finishedAt.map { " • finished \(formatTime($0))" } ?? "")")
                    .font(.caption2)
                    .opacity(0.65)
            }
        }
        .padding(10)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {

            // Run All row
            HStack(spacing: 8) {
                Button {
                    runAll()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.circle")
                        Text("Run All")
                    }
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: config.buttonCornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    stopRunOnly()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark.circle")
                        Text("Cancel")
                    }
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: config.buttonCornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .opacity(runTask == nil ? 0.35 : 0.95)
                .disabled(runTask == nil)
            }

            // Row 1
            HStack(spacing: 8) {
                button("Smoke", systemImage: "flame") {
                    await ARCTestHarness.shared.runSmokeTest(count: 250, timeout: .seconds(2))
                }
                button("Cycle", systemImage: "arrow.triangle.2.circlepath") {
                    await ARCTestHarness.shared.runCycleTest(count: 50, breakDelay: .milliseconds(250), timeoutAfterBreak: .seconds(2))
                }
                button("Persistent", systemImage: "lock") {
                    await ARCTestHarness.shared.runExpectedPersistentTest(timeout: .milliseconds(500))
                }
            }

            // Row 2
            HStack(spacing: 8) {
                button("Closure", systemImage: "curlybraces") {
                    await ARCTestHarness.shared.runClosureCaptureCycleTest(count: 50, breakDelay: .milliseconds(300), timeoutAfterBreak: .seconds(2))
                }
                button("Combine", systemImage: "dot.radiowaves.left.and.right") {
                    await ARCTestHarness.shared.runCombineSinkCycleTest(count: 25, breakDelay: .milliseconds(300), timeoutAfterBreak: .seconds(2))
                }
                button("Task", systemImage: "bolt.badge.clock") {
                    await ARCTestHarness.shared.runTaskCaptureCycleTest(count: 25, breakDelay: .milliseconds(300), timeoutAfterBreak: .seconds(2))
                }
            }
        }
    }

    private func button(_ title: String, systemImage: String, action: @escaping @Sendable () async -> ARCTestHarness.Status) -> some View {
        Button {
            runOne(name: title, action: action)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: config.buttonCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Behavior

    private struct TestCase {
        let name: String
        let run: @Sendable () async -> ARCTestHarness.Status
    }

    private var suite: [TestCase] {
        [
            .init(name: "Smoke") { await ARCTestHarness.shared.runSmokeTest(count: 250, timeout: .seconds(2)) },
            .init(name: "Cycle") { await ARCTestHarness.shared.runCycleTest(count: 50, breakDelay: .milliseconds(250), timeoutAfterBreak: .seconds(2)) },
            .init(name: "Persistent") { await ARCTestHarness.shared.runExpectedPersistentTest(timeout: .milliseconds(500)) },
            .init(name: "Closure") { await ARCTestHarness.shared.runClosureCaptureCycleTest(count: 50, breakDelay: .milliseconds(300), timeoutAfterBreak: .seconds(2)) },
            .init(name: "Combine") { await ARCTestHarness.shared.runCombineSinkCycleTest(count: 25, breakDelay: .milliseconds(300), timeoutAfterBreak: .seconds(2)) },
            .init(name: "Task") { await ARCTestHarness.shared.runTaskCaptureCycleTest(count: 25, breakDelay: .milliseconds(300), timeoutAfterBreak: .seconds(2)) },
        ]
    }

    private func runOne(name: String, action: @escaping @Sendable () async -> ARCTestHarness.Status) {
        stopRunOnly()

        runTask = Task {
            print("[ARCTestMiniPanel] run begin name=\(name) stress=\(stressEnabled)")
            await publishPhase(.running, suiteIndex: 1, suiteCount: 1, iteration: 1, iterationsTotal: stressEnabled ? config.stressIterations : 1)

            if stressEnabled {
                _ = await runStress(name: name, run: action, iterations: config.stressIterations)
            } else {
                _ = await action()
            }

            print("[ARCTestMiniPanel] run end name=\(name)")
            await refreshOnce()
            await publishPhase(.finished, suiteIndex: 1, suiteCount: 1, iteration: 1, iterationsTotal: 1)
        }
    }

    private func runAll() {
        stopRunOnly()

        runTask = Task {
            let cases = suite
            let iters = stressEnabled ? config.stressIterations : 1

            print("[ARCTestMiniPanel] runAll begin cases=\(cases.count) iters=\(iters)")

            await publishPhase(.running, suiteIndex: 0, suiteCount: cases.count, iteration: 0, iterationsTotal: iters)

            for (idx, tc) in cases.enumerated() {
                if Task.isCancelled { break }

                let suiteIndex = idx + 1
                await publishPhase(.running, suiteIndex: suiteIndex, suiteCount: cases.count, iteration: 0, iterationsTotal: iters)

                if stressEnabled {
                    _ = await runStress(name: tc.name, run: tc.run, iterations: iters, suiteIndex: suiteIndex, suiteCount: cases.count)
                } else {
                    _ = await tc.run()
                    await refreshOnce()
                    await publishPhase(.running, suiteIndex: suiteIndex, suiteCount: cases.count, iteration: 1, iterationsTotal: 1)
                }
            }

            if Task.isCancelled {
                print("[ARCTestMiniPanel] runAll cancelled")
                await publishPhase(.cancelled, suiteIndex: 0, suiteCount: cases.count, iteration: 0, iterationsTotal: iters)
            } else {
                print("[ARCTestMiniPanel] runAll finished")
                await publishPhase(.finished, suiteIndex: cases.count, suiteCount: cases.count, iteration: iters, iterationsTotal: iters)
            }

            await refreshOnce()
        }
    }

    /// Runs a test N times and logs the worst failure (if any).
    private func runStress(
        name: String,
        run: @escaping @Sendable () async -> ARCTestHarness.Status,
        iterations: Int,
        suiteIndex: Int = 1,
        suiteCount: Int = 1
    ) async -> ARCTestHarness.Status {

        var last: ARCTestHarness.Status = .init()
        var anyFail = false
        var worstMessage: String = ""
        var worstObserved: Int = 0
        var worstExpected: Int = 0

        for i in 1...iterations {
            if Task.isCancelled { break }

            await publishPhase(.running, suiteIndex: suiteIndex, suiteCount: suiteCount, iteration: i, iterationsTotal: iterations)

            last = await run()
            await refreshOnce()

            if let r = last.lastResult, !r.isPass {
                anyFail = true
                // "Worst" = lowest observed/expected ratio or smallest observed
                if worstMessage.isEmpty || last.observedDeinits < worstObserved {
                    worstMessage = r.message
                    worstObserved = last.observedDeinits
                    worstExpected = last.expectedDeinits
                }
            }
        }

        if anyFail && !worstMessage.isEmpty {
            print("[ARCTestMiniPanel][Stress] worst FAIL in \(name): \(worstObserved)/\(worstExpected) :: \(worstMessage)")
        }

        return last
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task {
            await refreshOnce()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(config.pollIntervalSeconds * 1_000_000_000))
                await refreshOnce()
            }
        }
    }

    private func stopRunOnly() {
        runTask?.cancel()
        runTask = nil
        Task { await publishPhase(.cancelled, suiteIndex: 0, suiteCount: suite.count, iteration: 0, iterationsTotal: stressEnabled ? config.stressIterations : 1) }
    }

    private func stopAll() {
        stopRunOnly()
        pollTask?.cancel()
        pollTask = nil
    }

    @MainActor
    private func refreshOnce() async {
        let s = await ARCTestHarness.shared.currentStatus()
        status = s
        Task { await publishToBus(s) }
    }

    private func publishToBus(_ s: ARCTestHarness.Status) async {
        var snap = ARCTestStatusBus.Snapshot()
        snap.title = s.lastName
        snap.observed = s.observedDeinits
        snap.expected = s.expectedDeinits
        snap.updatedAt = Date()

        if let r = s.lastResult {
            snap.isPass = r.isPass
            snap.summary = r.message
        } else {
            snap.isPass = nil
            snap.summary = ""
        }

        // Preserve phase/progress if we’re mid-run
        let existing = await ARCTestStatusBus.shared.get()
        snap.phase = existing.phase
        snap.suiteIndex = existing.suiteIndex
        snap.suiteCount = existing.suiteCount
        snap.iteration = existing.iteration
        snap.iterationsTotal = existing.iterationsTotal

        await ARCTestStatusBus.shared.set(snap)
    }

    private func publishPhase(
        _ phase: ARCTestStatusBus.Phase,
        suiteIndex: Int,
        suiteCount: Int,
        iteration: Int,
        iterationsTotal: Int
    ) async {
        var snap = await ARCTestStatusBus.shared.get()
        snap.phase = phase
        snap.suiteIndex = suiteIndex
        snap.suiteCount = suiteCount
        snap.iteration = iteration
        snap.iterationsTotal = iterationsTotal
        snap.updatedAt = Date()
        await ARCTestStatusBus.shared.set(snap)
    }

    // MARK: - Formatting

    private var progressText: String {
        "\(status.observedDeinits)/\(status.expectedDeinits)"
    }

    private func formatTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}
