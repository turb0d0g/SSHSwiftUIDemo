//
//  TunnelHealthCard.swift
//  SSHSwiftUIDemo
//
//  SwiftUI card rendering TunnelHealthResponse with per-colo badges.
//  iOS 16+
//

import SwiftUI
import os.log

@MainActor
public struct TunnelHealthCard: View {

    private let log = Logger(subsystem: "SSHSwiftUIDemo", category: "TunnelHealthCard")

    public let response: TunnelHealthResponse?
    public let isLoading: Bool
    public let lastError: String?

    public var onRefresh: (() -> Void)?
    public var onStartTunnel: (() -> Void)?

    public init(
        response: TunnelHealthResponse?,
        isLoading: Bool,
        lastError: String? = nil,
        onRefresh: (() -> Void)? = nil,
        onStartTunnel: (() -> Void)? = nil
    ) {
        self.response = response
        self.isLoading = isLoading
        self.lastError = lastError
        self.onRefresh = onRefresh
        self.onStartTunnel = onStartTunnel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            headerRow

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            statusRow

            if let resp = response, resp.ok == true, resp.connectorCount ?? 0 > 0 {
                metricsRow(resp)
                coloBadges(resp)
                originIPs(resp)
            } else {
                emptyState
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.opacity(0.25), lineWidth: 1)
        )
        .onAppear {
            log.debug("TunnelHealthCard appear response.ok=\(self.response?.ok == true, privacy: .public) connectors=\(self.response?.connectorCount ?? -1, privacy: .public)")
        }
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Label("Tunnel Health", systemImage: "cloud.fill")
                .font(.headline)

            Spacer()

            Button {
                log.debug("TunnelHealthCard refresh tapped")
                onRefresh?()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.headline)
            }
            .buttonStyle(.plain)

            if let onStartTunnel {
                Button {
                    log.debug("TunnelHealthCard start tunnel tapped")
                    onStartTunnel()
                } label: {
                    Label("Start tunnel", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var statusRow: some View {
        let ok = response?.ok == true
        let hasData = (response?.connectorCount ?? 0) > 0

        return HStack(spacing: 10) {
            Circle()
                .frame(width: 10, height: 10)
                .foregroundStyle(ok && hasData ? .green : .red)

            if let resp = response {
                if resp.ok == true && hasData {
                    Text("Connected")
                        .font(.subheadline.weight(.semibold))
                } else if resp.ok == true && !hasData {
                    Text("No connectors reported")
                        .font(.subheadline.weight(.semibold))
                } else {
                    Text("Error")
                        .font(.subheadline.weight(.semibold))
                }
            } else {
                Text("No tunnel reported")
                    .font(.subheadline.weight(.semibold))
            }

            Spacer()

            // No timestamp field in TunnelHealthResponse schema.
        }
        .foregroundStyle(.primary)
    }

    private func metricsRow(_ resp: TunnelHealthResponse) -> some View {
        HStack(spacing: 12) {
            Label("Tunnels: \(resp.info?.id == nil ? 0 : 1)", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.caption)

            Label("Connectors: \(resp.connectorCount ?? 0)", systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption)

            Label("Edges: \(resp.edgeCount)", systemImage: "network")
                .font(.caption)

            Spacer()
        }
        .foregroundStyle(.secondary)
    }

    private func coloBadges(_ resp: TunnelHealthResponse) -> some View {
        let groups = resp.edgesByColo

        return VStack(alignment: .leading, spacing: 8) {
            Text("Colo connections")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(groups, id: \.colo) { group in
                    let colo = group.colo
                    let count = group.edges.count
                    let pending = group.edges.contains(where: { $0.isPendingReconnect == true })

                    HStack(spacing: 6) {
                        Text(colo.uppercased())
                            .font(.caption.weight(.semibold))

                        Text("\(count)")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.thinMaterial, in: Capsule())

                        if pending {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.opacity(0.25), lineWidth: 1))
                    .accessibilityLabel("\(colo) \(count) connections")
                }
            }
        }
    }

    private func originIPs(_ resp: TunnelHealthResponse) -> some View {
        let ips = resp.uniqueOriginIPs
        guard !ips.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(
            VStack(alignment: .leading, spacing: 6) {
                Text("Origin IPs")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(ips.joined(separator: " • "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = lastError ?? response?.error {
                Text("error: \(err)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else {
                Text("Stable: (none configured)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Temp: (no dynamic URL discovered)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

//
// Simple flow layout for “badges” without iOS 17 Layout protocol.
// iOS 16 compatible.
// Not fancy; just works.
//
private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    let lineSpacing: CGFloat
    @ViewBuilder let content: Content

    init(spacing: CGFloat, lineSpacing: CGFloat, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        self.content = content()
    }

    var body: some View {
        GeometryReader { geo in
            _FlowLayoutBody(
                width: geo.size.width,
                spacing: spacing,
                lineSpacing: lineSpacing,
                content: content
            )
        }
        .frame(minHeight: 1)
    }
}

private struct _FlowLayoutBody<Content: View>: View {
    let width: CGFloat
    let spacing: CGFloat
    let lineSpacing: CGFloat
    let content: Content

    @State private var totalHeight: CGFloat = .zero

    init(width: CGFloat, spacing: CGFloat, lineSpacing: CGFloat, content: Content) {
        self.width = width
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .preference(key: _SizePreferenceKey.self, value: proxy.size)
                    }
                )
        }
        .frame(height: totalHeight)
        .onPreferenceChange(_SizePreferenceKey.self) { _ in
            // Intentionally no-op; actual wrapping happens via alignment guides below.
        }
        .overlay(alignment: .topLeading) {
            _WrappedContent(width: width, spacing: spacing, lineSpacing: lineSpacing, totalHeight: $totalHeight) {
                content
            }
        }
    }
}

private struct _WrappedContent<Content: View>: View {
    let width: CGFloat
    let spacing: CGFloat
    let lineSpacing: CGFloat
    @Binding var totalHeight: CGFloat
    let content: Content

    init(width: CGFloat, spacing: CGFloat, lineSpacing: CGFloat, totalHeight: Binding<CGFloat>, @ViewBuilder content: () -> Content) {
        self.width = width
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        self._totalHeight = totalHeight
        self.content = content()
    }

    var body: some View {
        var x: CGFloat = 0
        var y: CGFloat = 0

        return ZStack(alignment: .topLeading) {
            content
                .alignmentGuide(.leading) { d in
                    if x + d.width > width {
                        x = 0
                        y -= (d.height + lineSpacing)
                    }
                    let result = x
                    x += d.width + spacing
                    return result
                }
                .alignmentGuide(.top) { d in
                    let result = y
                    totalHeight = abs(y) + d.height
                    return result
                }
        }
    }
}

private struct _SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
