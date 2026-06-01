//
//  UnifiedDiagnosticsHUDOverlay.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 12/30/25.
//

//
//  UnifiedDiagnosticsHUDOverlay.swift
//  SSHSwiftUIDemo
//
//  One overlay to rule them all:
//   - Memory panel (AnyMemoryHUDProviding)
//   - ARC tests (ARCTestMiniPanel + header summary line)
//   - ARC tracker panel (ARCTrackerHUDView)
//
//  iOS 16+
//  Updated: 2026-01-02
//

import SwiftUI

public struct UnifiedDiagnosticsHUDOverlay: View {

    public let memoryHUD: AnyMemoryHUDProviding?

    @State private var isExpanded: Bool = false
    @State private var dragOffset: CGSize = .zero
    @State private var baseOffset: CGSize = CGSize(width: 10, height: 52)

    // Header status for tests
    @State private var testSnap: ARCTestStatusBus.Snapshot = .init()
    @State private var testPollTask: Task<Void, Never>?

    public init(memoryHUD: AnyMemoryHUDProviding?) {
        self.memoryHUD = memoryHUD
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            hudCard
                .offset(
                    x: baseOffset.width + dragOffset.width,
                    y: baseOffset.height + dragOffset.height
                )
                .gesture(dragGesture)
        }
        .allowsHitTesting(true)
        .onAppear { startTestPolling() }
        .onDisappear { stopTestPolling() }
    }

    private var hudCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow

            if isExpanded {
                // 🔥 Show the last ARCTest result *right under the header*
                if let line = arctestHeaderLine {
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .opacity(0.95)
                }

                Divider().opacity(0.35)

                if let memoryHUD {
                    MemoryMiniPanel(memoryHUD: memoryHUD)
                } else {
                    Text("Memory panel not wired (pass MemoryHUDViewModel conformance/adapter).")
                        .font(.caption)
                        .opacity(0.7)
                }

                Divider().opacity(0.25)

                ARCTestMiniPanel()

                Divider().opacity(0.25)

                ARCTrackerHUDView(
                    config: {
                        var c = ARCTrackerHUDView.Config()
                        c.pollIntervalSeconds = 1.0
                        c.suspectAfterSeconds = 8.0
                        c.maxRows = 7
                        c.stackPreviewLines = 9
                        c.startExpanded = true
                        return c
                    }()
                )
            }
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(radius: 12, y: 6)
        .frame(maxWidth: 360, alignment: .leading)
        .accessibilityIdentifier("UnifiedDiagnosticsHUDOverlay")
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Diagnostics HUD")
                    .font(.headline)

                Text(isExpanded ? "drag me • tap to collapse" : "tap to expand • drag to move")
                    .font(.caption)
                    .opacity(0.75)
            }

            Spacer()

            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                isExpanded.toggle()
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                dragOffset = v.translation
            }
            .onEnded { v in
                baseOffset = CGSize(
                    width: baseOffset.width + v.translation.width,
                    height: baseOffset.height + v.translation.height
                )
                dragOffset = .zero
            }
    }

    // MARK: - ARCTest header line

    private var arctestHeaderLine: String? {
        // Show running even if there's no pass/fail yet.
        if testSnap.phase == .running {
            let suite = testSnap.suiteCount > 0 ? "\(testSnap.suiteIndex)/\(testSnap.suiteCount)" : "—"
            let iter = testSnap.iterationsTotal > 0 ? "\(testSnap.iteration)/\(testSnap.iterationsTotal)" : "—"
            return "RUNNING • suite \(suite) • iter \(iter) • \(testSnap.title)"
        }

        guard testSnap.isPass != nil else { return nil }
        let pass = testSnap.isPass == true
        let badge = pass ? "PASS" : "FAIL"
        let warn = pass ? "" : "⚠️ "
        return "\(warn)\(badge) • \(testSnap.title) • \(testSnap.summary)"
    }

    // MARK: - Polling bus

    private func startTestPolling() {
        guard testPollTask == nil else { return }
        testPollTask = Task {
            // prime
            await readBusOnce()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                await readBusOnce()
            }
        }
    }

    private func stopTestPolling() {
        testPollTask?.cancel()
        testPollTask = nil
    }

    @MainActor
    private func readBusOnce() async {
        let snap = await ARCTestStatusBus.shared.get()
        testSnap = snap
    }
}

// MARK: - Memory panel plumbing (adapter)

public protocol AnyMemoryHUDProviding: AnyObject {
    var footprintMB: Double { get }
    var residentMB: Double { get }
    var deltaMB: Double { get }
    var slopeMBPerMin: Double { get }
    var statusText: String { get }
}

private struct MemoryMiniPanel: View {
    let memoryHUD: AnyMemoryHUDProviding

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Memory")
                    .font(.headline)
                Spacer()
                Text(memoryHUD.statusText)
                    .font(.caption)
                    .opacity(0.75)
            }

            HStack(spacing: 14) {
                metric("Footprint", memoryHUD.footprintMB)
                metric("Resident", memoryHUD.residentMB)
            }

            HStack(spacing: 14) {
                metric("Δ MB", memoryHUD.deltaMB)
                metric("Slope/min", memoryHUD.slopeMBPerMin)
            }
        }
    }

    private func metric(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .opacity(0.75)
            Text(String(format: "%.1f", value))
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
