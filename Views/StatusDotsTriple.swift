//
//  StatusDotsTriple.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 8/9/25.
//


import SwiftUI

/// Compact triple status: SSH • HTTP • HLS (left→right)
struct StatusDotsTriple: View {
    let ssh: DeviceServiceStatus
    let http: DeviceServiceStatus
    let hls: DeviceServiceStatus
    var size: CGFloat = 10
    var spacing: CGFloat = 4

    private func color(for s: DeviceServiceStatus) -> Color {
        switch s {
        case .online:     return .green
        case .connecting: return .orange
        case .testing:    return .orange
        case .offline:    return .red
        case .unknown:    return .gray
        }
    }

    var body: some View {
        HStack(spacing: spacing) {
            Circle().fill(color(for: ssh)).frame(width: size, height: size)
                .accessibilityLabel("SSH")
            Circle().fill(color(for: http)).frame(width: size, height: size)
                .accessibilityLabel("HTTP")
            Circle().fill(color(for: hls)).frame(width: size, height: size)
                .accessibilityLabel("HLS")
        }
        .accessibilityElement(children: .contain)
    }
}
