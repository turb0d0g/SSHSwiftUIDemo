//
//  LiveVMOverlay.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 1/9/26.
//


//
//  LiveVMOverlay.swift
//  SSHSwiftUIDemo
//
//  Tiny on-screen HUD showing live VM instance IDs + counts.
//  Draggable + tap-to-toggle.
//
//  Add to root view:
//    .overlay(alignment: .topLeading) { LiveVMOverlay() }
//

import SwiftUI
import CoreGraphics

extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGSize) -> CGPoint {
        .init(x: lhs.x + rhs.width, y: lhs.y + rhs.height)
    }
    static func - (lhs: CGPoint, rhs: CGSize) -> CGPoint {
        .init(x: lhs.x - rhs.width, y: lhs.y - rhs.height)
    }
}

extension CGSize {
    static func + (lhs: CGSize, rhs: CGSize) -> CGSize {
        .init(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
    }
    static func - (lhs: CGSize, rhs: CGSize) -> CGSize {
        .init(width: lhs.width - rhs.width, height: lhs.height - rhs.height)
    }
}

public struct LiveVMOverlay: View {
    @ObservedObject private var reg = VMInstanceRegistry.shared

    @State private var isExpanded: Bool = true
    @State private var offset: CGSize = .init(width: 8, height: 60)

    public init() {}

    public var body: some View {
        if reg.isOverlayEnabled {
            content
                .padding(8)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
                .offset(offset)
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { offset = $0.translation + .init(width: 8, height: 60) }
                )
                .onTapGesture(count: 1) { isExpanded.toggle() }
                .onTapGesture(count: 2) { reg.isOverlayEnabled.toggle() } // double-tap = hide
                .accessibilityHidden(true)
                .zIndex(9999)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if isExpanded {
                Divider().opacity(0.35)

                if reg.rows.isEmpty {
                    Text("No tracked VMs")
                        .font(.system(.caption, design: .monospaced))
                        .opacity(0.8)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(reg.rows.prefix(30)) { r in
                                row(r)
                            }

                            if reg.rows.count > 30 {
                                Text("… \(reg.rows.count - 30) more")
                                    .font(.system(.caption2, design: .monospaced))
                                    .opacity(0.6)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
        }
        .foregroundStyle(.primary)
    }

    private var header: some View {
        let total = reg.rows.count
        return HStack(spacing: 8) {
            Text("VM HUD")
                .font(.system(.caption, design: .monospaced).weight(.semibold))

            Text("live=\(total)")
                .font(.system(.caption, design: .monospaced))
                .opacity(0.85)

            Spacer(minLength: 12)

            Text(isExpanded ? "tap:collapse" : "tap:expand")
                .font(.system(.caption2, design: .monospaced))
                .opacity(0.6)
        }
    }

    private func row(_ r: VMInstanceRegistry.SnapshotRow) -> some View {
        let typeShort = r.typeName.split(separator: ".").last.map(String.init) ?? r.typeName
        return HStack(spacing: 8) {
            Text("\(typeShort)#\(r.instanceID)")
                .font(.system(.caption, design: .monospaced))

            if !r.label.isEmpty {
                Text("[\(r.label)]")
                    .font(.system(.caption2, design: .monospaced))
                    .opacity(0.75)
            }

            Spacer(minLength: 8)

            Text(String(format: "%.1fs", r.ageSeconds))
                .font(.system(.caption2, design: .monospaced))
                .opacity(0.65)
        }
    }
}
