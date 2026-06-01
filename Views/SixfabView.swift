
//
//  SixfabView.swift
//  SSHSwiftUIDemo
//
//
//
//  SixfabView.swift
//  SSHSwiftUIDemo
//
//  Sixfab EC-25 LTE UI
//  - Main meters: DEFAULT ROUTE traffic via traffic_snapshot.cgi (VM: rxBytesPerSec/txBytesPerSec/totals)
//  - Secondary meters: LTE-only traffic via traffic_snapshot.cgi (VM: lteRxBytesPerSec/lteTxBytesPerSec/totals)
//  - Session control, LTE test, route sanity, endpoints, tunnel health
//
//  Triple-tap title -> CloudflaredInspectorView
//
//  Lifecycle fixes (2026-01-12):
//  - Polling + initial refresh moved to .task(id:) so SwiftUI auto-cancels on disappear.
//  - Explicit stopPolling() in cancellation path to avoid orphan poll loops.
//
//  iOS 16+
//
//  UPDATED (IP Summary + animated antenna):
//  - IP Summary now prefers the VM fields (which now fallback-promote route.wwan ip/gw into ipv4Address/ipv4Gateway).
//  - “LTE NAT” row now shows wwan nat_ip (real NAT IP) when available, otherwise (none)/(unknown).
//  - Header glyph replaced with AntennaWavesIcon (iOS 16-friendly custom animation) and auto state wiring.
//

import SwiftUI

public struct SixfabView: View {
    @StateObject private var viewModel: SixfabViewModel
    @State private var showCloudflaredInspector: Bool = false

    private let device: Device
    private let title: String
    private let baseCGIURL: URL

    // MARK: - Init
    init(device: Device, title: String = "4G / LTE") {
        self.device = device
        self.title = title

        let urlString = "http://\(device.host)/cgi-bin"
        guard let url = URL(string: urlString) else {
            fatalError("Invalid CGI base URL: \(urlString)")
        }

        self.baseCGIURL = url
        _viewModel = StateObject(wrappedValue: SixfabViewModel(baseCGIURL: url))
    }

    // MARK: - Computed URLs (reachability)
    
    private var antennaActivity: AntennaWavesIcon.Activity {
        if viewModel.connectionState == .error { return .error }
        if viewModel.isConnecting { return .connecting }
        if viewModel.isBusy { return .busy }
        if viewModel.sessionActive { return .active }
        return .idle
    }

    private var cgiPathLAN: String { "/cgi-bin/cgitest.cgi" }
    private var cgiPathLTE: String { "/cgi-bin/lte_http_probe.cgi" }
    private var cgiPathTunnel: String { "/cgi-bin/tunnel_http_probe.cgi" }

    private var lanCGIURLString: String {
        "http://\(device.host)\(cgiPathLAN)"
    }

    private var lteCGIURLString: String? {
        let ip = viewModel.lastKnownLTEIP ?? viewModel.ipv4Address
        guard let ip, !ip.isEmpty else { return nil }
        return "http://\(ip)\(cgiPathLTE)"
    }

    private var tunnelCGIURLString: String? {
        if let stable = viewModel.tunnelStableURL, !stable.isEmpty {
            return stable.hasSuffix("/") ? "\(stable.dropLast())\(cgiPathTunnel)" : "\(stable)\(cgiPathTunnel)"
        }

        if let h = viewModel.tunnelHostnames.first, !h.isEmpty {
            let base = (h.hasPrefix("http://") || h.hasPrefix("https://")) ? h : "https://\(h)"
            return base.hasSuffix("/") ? "\(base.dropLast())\(cgiPathTunnel)" : "\(base)\(cgiPathTunnel)"
        }

        if let temp = viewModel.dynamicTunnelURL, !temp.isEmpty {
            return temp.hasSuffix("/") ? "\(temp.dropLast())\(cgiPathTunnel)" : "\(temp)\(cgiPathTunnel)"
        }

        return nil
    }

    // MARK: - Derived helpers

    private var defaultTrafficIface: String {
        if let s = viewModel.defaultRouteStatsIface, !s.isEmpty { return s }
        if let d = viewModel.defaultRouteDev, !d.isEmpty { return d }
        return "?"
    }

