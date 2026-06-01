//
//  LiquidGlass.swift
//  SSHSwiftUIDemo
//
//  A reusable "liquid glass" container with optional tilt motion.
//

import SwiftUI

// MARK: - Public LiquidGlass container

public struct LiquidGlass<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    private let cornerRadius: CGFloat
    private let blurRadius: CGFloat
    private let motion: Bool
    private let content: () -> Content

    /// - Parameters:
    ///   - cornerRadius: Corner radius for the card.
    ///   - blurRadius: Background blur intensity.
    ///   - motion: If true, applies a subtle tilt effect.
    ///   - content: Your inner content.
    public init(
        cornerRadius: CGFloat = 20,
        blurRadius: CGFloat = 18,
        motion: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.blurRadius = blurRadius
        self.motion = motion
        self.content = content
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .blur(radius: blurRadius / 3)

            // Soft internal gradient sheen
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.18 : 0.35),
                            Color.white.opacity(0.02)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Outer stroke
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.45 : 0.7),
                            Color.white.opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )

            // Inner shadow-ish rim
            RoundedRectangle(cornerRadius: cornerRadius + 2, style: .continuous)
                .stroke(
                    Color.black.opacity(colorScheme == .dark ? 0.35 : 0.08),
                    lineWidth: 0.6
                )
                .blur(radius: 0.3)

            // Your content
            content()
                .padding()
        }
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(colorScheme == .dark ? 0.30 : 0.06))
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .motionTiltIf(motion, maxAngle: 8)
    }
}

// MARK: - MotionTilt (currently a safe no-op visual wrapper)

/// A placeholder tilt effect. You can later upgrade this to use CoreMotion for
/// real device-tilt parallax. For now it compiles cleanly and is visually safe.
struct MotionTilt: ViewModifier {
    let maxAngle: Double

    func body(content: Content) -> some View {
        // No-op tilt for now; keeps type system happy and
        // gives you a single place to upgrade later.
        content
    }
}

// MARK: - Conditional helper

extension View {
    /// Conditionally applies `MotionTilt` when enabled.
    @ViewBuilder
    func motionTiltIf(_ enabled: Bool, maxAngle: Double = 8) -> some View {
        if enabled {
            self.modifier(MotionTilt(maxAngle: maxAngle))
        } else {
            self
        }
    }
}
