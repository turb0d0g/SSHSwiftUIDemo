//
//  MemoryHUDOverlay.swift
//  SSHSwiftUIDemo
//
//  Floating memory HUD overlay + ARC test controls.
//  - Draggable (clamped away from nav bar hit area).
//  - Tap to cycle compact/expanded.
//  - Long-press resets memory baseline.
//  - Double-tap toggles visibility.
//
//  iOS 16+
//
import SwiftUI
import OSLog

public struct MemoryHUDOverlay: View {
    private let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "MemoryHUDOverlay")

    @ObservedObject private var vm: MemoryHUDViewModel

    @State private var isExpanded: Bool = false
    @AppStorage("hud.visible") private var isVisible: Bool = true

    @State private var dragOffset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    @AppStorage("memoryHUD.offsetX") private var storedX: Double = 14
    @AppStorage("memoryHUD.offsetY") private var storedY: Double = 120

    // Keep HUD out of navigation bar / notch hit area
    private let navBarDeadZoneHeight: CGFloat = 56

    // ✅ CORRECT INITIALIZER
    public init(vm: MemoryHUDViewModel) {
        self._vm = ObservedObject(wrappedValue: vm)
    }

    public var body: some View {
        Group {
            if isVisible {
                hudCard
                    .offset(
                        x: baseOffset.width + dragOffset.width,
                        y: baseOffset.height + dragOffset.height
                    )
                    .onAppear {
                        baseOffset = CGSize(width: storedX, height: storedY)
                        baseOffset = clampOffset(baseOffset)

                        storedX = baseOffset.width
                        storedY = baseOffset.height

                        log.info("[MemoryHUDOverlay] appear baseOffset=(\(storedX, privacy: .public), \(storedY, privacy: .public))")
                    }
                    .gesture(dragGesture)
                    .simultaneousGesture(tapGesture)
                    .simultaneousGesture(longPressGesture)
                    .simultaneousGesture(doubleTapGesture)
                    .transition(.opacity)
                    .zIndex(9999)
            }
        }
    }

    // MARK: - HUD Card

    private var hudCard: some View {
        let s = vm.state
        let latest = s.latest

        let footprint = latest.map { String(format: "%.1fMB", $0.footprintMB) } ?? "--"
        let resident  = latest.map { String(format: "%.1fMB", $0.residentMB) } ?? "--"
        let delta     = s.deltaMB.map { String(format: "%+.1fMB", $0) } ?? "--"
        let slope     = s.slopeMBPerMin.map { String(format: "%+.1fMB/min", $0) } ?? "--"

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .frame(width: 10, height: 10)
                    .foregroundStyle(colorForLevel(s.level))

                VStack(alignment: .leading, spacing: 6) {
                    Text("MEM")
                        .font(.caption.weight(.bold))

                    Text("\(footprint)  \(delta)")
                        .font(.system(.footnote, design: .monospaced).weight(.semibold))

                    HStack(spacing: 8) {
                        hudButton(title: "Closure") { vm.runARCClosureCycle() }
                        hudButton(title: "Combine") { vm.runARCCombineCycle() }
                        hudButton(title: "Task") { vm.runARCTaskCycle() }
                    }
                    .disabled(s.arcIsRunning)
                    .opacity(s.arcIsRunning ? 0.6 : 1.0)
                }

                Spacer(minLength: 10)

                Text(s.isRunning ? "ON" : "OFF")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    row("Resident", resident)
                    row("Slope", slope)
                    row("Updated", s.lastUpdated.map(timeString) ?? "--")

                    Divider().opacity(0.35)

                    Text("ARC TEST")
                        .font(.caption.weight(.bold))

                    HStack(spacing: 10) {
                        hudButton(title: s.arcIsRunning ? "Running…" : "ARC Smoke") {
                            vm.runARCSmoke(count: 250)
                        }
                        .disabled(s.arcIsRunning)

                        hudButton(title: s.arcIsRunning ? "Running…" : "ARC Cycle") {
                            vm.runARCCycle(count: 50)
                        }
                        .disabled(s.arcIsRunning)
                    }

                    Text("Tap: expand • Long-press: baseline • Double-tap: hide")
                        .font(.caption2)
                        .opacity(0.75)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(radius: 10)
        .padding(8)
    }

    // MARK: - Helpers / Gestures (unchanged)

    private func hudButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(.caption, design: .monospaced))
            Spacer()
            Text(v).font(.system(.caption, design: .monospaced).weight(.semibold))
        }
    }

    private func colorForLevel(_ level: MemoryHUDViewModel.Level) -> Color {
        switch level {
        case .ok: return .green
        case .warn: return .yellow
        case .error: return .red
        }
    }

    private func timeString(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        return seconds < 60 ? "\(seconds)s ago" : "\(seconds / 60)m ago"
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { dragOffset = $0.translation }
            .onEnded {
                baseOffset.width += $0.translation.width
                baseOffset.height += $0.translation.height
                baseOffset = clampOffset(baseOffset)
                dragOffset = .zero
                storedX = baseOffset.width
                storedY = baseOffset.height
            }
    }

    private var tapGesture: some Gesture {
        TapGesture().onEnded {
            withAnimation(.spring()) { isExpanded.toggle() }
        }
    }

    private var longPressGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.45).onEnded { _ in
            vm.resetBaseline(reason: "HUD long-press")
        }
    }

    private var doubleTapGesture: some Gesture {
        TapGesture(count: 2).onEnded {
            withAnimation { isVisible.toggle() }
        }
    }

    private func clampOffset(_ proposed: CGSize) -> CGSize {
        let minY = navBarDeadZoneHeight
        return CGSize(width: proposed.width, height: max(proposed.height, minY))
    }
}