    private var lteIsDefaultRoute: Bool {
        viewModel.wwanIsDefault || viewModel.defaultRouteDev == "wwan0" || viewModel.defaultRouteStatsIface == "wwan0"
    }

    // MARK: - Animated antenna wiring

    @available(iOS 17.0, *)
    private var antennaState: AntennaWavesIcon.Activity {
        if viewModel.connectionState == .error { return .error }
        if viewModel.isConnecting { return .connecting }
        if viewModel.isBusy { return .busy }
        if viewModel.sessionActive { return .active }
        return .idle
    }

    // MARK: - Body

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerCard
                sessionControlsCard
                lteTestCard
                ipSummaryCard
                routeSanityCard
                endpointsCard
                tunnelHealthCard
                defaultRouteTrafficCard
                lteTrafficCard
                footerStatus
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(title)
                    .font(.headline)
                    .onTapGesture(count: 3) {
                        showCloudflaredInspector = true
                    }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await viewModel.refreshOnce() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isBusy)
            }
        }

        // ✅ Single source of truth for lifecycle:
        // SwiftUI cancels on disappear/pop; we stop polling on cancellation.
        .task(id: baseCGIURL) {
            print("[SixfabView] task start base=\(baseCGIURL.absoluteString) host=\(device.host)")
            viewModel.startPolling()

            // Prime immediately (sequential, predictable)
            await viewModel.refreshOnce()
            await viewModel.refreshRoutes()
            await viewModel.refreshTunnelHealth()

            // Park until cancelled
            do {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
            } catch { /* ignore */ }

            print("[SixfabView] task cancelled -> stopPolling base=\(baseCGIURL.absoluteString) host=\(device.host)")
            viewModel.stopPolling()
        }

        .sheet(isPresented: $showCloudflaredInspector) {
            NavigationStack {
                CloudflaredInspectorView(device: device)
            }
        }
    }

    // MARK: - Cards

    private var headerCard: some View {
        HStack(spacing: 12) {
            // ✅ Animated antenna (iOS 16 friendly)
            AntennaWavesIcon(activity: antennaActivity, size: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text("Sixfab EC-25")
                    .font(.headline)

                Text("\(viewModel.iface) • \(viewModel.connectionState.summary)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("operstate: \(viewModel.operstate)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if viewModel.isBusy {
                Text("BUSY")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial)
                    .clipShape(Capsule())
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }

    private var sessionControlsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Session")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(viewModel.sessionActive ? "ACTIVE" : "INACTIVE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(viewModel.sessionActive ? .green : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill((viewModel.sessionActive ? Color.green : Color.gray).opacity(0.12)))
            }

            HStack(spacing: 12) {
                Button {
                    Task { await viewModel.connect() }
                } label: {
                    HStack {
                        if viewModel.isConnecting {
                            ProgressView().progressViewStyle(.circular)
                            Text("Connecting…")
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text(viewModel.sessionActive ? "Reconnect" : "Connect")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isConnecting)

                Button {
                    Task { await viewModel.disconnect() }
                } label: {
                    HStack {
                        if viewModel.isDisconnecting {
                            ProgressView().scaleEffect(0.9)
                            Text("Disconnecting…")
                        } else {
                            Image(systemName: "xmark.circle")
                            Text("Disconnect")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isDisconnecting || !viewModel.sessionActive)
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }

    private var lteTestCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "waveform.path.ecg")
                Text("Test via LTE")
                    .font(.subheadline.weight(.semibold))
                Spacer()

                Text(viewModel.sessionActive ? "LTE READY" : "LTE INACTIVE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(viewModel.sessionActive ? .orange : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill((viewModel.sessionActive ? Color.orange : Color.gray).opacity(0.12)))
            }

            Button {
                Task { await viewModel.testConnectivity() }
            } label: {
                HStack {
                    if viewModel.isTesting {
                        ProgressView().scaleEffect(0.85)
                        Text("Testing via LTE…")
                    } else {
                        Image(systemName: "bolt.horizontal.circle")
                        Text("Run LTE test")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isTesting || !viewModel.sessionActive)

            if let target = viewModel.lastTestTarget,
               let succeeded = viewModel.lastTestSucceeded,
               let timestamp = viewModel.lastTestTimestamp {

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(succeeded ? Color.green : Color.red)
                        .frame(width: 10, height: 10)

                    VStack(alignment: .leading, spacing: 2) {
                        if succeeded, let ms = viewModel.lastTestLatencyMs {
                            Text("Last LTE test: \(String(format: "%.1f ms", ms)) to \(target)")
                                .font(.caption.monospaced())
                        } else {
                            Text("Last LTE test failed to \(target)")
                                .font(.caption.monospaced())
                        }

                        Text(timestamp.formatted(date: .omitted, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }

    private var ipSummaryCard: some View {
        // NOTE:
        // viewModel.ipv4Address / ipv4Gateway are now fallback-promoted from embedded route.wwan when lte_status doesn't provide them.
        // That means this card should no longer show (none) while Route Sanity clearly has wwan0 IP/gw.

        let ip = viewModel.ipv4Address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let gw = viewModel.ipv4Gateway?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let prefix = viewModel.ipv4Prefix?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ipWithPrefix = (!ip.isEmpty && !prefix.isEmpty) ? "\(ip)\(prefix)" : ip

        // Real NAT IP should come from route/wwan nat ip (not lastKnownLTEIP).
        let nat = viewModel.wwanNatIP?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return VStack(alignment: .leading, spacing: 6) {
            Text("IP summary")
                .font(.subheadline.weight(.semibold))

            rowKV("APN", viewModel.apn)

            if !ipWithPrefix.isEmpty {
                rowKV("IP", ipWithPrefix, monospaced: true)
            } else {
                rowKV("IP", "(none)", secondary: true)
            }

            if !gw.isEmpty {
                rowKV("Gateway", gw, monospaced: true)
            } else {
                rowKV("Gateway", "(none)", secondary: true)
            }

            if !nat.isEmpty {
                rowKV("LTE NAT", nat, monospaced: true)
            } else {
                // If your script uses "(none)" for nat_ip, this is the correct display.
                rowKV("LTE NAT", "(none)", secondary: true)
            }

            // Optional: keep the last-known LTE IP visible, because it's still useful for constructing LTE CGNAT probe URLs.
            if let last = viewModel.lastKnownLTEIP?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty {
                rowKV("Last LTE IP", last, monospaced: true, secondary: true)
            }

            Divider().padding(.vertical, 4)

            Text(viewModel.sessionActive ? "Session: ACTIVE" : "Session: INACTIVE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(viewModel.sessionActive ? .green : .secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }

    private var routeSanityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Route sanity")
                    .font(.subheadline.weight(.semibold))
                Spacer()

                if lteIsDefaultRoute {
                    Text("LTE DEFAULT")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                }

                Button {
                    Task { await viewModel.refreshRoutes() }
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    routeBadge(for: viewModel.defaultRouteDev)
                    Text("route_class: \(viewModel.routeClass)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                HStack(spacing: 8) {
                    Text("stats_iface:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(defaultTrafficIface)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                if let line = viewModel.defaultRouteLine, !line.isEmpty {
                    Text(line)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Divider().padding(.vertical, 4)

            ifaceRow(title: "eth0", exists: viewModel.eth0Exists, oper: viewModel.eth0Operstate, up: viewModel.eth0Up, ip: viewModel.eth0IP)
            ifaceRow(title: "wlan0", exists: viewModel.wlan0Exists, oper: viewModel.wlan0Operstate, up: viewModel.wlan0Up, ip: viewModel.wlan0IP)

            VStack(alignment: .leading, spacing: 6) {
                ifaceRow(title: "wwan0", exists: viewModel.wwanExists, oper: viewModel.wwanOperstate, up: viewModel.wwanUp, ip: viewModel.wwanIP)

                rowKV("wwan gw", (viewModel.wwanGateway?.isEmpty == false) ? (viewModel.wwanGateway ?? "") : "(none)", monospaced: true, secondary: viewModel.wwanGateway?.isEmpty != false)
                rowKV("wwan nat_ip", (viewModel.wwanNatIP?.isEmpty == false) ? (viewModel.wwanNatIP ?? "") : "(none)", monospaced: true, secondary: viewModel.wwanNatIP?.isEmpty != false)
            }

            Divider().padding(.vertical, 4)

            HStack(spacing: 8) {
                Text("cloudflared:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(viewModel.tunnelEnabled ? "enabled" : "disabled")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)

                Text(viewModel.tunnelRunning ? "running" : "stopped")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)

                Spacer()

                if viewModel.tunnelEdgeConnections > 0 {
                    Text("edges: \(viewModel.tunnelEdgeConnections)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            if !viewModel.tunnelHostnames.isEmpty {
                Text("hostnames: \(viewModel.tunnelHostnames.joined(separator: ", "))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            if let e = viewModel.tunnelRouteError, !e.isEmpty {
                Text("tunnel error: \(e)")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }

    private var endpointsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Endpoints")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    Task {
                        await viewModel.updateLANStatus(url: lanCGIURLString)
                        if let lte = lteCGIURLString { await viewModel.updateLTEStatus(url: lte) }
                        if let tunnel = tunnelCGIURLString { await viewModel.updateTunnelStatus(url: tunnel) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.horizontal.circle")
                        Text("Test all")
                    }
                    .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }

            endpointRow(label: "LAN", urlString: lanCGIURLString, status: viewModel.lanURLStatus, role: .lan) {
                Task { await viewModel.updateLANStatus(url: lanCGIURLString) }
            }

            endpointRow(label: "LTE (CGNAT)", urlString: lteCGIURLString, status: viewModel.lteURLStatus, role: .lte) {
                guard let lte = lteCGIURLString else { return }
                Task { await viewModel.updateLTEStatus(url: lte) }
            }

            endpointRow(label: "Tunnel", urlString: tunnelCGIURLString, status: viewModel.tunnelURLStatus, role: .tunnel) {
                guard let tun = tunnelCGIURLString else { return }
                Task { await viewModel.updateTunnelStatus(url: tun) }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }

    private var tunnelHealthCard: some View {
        let statusText: String
        let statusColor: Color

        if viewModel.tunnelOK {
            statusColor = .green
            statusText = "OK"
        } else if let err = viewModel.tunnelError, !err.isEmpty {
            statusColor = .red
            statusText = "error: \(err)"
        } else {
            statusColor = .gray
            statusText = "unknown"
        }

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "bolt.horizontal.icloud").foregroundStyle(.purple)
                Text("Tunnel Health").font(.subheadline.weight(.semibold))
                Spacer()

                Button {
                    Task { await viewModel.refreshTunnelHealth() }
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .buttonStyle(.plain)

                Button {
                    Task { await viewModel.startTunnel() }
                } label: {
                    HStack(spacing: 4) {
                        if viewModel.isStartingTunnel {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "link.badge.plus")
                        }
                        Text("Start tunnel").font(.caption)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isStartingTunnel)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(statusColor).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.tunnelName ?? "No tunnel reported")
                        .font(.caption.weight(.semibold))
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(statusColor)
                }
            }

            HStack(spacing: 12) {
                Label { Text("Tunnels: \(viewModel.tunnelCount)") } icon: { Image(systemName: "rectangle.3.offgrid") }
                Label { Text("Connectors: \(viewModel.tunnelConnectorCount)") } icon: { Image(systemName: "antenna.radiowaves.left.and.right") }
            }
            .font(.caption2)

            if let stable = viewModel.tunnelStableURL, !stable.isEmpty {
                Text("Stable: \(stable)")
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Stable: (none configured)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let temp = viewModel.dynamicTunnelURL, !temp.isEmpty {
                Text("Temp: \(temp)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Temp: (no dynamic URL discovered)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }

    private var defaultRouteTrafficCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Default Route Traffic")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                routeBadge(for: defaultTrafficIface)
            }

            HStack(spacing: 14) {
                trafficTile(title: "Download", systemImage: "arrow.down.circle.fill", bytesPerSec: viewModel.rxBytesPerSec)
                trafficTile(title: "Upload", systemImage: "arrow.up.circle.fill", bytesPerSec: viewModel.txBytesPerSec)
            }

            totalsRow(rxBytes: viewModel.totalRxBytes, txBytes: viewModel.totalTxBytes)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }

    private var lteTrafficCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LTE Traffic (wwan0)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                routeBadge(for: "wwan0")
            }

            HStack(spacing: 14) {
                trafficTile(title: "Download", systemImage: "arrow.down.circle.fill", bytesPerSec: viewModel.lteRxBytesPerSec)
                trafficTile(title: "Upload", systemImage: "arrow.up.circle.fill", bytesPerSec: viewModel.lteTxBytesPerSec)
            }

            totalsRow(rxBytes: viewModel.lteTotalRxBytes, txBytes: viewModel.lteTotalTxBytes)

            if !lteIsDefaultRoute {
                Text("LTE isn’t the kernel default route right now — these are wwan0-only counters.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }

    private var footerStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let lastUpdated = viewModel.lastUpdated {
                Text("Last updated: \(lastUpdated.formatted(date: .omitted, time: .standard))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let error = viewModel.lastError, !error.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Endpoint row

    private enum EndpointRole { case lan, lte, tunnel }

    private func endpointRow(
        label: String,
        urlString: String?,
        status: SixfabViewModel.URLCheckResult?,
        role: EndpointRole,
        onTest: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                endpointBadge(for: role, reachable: status?.reachable)
                Text(label).font(.caption.weight(.semibold))
                Spacer()

                Button(action: onTest) {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.horizontal.circle").imageScale(.small)
                        Text("Test").font(.caption2)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(urlString == nil)
                .opacity(urlString == nil ? 0.4 : 1)
            }

            if let urlString {
                Text(urlString)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("No endpoint URL configured")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let status {
                Text(status.status)
                    .font(.caption2)
                    .foregroundStyle(status.reachable ? .green : .red)
            } else {
                Text("Tap Test to check reachability")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func endpointBadge(for role: EndpointRole, reachable: Bool?) -> some View {
        let baseText: String
        let baseColor: Color

        switch role {
        case .lan: baseText = "LAN"; baseColor = .blue
        case .lte: baseText = "LTE"; baseColor = .orange
        case .tunnel: baseText = "TUN"; baseColor = .purple
        }

        let color: Color = {
            if let reachable { return reachable ? baseColor : .red }
            return .gray
        }()

        return Text(baseText)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    // MARK: - Interface row

    private func ifaceRow(title: String, exists: Bool, oper: String, up: Bool, ip: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            routeBadge(for: title)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title) • \(exists ? "exists" : "missing") • operstate=\(oper)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(exists ? .primary : .secondary)

                Text("up: \(up ? "true" : "false") • ip: \(ip?.isEmpty == false ? (ip ?? "") : "(none)")")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Badges

    private func routeBadge(for dev: String?) -> some View {
        let text: String
        let color: Color

        switch dev {
        case "wwan0": text = "LTE"; color = .orange
        case "eth0":  text = "LAN"; color = .blue
        case "wlan0": text = "Wi-Fi"; color = .green
        case .some(let v) where !v.isEmpty: text = v; color = .gray
        default: text = "?"; color = .gray
        }

        return Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    // MARK: - Traffic tiles

    private func trafficTile(title: String, systemImage: String, bytesPerSec: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).imageScale(.large)
                Text(title).font(.subheadline.weight(.semibold))
            }

            Text(formatRate(bytesPerSec: bytesPerSec))
                .font(.title3.monospacedDigit())

            Text(bytesPerSec > 0.5 ? "Active" : "Idle")
                .font(.caption)
                .foregroundStyle(bytesPerSec > 0.5 ? .green : .secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemBackground)))
    }

    // ✅ UInt64 totals
    private func totalsRow(rxBytes: UInt64, txBytes: UInt64) -> some View {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .binary

        let rx = formatter.string(fromByteCount: Int64(clamping: rxBytes))
        let tx = formatter.string(fromByteCount: Int64(clamping: txBytes))

        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Total downloaded")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(rx)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("Total uploaded")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(tx)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(.top, 6)
    }

    // MARK: - Small helpers

    private func rowKV(_ k: String, _ v: String, monospaced: Bool = false, secondary: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(k):")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(v)
                .font(monospaced ? .caption.monospaced() : .caption)
                .foregroundStyle(secondary ? .secondary : .primary)

            Spacer()
        }
    }

    private func formatRate(bytesPerSec: Double) -> String {
        guard bytesPerSec > 0.5 else { return "0 B/s" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = bytesPerSec
        var idx = 0
        while value >= 1024 && idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        return String(format: "%.1f %@", value, units[idx])
    }
}
