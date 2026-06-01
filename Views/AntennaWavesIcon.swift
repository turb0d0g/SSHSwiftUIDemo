//
//  AntennaWavesIcon.swift
//  SSHSwiftUIDemo
//
//  iOS 16+
//  Discrete “fill one-by-one” wave animation (inner → mid → outer).
//

import SwiftUI

public struct AntennaWavesIcon: View {

    public enum Activity: Equatable {
        case idle
        case active
        case connecting
        case busy
        case error
    }

    public let activity: Activity
    public var size: CGFloat = 34

    @State private var step: Int = 0
    @State private var loopTask: Task<Void, Never>?

    public init(activity: Activity, size: CGFloat = 34) {
        self.activity = activity
        self.size = size
    }

    public var body: some View {
        ZStack {
            Image(systemName: baseSymbolName)
                .font(.system(size: size, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .opacity(activity == .error ? 0.35 : 1.0)

            DiscreteWaves(step: step, intensity: intensity)
                .frame(width: size * 1.35, height: size * 1.35)
                .opacity(wavesOpacity)
                .allowsHitTesting(false)
        }
        .onAppear { startOrStopLoop(for: activity) }
        .onDisappear { stopLoop(reason: "onDisappear") }
        .onChange(of: activity) { newValue in
            startOrStopLoop(for: newValue)
        }
    }

    // MARK: - Symbol + tuning

    private var baseSymbolName: String {
        // No baked-in waves. We draw those ourselves.
        // "antenna.radiowaves..." includes the wave glyphs -> double waves.
        switch activity {
        case .error:
            return "antenna.slash"
        default:
            return "antenna"
        }
    }

    private var intensity: CGFloat {
        // This is “how bright the filled bands get”
        switch activity {
        case .idle: return 0.10
        case .active: return 0.22
        case .connecting: return 1.00
        case .busy: return 0.85
        case .error: return 0.0
        }
    }

    private var wavesOpacity: CGFloat {
        switch activity {
        case .active: return 0.70
        case .idle: return 0.25
        case .connecting, .busy: return 1.0
        case .error: return 0.0
        }
    }

    // MARK: - Loop control

    private func startOrStopLoop(for activity: Activity) {
        let shouldAnimate = (activity == .connecting || activity == .busy)

        if shouldAnimate {
            guard loopTask == nil else { return }
            print("[AntennaWavesIcon] start loop activity=\(activity)")
            step = 0

            loopTask = Task { @MainActor in
                while !Task.isCancelled {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        step = (step + 1) % 4  // 0,1,2,3 where 3 = “all lit”
                    }
                    try? await Task.sleep(nanoseconds: 240_000_000) // 240ms per step

                    if step == 3 {
                        try? await Task.sleep(nanoseconds: 120_000_000) // hold
                        withAnimation(.easeOut(duration: 0.14)) {
                            step = 0
                        }
                        try? await Task.sleep(nanoseconds: 80_000_000)
                    }
                }
            }
        } else {
            stopLoop(reason: "activity=\(activity)")
            // Pick a sensible static fill.
            // Active: show 2-3 bars, Idle: 1 bar.
            withAnimation(.easeOut(duration: 0.18)) {
                switch activity {
                case .active: step = 2
                case .idle: step = 1
                case .error: step = 0
                default: step = 0
                }
            }
        }
    }

    private func stopLoop(reason: String) {
        if loopTask != nil {
            print("[AntennaWavesIcon] stop loop reason=\(reason)")
        }
        loopTask?.cancel()
        loopTask = nil
    }
}

// MARK: - Discrete waves (fixed bands, “fill” by step)

private struct DiscreteWaves: View {
    let step: Int
    let intensity: CGFloat

    var body: some View {
        GeometryReader { geo in
            let rect = geo.frame(in: .local)
            let c = CGPoint(x: rect.midX, y: rect.midY)

            Canvas { ctx, _ in
                // 3 fixed bands, inner → outer
                // step meaning:
                // 0 = none, 1 = inner, 2 = inner+mid, 3 = inner+mid+outer
                let bands: [(CGFloat, CGFloat)] = [
                    (0.12, 0.18),
                    (0.20, 0.27),
                    (0.30, 0.38)
                ]

                for (idx, band) in bands.enumerated() {
                    let isFilled = step >= (idx + 1)

                    let alpha: CGFloat = isFilled ? (0.95 * intensity) : (0.10 * intensity)
                    let line: CGFloat = isFilled ? 2.4 : 1.6

                    let r1 = rect.width * band.0
                    let r2 = rect.width * band.1

                    ctx.stroke(
                        waveArc(center: c, rInner: r1, rOuter: r2, side: .left),
                        with: .color(.primary.opacity(alpha)),
                        style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round)
                    )

                    ctx.stroke(
                        waveArc(center: c, rInner: r1, rOuter: r2, side: .right),
                        with: .color(.primary.opacity(alpha)),
                        style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round)
                    )
                }
            }
        }
    }

    private enum Side { case left, right }

    private func waveArc(center: CGPoint, rInner: CGFloat, rOuter: CGFloat, side: Side) -> Path {
        let (a1, a2): (CGFloat, CGFloat) = {
            switch side {
            case .left:  return (.pi * 0.62, .pi * 1.38)
            case .right: return (.pi * -0.38, .pi * 0.38)
            }
        }()

        var p = Path()
        p.addArc(center: center, radius: rInner, startAngle: .radians(Double(a1)), endAngle: .radians(Double(a2)), clockwise: false)
        p.addArc(center: center, radius: rOuter, startAngle: .radians(Double(a1)), endAngle: .radians(Double(a2)), clockwise: false)
        return p
    }
}
