//
//  ARCTrackerHUDView.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 12/30/25.
//


//
//  ARCTrackerHUDView.swift
//  SSHSwiftUIDemo
//
//  Live HUD for ARCTracker.
//  - Async/await polling loop (no Timer).
//  - Modes: Suspects | Transient | Pinned | All
//  - Tap row to expand stack trace preview.
//  iOS 16+
//
//  Updated: 2026-01-02
//

import SwiftUI

public struct ARCTrackerHUDView: View {

    public struct Config: Sendable {
        public var pollIntervalSeconds: Double = 1.0
        public var suspectAfterSeconds: Double = 8.0
        public var maxRows: Int = 8
        public var stackPreviewLines: Int = 10
        public var startExpanded: Bool = true
        public init() {}
    }

    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case suspects = "Suspects"
        case transient = "Transient"
        case pinned = "Pinned"
        case all = "All"
        public var id: String { rawValue }
    }

    private let config: Config

    @State private var mode: Mode = .suspects

    // We render a unified list type
    @State private var items: [ARCTracker.Tracked] = []
    @State private var task: Task<Void, Never>?

    @State private var expandedIDs: Set<String> = []

    // Cached counts so header can show "All: 12 | Pinned: 4 | ..."
    @State private var countSuspects: Int = 0
    @State private var countTransient: Int = 0
    @State private var countPinned: Int = 0
    @State private var countAll: Int = 0

    public init(config: Config = .init()) {
        self.config = config
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            header

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { _ in
                // Collapse rows on mode switch to avoid confusion
                expandedIDs.removeAll()
                Task { await refreshOnce() }
            }

            if items.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .opacity(0.7)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(items.prefix(config.maxRows), id: \.id) { t in
                        row(t)
                    }
                }
            }
        }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("ARC Watch")
                .font(.headline)

            Spacer()

            // Tiny scoreboard (monospace)
            Text(scoreboardText)
                .font(.system(.caption, design: .monospaced))
                .opacity(0.75)
        }
    }

    private var scoreboardText: String {
        // Keep it compact; this is a HUD, not a novel.
        "S:\(countSuspects) T:\(countTransient) P:\(countPinned) A:\(countAll)"
    }

    private var emptyText: String {
        switch mode {
        case .suspects: return "No suspects (yet)."
        case .transient: return "No transient tracked objects."
        case .pinned: return "No pinned app-lifetime objects."
        case .all: return "No tracked objects."
        }
    }

    // MARK: - Row

    private func row(_ t: ARCTracker.Tracked) -> some View {
        let open = expandedIDs.contains(t.id)
        let isPinned = (t.expectedLifetime == .appLifetime)

        return VStack(alignment: .leading, spacing: 6) {

            HStack(alignment: .top, spacing: 10) {

                VStack(alignment: .leading, spacing: 2) {

                    HStack(spacing: 6) {
                        if isPinned {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .opacity(0.85)
                        }

                        Text(t.typeName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                    }

                    Text("age \(formatAge(t.ageSeconds)) • \(formatTime(t.createdAt))")
                        .font(.caption)
                        .opacity(0.75)

                    if isPinned {
                        Text("expected: app lifetime")
                            .font(.caption)
                            .opacity(0.70)
                    }

                    if !t.note.isEmpty {
                        Text(t.note)
                            .font(.caption)
                            .opacity(0.85)
                            .lineLimit(2)
                    }
                }

                Spacer()

                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(0.8)
            }

            if open {
                Divider().opacity(0.25)
                Text(stackPreview(t.creationStack))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(10)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { toggle(t.id) }
    }

    private func toggle(_ id: String) {
        if expandedIDs.contains(id) { expandedIDs.remove(id) }
        else { expandedIDs.insert(id) }
    }

    // MARK: - Polling

    private func start() {
        guard task == nil else { return }

        // If you want it open by default with expanded stacks, preserve config.startExpanded behavior.
        // We’ll keep “expandedIDs empty” and let the user tap rows; startExpanded remains a future hook.
        task = Task {
            await refreshOnce()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(config.pollIntervalSeconds * 1_000_000_000))
                await refreshOnce()
            }
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
    }

    @MainActor
    private func refreshOnce() async {
        // Pull counts first (fast, actor-isolated) so header stays accurate
        let suspects = await ARCTracker.shared.currentTracked(.suspects(suspectAfterSeconds: config.suspectAfterSeconds))
        let transient = await ARCTracker.shared.currentTracked(.transientAll)
        let pinned = await ARCTracker.shared.currentTracked(.pinned)
        let all = await ARCTracker.shared.currentTracked(.all(includePinned: true))

        countSuspects = suspects.count
        countTransient = transient.count
        countPinned = pinned.count
        countAll = all.count

        // Choose list based on mode
        let selected: [ARCTracker.Tracked]
        switch mode {
        case .suspects:
            selected = suspects
        case .transient:
            selected = transient
        case .pinned:
            selected = pinned
        case .all:
            selected = all
        }

        // Keep expandedIDs only for items still present
        expandedIDs = expandedIDs.intersection(Set(selected.map(\.id)))

        items = selected
    }

    // MARK: - Formatting

    private func formatAge(_ s: TimeInterval) -> String {
        if s < 60 { return String(format: "%.1fs", s) }
        let m = Int(s) / 60
        let r = Int(s) % 60
        return "\(m)m\(r)s"
    }

    private func formatTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    private func stackPreview(_ stack: [String]) -> String {
        stack.prefix(config.stackPreviewLines).joined(separator: "\n")
    }
}
