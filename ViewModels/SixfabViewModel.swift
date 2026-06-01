//
//  SixfabViewModel.swift
//  SSHSwiftUIDemo
//
//
//  SixfabViewModel.swift
//  SSHSwiftUIDemo
//
//  ViewModel for Sixfab EC-25 LTE screen.
//
//  Poll strategy (UPDATED):
//   - /cgi-bin/lte_status.cgi         session state (fast, stable)
//   - /cgi-bin/traffic_snapshot.cgi   unified: default traffic + LTE traffic + embedded route + full tunnel snapshot
//   - /cgi-bin/lte_connect.cgi / lte_disconnect.cgi / lte_test.cgi remain unchanged
//
//  This file stays schema-tolerant; tunnel_snapshot payload is best-effort.
//

import Foundation
import SwiftUI

@MainActor
public final class SixfabViewModel: ObservableObject {

    // MARK: - Types

    public struct URLCheckResult: Sendable {
        public let reachable: Bool
        public let status: String
        public let ms: Double?
        public let timestamp: Date
    }

    public enum ConnectionState: String, Sendable {
        case idle
        case active
        case inactive
        case connecting
        case disconnecting
        case error

        public var isActive: Bool { self == .active }
        public var summary: String {
            switch self {
            case .idle: return "idle"
            case .active: return "connected"
            case .inactive: return "disconnected"
            case .connecting: return "connecting"
            case .disconnecting: return "disconnecting"
            case .error: return "error"
            }
        }
    }

    // MARK: - Published UI State (used by SixfabView.swift)

    @Published public var lastUpdated: Date?
    @Published public var lastError: String?

    // LTE Session status
    @Published public var connectionState: ConnectionState = .idle
    @Published public var isBusy: Bool = false

    @Published public var isConnecting: Bool = false
    @Published public var isDisconnecting: Bool = false
    @Published public var isTesting: Bool = false
    @Published public var isStartingTunnel: Bool = false

    @Published public var iface: String = "wwan0"
    @Published public var operstate: String = "unknown"
    @Published public var apn: String = "unknown"

    @Published public var sessionActive: Bool = false
    @Published public var ipv4Address: String?
    @Published public var ipv4Prefix: String?
    @Published public var ipv4Gateway: String?
    @Published public var lastKnownLTEIP: String?

    // Connectivity test
    @Published public var lastTestTarget: String?
    @Published public var lastTestSucceeded: Bool?
    @Published public var lastTestLatencyMs: Double?
    @Published public var lastTestTimestamp: Date?

    // Endpoint reachability cards
    @Published public var lanURLStatus: URLCheckResult?
    @Published public var lteURLStatus: URLCheckResult?
    @Published public var tunnelURLStatus: URLCheckResult?

    // Tunnel Health card (now derived from traffic_snapshot -> route.tunnel + tunnel_snapshot)
    @Published public var tunnelOK: Bool = false
    @Published public var tunnelError: String?
    @Published public var tunnelName: String?
    @Published public var tunnelCount: Int = 0
    @Published public var tunnelConnectorCount: Int = 0
    @Published public var tunnelStableURL: String?
    @Published public var dynamicTunnelURL: String?

    // Route sanity card (now derived from traffic_snapshot.route)
    @Published public var defaultRouteLine: String?
    @Published public var defaultRouteDev: String?
    @Published public var defaultRouteVia: String?
    @Published public var routeClass: String = "unknown"
    @Published public var defaultRouteStatsIface: String?

    @Published public var eth0Exists: Bool = false
    @Published public var eth0Operstate: String = "missing"
    @Published public var eth0Up: Bool = false
    @Published public var eth0IP: String?

    @Published public var wlan0Exists: Bool = false
    @Published public var wlan0Operstate: String = "missing"
    @Published public var wlan0Up: Bool = false
    @Published public var wlan0IP: String?

    @Published public var wwanExists: Bool = false
    @Published public var wwanOperstate: String = "missing"
    @Published public var wwanUp: Bool = false
    @Published public var wwanIP: String?
    @Published public var wwanGateway: String?
    @Published public var wwanNatIP: String?
    @Published public var wwanIsDefault: Bool = false

    @Published public var tunnelEnabled: Bool = false
    @Published public var tunnelRunning: Bool = false
    @Published public var tunnelEdgeConnections: Int = 0
    @Published public var tunnelHostnames: [String] = []
    @Published public var tunnelRouteError: String?

    // Traffic meters shown in SixfabView.swift (DEFAULT ROUTE traffic)
    @Published public var rxBytesPerSec: Double = 0
    @Published public var txBytesPerSec: Double = 0

    // ✅ Updated: totals are UInt64 end-to-end
    @Published public var totalRxBytes: UInt64 = 0
    @Published public var totalTxBytes: UInt64 = 0

    // (kept for debugging / future UI) — LTE interface-only traffic
    @Published public var lteRxBytesPerSec: Double = 0
    @Published public var lteTxBytesPerSec: Double = 0

    // ✅ Updated: totals are UInt64 end-to-end
    @Published public var lteTotalRxBytes: UInt64 = 0
    @Published public var lteTotalTxBytes: UInt64 = 0

    // Tunnel snapshot details (rich list UI)
    @Published public var tunnelConnectors: [TunnelConnectorUI] = []
    @Published public var tunnelRoutes: [TunnelRouteUI] = []

    // ✅ ARC lifecycle tracking (token-based, no retain cycle)
    private var arcToken: ARCTracker.Token?

    // MARK: - Config
    public let baseCGIURL: URL

    // MARK: - Internals
    private var pollTask: Task<Void, Never>?
    private var pollTick: Int = 0

    /// Avoid “refreshOnce” piling up from UI + timer.
    private var refreshInFlight = false

    // MARK: - Init

    public init(baseCGIURL: URL) {
        self.baseCGIURL = baseCGIURL

        print("[SixfabViewModel] init base=\(baseCGIURL.absoluteString)")

        // ✅ ARC tracking: registerToken(self) then store token.
        Task { [weak self] in
            guard let self else { return }
            let token = await ARCTracker.shared.registerToken(self, note: String(reflecting: type(of: self)), expectedLifetime: .transient)
            self.arcToken = token
            print("[SixfabViewModel] ARCTracker.registerToken ok token.id=\(token.id) oidRaw=\(token.oidRaw)")
        }
    }

    deinit {
        print("[DEINIT] \(String(describing: Self.self))")
        print("[SixfabViewModel] deinit → stopPolling()")

        pollTask?.cancel()
        pollTask = nil

        // ✅ Unregister by token (does not retain self).
        if let token = arcToken {
            Task {
                await ARCTracker.shared.unregister(token: token)
                print("[SixfabViewModel] ARCTracker.unregister(token) ok token.id=\(token.id)")
            }
        } else {
            print("[SixfabViewModel] deinit (no arcToken yet)")
        }
    }

    // MARK: - Polling

    public func startPolling(interval: TimeInterval = 2.0) {
        stopPolling()

        print("[SixfabViewModel] startPolling interval=\(interval)s base=\(baseCGIURL.absoluteString)")

        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                autoreleasepool {
                    Task { @MainActor in
                        await self.refreshOnce()
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stopPolling() {
        if pollTask != nil {
            print("[SixfabViewModel] stopPolling")
        }
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Manual refresh buttons used by SixfabView.swift

    /// Route sanity now comes from traffic_snapshot.cgi (embedded route block).
    public func refreshRoutes() async {
        print("[SixfabViewModel] refreshRoutes")
        do {
            let snap = try await getJSON(TrafficSnapshotResponse.self, path: "traffic_snapshot.cgi", timeout: 10)
            applyTrafficSnapshot(snap)
            lastUpdated = Date()
        } catch {
            lastError = error.localizedDescription
            print("[SixfabViewModel] ERROR refreshRoutes: \(error)")
        }
    }

    /// Tunnel health now comes from traffic_snapshot.cgi (route.tunnel + tunnel_snapshot).
    public func refreshTunnelHealth() async {
        print("[SixfabViewModel]  refreshTunnelHealth")
        do {
            let snap = try await getJSON(TrafficSnapshotResponse.self, path: "traffic_snapshot.cgi", timeout: 10)
            applyTrafficSnapshot(snap)
            lastUpdated = Date()
        } catch {
            lastError = error.localizedDescription
            print("[SixfabViewModel] ERROR refreshTunnelHealth: \(error)")
        }
    }

    /// Starts cloudflared tunnel (expects a CGI to exist).
    public func startTunnel() async {
        print("[SixfabViewModel] startTunnel")
        guard !isStartingTunnel else { return }
        isStartingTunnel = true
        defer { isStartingTunnel = false }

        do {
            let resp = try await getJSON(SimpleOKResponse.self, path: "tunnel_start.cgi", timeout: 20)

            if resp.ok == true {
                print("[SixfabViewModel] startTunnel ok")
            } else {
                let msg = resp.error ?? "startTunnel failed"
                lastError = msg
                print("[SixfabViewModel] startTunnel not ok: \(msg)")
            }

            // Pull latest state after attempting start
            await refreshTunnelHealth()

        } catch {
            lastError = error.localizedDescription
            print("[SixfabViewModel] ERROR startTunnel: \(error)")
        }
    }

    // MARK: - One-shot refresh (UPDATED: lte_status + traffic_snapshot only)

    public func refreshOnce() async {
        if refreshInFlight { return }
        refreshInFlight = true
        defer { refreshInFlight = false }

        if isBusy { return }
        isBusy = true
        defer { isBusy = false }

        pollTick &+= 1

        do {
            lastError = nil

            // 1) LTE status (fast)
            let lteStatus = try await getJSON(LTEStatusResponse.self, path: "lte_status.cgi", timeout: 10)

            // 2) Unified traffic snapshot
            let snapResult: TrafficSnapshotResponse? = try? await getJSON(TrafficSnapshotResponse.self, path: "traffic_snapshot.cgi", timeout: 10)

            autoreleasepool {
                self.applyLTEStatus(lteStatus)

                if let snap = snapResult {
                    self.applyTrafficSnapshot(snap)
                }

                self.lastUpdated = Date()
            }
        } catch {
            lastError = error.localizedDescription
            print("[SixfabViewModel] ERROR refreshOnce: \(error)")
        }
    }

    // MARK: - LTE Session controls

    public func connect() async {
        print("[SixfabViewModel] connect")
        guard !isConnecting else { return }
        isConnecting = true
        connectionState = .connecting
        defer { isConnecting = false }

        do {
            let resp = try await getJSON(SimpleOKResponse.self, path: "lte_connect.cgi", timeout: 30)
            if resp.ok == true {
                print("[SixfabViewModel] lte_connect ok")
            } else {
                print("[SixfabViewModel] lte_connect not ok: \(resp.error ?? "unknown")")
            }

            await refreshOnce()

        } catch {
            lastError = error.localizedDescription
            connectionState = .error
        }
    }

    public func disconnect() async {
        print("[SixfabViewModel] disconnect")
        guard !isDisconnecting else { return }
        isDisconnecting = true
        connectionState = .disconnecting
        defer { isDisconnecting = false }

        do {
            let resp = try await getJSON(SimpleOKResponse.self, path: "lte_disconnect.cgi", timeout: 30)
            if resp.ok == true {
                print("[SixfabViewModel] lte_disconnect ok")
            } else {
                print("[SixfabViewModel] lte_disconnect not ok: \(resp.error ?? "unknown")")
            }

            await refreshOnce()

        } catch {
            lastError = error.localizedDescription
            connectionState = .error
        }
    }

    // MARK: - LTE connectivity test

    public func testConnectivity(target: String = "https://api.ipify.org") async {
        print("[SixfabViewModel] test connnectivity")
        guard sessionActive else { return }
        guard !isTesting else { return }

        isTesting = true
        defer { isTesting = false }

        do {
            var comps = URLComponents(url: baseCGIURL.appendingPathComponent("lte_test.cgi"), resolvingAgainstBaseURL: false)
            comps?.queryItems = [URLQueryItem(name: "target", value: target)]
            guard let url = comps?.url else { throw URLError(.badURL) }

            print("[SixfabViewModel] GET lte_test.cgi \(url.absoluteString)")
            var req = URLRequest(url: url)
            req.timeoutInterval = 20
            req.cachePolicy = .reloadIgnoringLocalCacheData

            let start = CFAbsoluteTimeGetCurrent()
            let (data, resp) = try await URLSession.shared.data(for: req)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

            if let http = resp as? HTTPURLResponse {
                print("[SixfabViewModel] lte_test.cgi HTTP \(http.statusCode) bytes=\(data.count) \(String(format: "%.1f", elapsedMs))ms")
            }

            let decoded = try iso8601Decoder().decode(LTETestResponse.self, from: data)

            lastTestTarget = decoded.target ?? target
            lastTestSucceeded = decoded.ok ?? false
            lastTestLatencyMs = decoded.latencyMs ?? elapsedMs
            lastTestTimestamp = Date()

        } catch {
            lastTestTarget = target
            lastTestSucceeded = false
            lastTestLatencyMs = nil
            lastTestTimestamp = Date()
            lastError = error.localizedDescription
        }
    }

    // MARK: - Endpoint reachability

    public func updateLANStatus(url: String) async {
        print("[SixfabViewModel] updateLANStatus")
        lanURLStatus = await checkURL(urlString: url, label: "LAN")
    }

    public func updateLTEStatus(url: String) async {
        print("[SixfabViewModel] updateLTEStatus")
        lteURLStatus = await checkURL(urlString: url, label: "LTE")
    }

    public func updateTunnelStatus(url: String) async {
        print("[SixfabViewModel] updateTunnelStatus")
        tunnelURLStatus = await checkURL(urlString: url, label: "TUNNEL")
    }

    private func checkURL(urlString: String, label: String) async -> URLCheckResult {
        let now = Date()

        guard let url = URL(string: urlString) else {
            return URLCheckResult(reachable: false, status: "Bad URL", ms: nil, timestamp: now)
        }

        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 6
            req.cachePolicy = .reloadIgnoringLocalCacheData

            let start = CFAbsoluteTimeGetCurrent()
            let (_, resp) = try await URLSession.shared.data(for: req)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

            if let http = resp as? HTTPURLResponse {
                let ok = (200..<300).contains(http.statusCode)
                return URLCheckResult(
                    reachable: ok,
                    status: "HTTP \(http.statusCode) \(String(format: "%.0fms", elapsedMs))",
                    ms: elapsedMs,
                    timestamp: now
                )
            } else {
                return URLCheckResult(reachable: true, status: "Non-HTTP OK", ms: elapsedMs, timestamp: now)
            }

        } catch {
            return URLCheckResult(reachable: false, status: error.localizedDescription, ms: nil, timestamp: now)
        }
    }

    // MARK: - Apply LTE decoded models

    private func applyLTEStatus(_ resp: LTEStatusResponse) {
        iface = resp.iface ?? iface
        operstate = resp.operstate ?? "unknown"
        apn = resp.apn ?? apn

        // NOTE:
        // lte_status.cgi "ok" can mean script success, not necessarily "connected".
        // We'll treat presence of an IP as strong "active" signal and keep ok as weak fallback.
        ipv4Address = resp.ipv4
        ipv4Prefix = resp.prefix
        ipv4Gateway = resp.gw

        if let ip = resp.ipv4?.trimmingCharacters(in: .whitespacesAndNewlines), !ip.isEmpty {
            lastKnownLTEIP = ip
        }

        let hasIP = (resp.ipv4?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        sessionActive = hasIP || (resp.ok ?? false)

        connectionState = sessionActive ? .active : .inactive
    }

    // MARK: - Apply unified traffic snapshot

    private func applyTrafficSnapshot(_ snap: TrafficSnapshotResponse) {
        // ---- Default route meters (what your UI shows)
        if let def = snap.defaultRoute {
            rxBytesPerSec = def.rxBytesPerSec ?? rxBytesPerSec
            txBytesPerSec = def.txBytesPerSec ?? txBytesPerSec
            totalRxBytes  = def.rxBytes ?? totalRxBytes
            totalTxBytes  = def.txBytes ?? totalTxBytes

            let iface = def.iface ?? snap.defaultRouteIface ?? "unknown"
            print("[SixfabViewModel] [TRAFFIC] default iface=\(iface) rxps=\(rxBytesPerSec) txps=\(txBytesPerSec) rx=\(totalRxBytes) tx=\(totalTxBytes)")
            print("[SixfabViewModel] [TOTALS] default rx=\(totalRxBytes) tx=\(totalTxBytes) (UInt64)")
        }

        // ---- LTE-only meters (debug/future UI)
        if let lte = snap.lte {
            lteRxBytesPerSec = lte.rxBytesPerSec ?? lteRxBytesPerSec
            lteTxBytesPerSec = lte.txBytesPerSec ?? lteTxBytesPerSec
            lteTotalRxBytes  = lte.rxBytes ?? lteTotalRxBytes
            lteTotalTxBytes  = lte.txBytes ?? lteTotalTxBytes

            print("[SixfabViewModel] [TOTALS] lte rx=\(lteTotalRxBytes) tx=\(lteTotalTxBytes) (UInt64)")
        }

        // ---- Route block (embedded route_status equivalent)
        if let r = snap.route {
            defaultRouteLine = r.defaultRouteLine
            defaultRouteDev  = r.defaultRouteIface
            defaultRouteVia  = r.defaultRouteVia
            defaultRouteStatsIface = r.defaultRouteStatsIface
            routeClass = r.routeClass ?? routeClass

            // LAN
            eth0Exists = r.lan?.eth0?.exists ?? eth0Exists
            eth0Operstate = r.lan?.eth0?.operstate ?? eth0Operstate
            eth0Up = r.lan?.eth0?.up ?? eth0Up
            eth0IP = r.lan?.eth0?.ipOrNil

            wlan0Exists = r.lan?.wlan0?.exists ?? wlan0Exists
            wlan0Operstate = r.lan?.wlan0?.operstate ?? wlan0Operstate
            wlan0Up = r.lan?.wlan0?.up ?? wlan0Up
            wlan0IP = r.lan?.wlan0?.ipOrNil

            // WWAN
            wwanExists = r.wwan?.exists ?? wwanExists
            wwanOperstate = r.wwan?.operstate ?? wwanOperstate
            wwanUp = r.wwan?.up ?? wwanUp
            wwanIP = r.wwan?.ipOrNil
            wwanGateway = r.wwan?.gatewayOrNil
            wwanIsDefault = r.wwan?.isDefaultRoute ?? wwanIsDefault

            // ✅ IMPORTANT:
            // Your UI "IP summary" shows ipv4/gw/prefix coming from lte_status.cgi.
            // But route_sanity (embedded here) is often the ONLY reliable source of wwan IP/gw.
            // So we promote route values into the IP summary fields as fallback.
            let trimmedLTEIP = ipv4Address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmedLTEIP.isEmpty, let ip = wwanIP, !ip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ipv4Address = ip
                lastKnownLTEIP = ip
                print("[SixfabViewModel] [IP-SUMMARY] fallback ipv4Address <- route.wwan.ip \(ip)")
            }

            let trimmedLTEGW = ipv4Gateway?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmedLTEGW.isEmpty, let gw = wwanGateway, !gw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ipv4Gateway = gw
                print("[SixfabViewModel] [IP-SUMMARY] fallback ipv4Gateway <- route.wwan.gateway \(gw)")
            }

            if (operstate == "unknown" || operstate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
               let op = wwanOperstate.nilIfEmpty {
                operstate = op
                print("[SixfabViewModel] [IP-SUMMARY] fallback operstate <- route.wwan.operstate \(op)")
            }

            // If wwan clearly up with an IP, treat the session as active (strong signal).
            if wwanUp, let ip = wwanIP?.nilIfEmpty {
                if sessionActive == false {
                    print("[SixfabViewModel] [SESSION] promote sessionActive=true (wwanUp + hasIP) ip=\(ip)")
                }
                sessionActive = true
                connectionState = .active
            }

            // Tunnel (light)
            tunnelEnabled = r.tunnel?.enabled ?? tunnelEnabled
            tunnelRunning = r.tunnel?.running ?? tunnelRunning
            tunnelEdgeConnections = r.tunnel?.edgeConnections ?? tunnelEdgeConnections
            tunnelHostnames = r.tunnel?.hostnames ?? tunnelHostnames
            tunnelRouteError = (r.tunnel?.error?.isEmpty == false) ? r.tunnel?.error : nil

            tunnelOK = (tunnelEnabled && tunnelEdgeConnections > 0)

            if (tunnelStableURL == nil || tunnelStableURL?.isEmpty == true),
               let primary = tunnelHostnames.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                tunnelStableURL = primary.hasPrefix("http") ? primary : "https://\(primary)"
            }
        }

        // ---- Full tunnel snapshot (best-effort)
        if let full = snap.tunnelSnapshot {
            if let stable = full.stableURL, !stable.isEmpty { tunnelStableURL = stable }
            if let temp = full.tempURL, !temp.isEmpty { dynamicTunnelURL = temp }

            if let name = full.tunnelIdent, !name.isEmpty {
                tunnelName = name
            } else if tunnelName == nil || tunnelName?.isEmpty == true {
                tunnelName = full.tunnelID
            }

            tunnelConnectorCount = full.connectorCount ?? tunnelConnectorCount
            tunnelCount = tunnelConnectorCount

            if full.ok == false {
                tunnelOK = false
                tunnelError = full.error ?? "tunnel_snapshot not ok"
            } else {
                tunnelError = (full.error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? full.error : nil
                tunnelOK = full.running ?? tunnelOK
                tunnelEdgeConnections = full.edgeConnections ?? tunnelEdgeConnections
                if let hn = full.hostnames, !hn.isEmpty { tunnelHostnames = hn }
            }
        } else {
            if tunnelEnabled && !tunnelOK && (tunnelError == nil || tunnelError?.isEmpty == true) {
                tunnelError = "tunnel_snapshot missing"
            }
        }
    }

    // MARK: - Networking helpers

    private func getJSON<T: Decodable>(_ type: T.Type, path: String, timeout: TimeInterval) async throws -> T {
        let url = baseCGIURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData

        print("[SixfabViewModel] GET \(path) \(url.absoluteString)")
        let (data, resp) = try await URLSession.shared.data(for: req)

        guard let http = resp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        print("[SixfabViewModel] \(path) HTTP \(http.statusCode) bytes=\(data.count)")

        guard (200..<300).contains(http.statusCode) else {
            let errorMessage = String(data: data.prefix(500), encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            let error = URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(http.statusCode) for \(path)",
                NSURLErrorFailingURLErrorKey: url,
                "responseBody": errorMessage
            ])
            print("[SixfabViewModel] HTTP error for \(path): \(http.statusCode)")
            throw error
        }

        do {
            return try SixfabViewModel.decoder.decode(T.self, from: data)
        } catch {
            let head = String(data: data.prefix(900), encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            print("[SixfabViewModel] decode failed for \(path). Raw head:\n\(head)")
            throw error
        }
    }

    private func iso8601Decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()

            if let s = try? c.decode(String.self) {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let dt = iso.date(from: s) { return dt }

                let iso2 = ISO8601DateFormatter()
                iso2.formatOptions = [.withInternetDateTime]
                if let dt = iso2.date(from: s) { return dt }

                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid date string: \(s)")
            }

            if let seconds = try? c.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }

            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid date type")
        }

        return d
    }

    // MARK: - Shared decoding (NO per-decode formatter allocation)

    private static let isoWithFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()

            if let s = try? c.decode(String.self) {
                if let dt = SixfabViewModel.isoWithFrac.date(from: s) { return dt }
                if let dt = SixfabViewModel.isoNoFrac.date(from: s) { return dt }
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid date string: \(s)")
            }

            if let seconds = try? c.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }

            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid date type")
        }
        return d
    }()
}

// MARK: - Response Models (schema-tolerant)

private struct SimpleOKResponse: Codable, Sendable {
    let ok: Bool?
    let error: String?
}

private struct LTETestResponse: Codable, Sendable {
    let ok: Bool?
    let target: String?
    let latencyMs: Double?

    private enum CodingKeys: String, CodingKey {
        case ok
        case target
        case latencyMs = "latency_ms"
    }
}

public struct TunnelConnectorUI: Identifiable, Sendable {
    public let id: String
    public let created: String?
    public let arch: String?
    public let version: String?
    public let originIP: String?
    public let edges: [TunnelEdgeUI]
}

public struct TunnelEdgeUI: Identifiable, Sendable {
    public let id: String
    public let colo: String?
    public let originIP: String?
    public let openedAt: String?
    public let isPendingReconnect: Bool
}

public struct TunnelRouteUI: Identifiable, Sendable {
    public let id: String
    public let hostname: String
    public let tunnelID: String?
    public let tunnelName: String?
}

/// ✅ traffic_snapshot.cgi
private struct TrafficSnapshotResponse: Decodable, Sendable {
    let ok: Bool?
    let timestamp: Date?

    let defaultRouteIface: String?
    let defaultRoute: TrafficIfaceBlock?

    let lte: TrafficIfaceBlock?

    let route: EmbeddedRouteStatus?

    let tunnelSnapshotOK: Bool?
    let tunnelSnapshot: TunnelSnapshot?

    private enum CodingKeys: String, CodingKey {
        case ok
        case timestamp
        case defaultRouteIface = "default_route_iface"
        case defaultRoute = "default_route"
        case lte
        case route
        case tunnelSnapshotOK = "tunnel_snapshot_ok"
        case tunnelSnapshot = "tunnel_snapshot"
    }
}

private struct TrafficIfaceBlock: Decodable, Sendable {
    let ok: Bool?
    let iface: String?
    let operstate: String?
    let carrier: Int?

    let timestamp: Date?

    let firstRun: Bool?
    let deltaSeconds: Double?

    let rxBytes: UInt64?
    let txBytes: UInt64?

    let rxBytesPerSec: Double?
    let txBytesPerSec: Double?

    private enum CodingKeys: String, CodingKey {
        case ok, iface, operstate, carrier, timestamp
        case firstRun = "first_run"
        case deltaSeconds = "delta_seconds"
        case rxBytes = "rx_bytes"
        case txBytes = "tx_bytes"
        case rxBytesPerSec = "rx_bytes_per_sec"
        case txBytesPerSec = "tx_bytes_per_sec"
    }
}

private struct EmbeddedRouteStatus: Decodable, Sendable {
    let ok: Bool?
    let timestamp: Date?

    let defaultRouteLine: String?
    let defaultRouteIface: String?
    let defaultRouteVia: String?
    let defaultRouteStatsIface: String?
    let routeClass: String?

    let lan: LAN?
    let wwan: WWAN?
    let tunnel: TunnelLight?

    private enum CodingKeys: String, CodingKey {
        case ok
        case timestamp
        case defaultRouteLine = "default_route_line"
        case defaultRouteIface = "default_route_iface"
        case defaultRouteVia = "default_route_via"
        case defaultRouteStatsIface = "default_route_stats_iface"
        case routeClass = "route_class"
        case lan
        case wwan
        case tunnel
    }

    struct LAN: Decodable, Sendable {
        let eth0: Interface?
        let wlan0: Interface?
    }

    struct Interface: Decodable, Sendable {
        let exists: Bool?
        let state: String?
        let operstate: String?
        let up: Bool?
        let ip: String?

        var ipOrNil: String? {
            guard let ip, !ip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ip
        }
    }

    struct WWAN: Decodable, Sendable {
        let iface: String?
        let exists: Bool?
        let state: String?
        let operstate: String?
        let up: Bool?
        let ipaddr: String?
        let gateway: String?
        let isDefaultRoute: Bool?

        private enum CodingKeys: String, CodingKey {
            case iface
            case exists
            case state
            case operstate
            case up
            case ipaddr
            case gateway
            case isDefaultRoute = "is_default_route"
        }

        var ipOrNil: String? {
            guard let ipaddr, !ipaddr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ipaddr
        }

        var gatewayOrNil: String? {
            guard let gateway, !gateway.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return gateway
        }
    }

    struct TunnelLight: Decodable, Sendable {
        let enabled: Bool?
        let running: Bool?
        let id: String?
        let name: String?
        let edgeConnections: Int?
        let error: String?

        private enum CodingKeys: String, CodingKey {
            case enabled
            case running
            case id
            case name
            case edgeConnections = "edge_connections"
            case error
        }

        var hostnames: [String]? { nil }
    }
}

/// Full tunnel_snapshot payload (schema-tolerant)
private struct TunnelSnapshot: Decodable, Sendable {
    public let iface: String?
    public let timestamp: Date?

    public let rxBytes: UInt64?
    public let txBytes: UInt64?

    public let rxBps: UInt64?
    public let txBps: UInt64?

    let ok: Bool?
    let host: String?
    let tunnelIdent: String?
    let tunnelID: String?

    let enabled: Bool?
    let running: Bool?

    let connectorCount: Int?
    let edgeConnections: Int?

    let hostnames: [String]?
    let stableURLs: [String]?
    let stableURL: String?
    let tempURL: String?

    let error: String?

    let connectors: [Connector]?
    let routes: [Route]?

    private enum CodingKeys: String, CodingKey {
        case ok
        case iface
        case timestamp
        case host
        case tunnelIdent = "tunnel_ident"
        case tunnelID = "tunnel_id"
        case enabled
        case running
        case connectorCount = "connector_count"
        case edgeConnections = "edge_connections"
        case hostnames
        case stableURLs = "stable_urls"
        case stableURL = "stable_url"
        case tempURL = "temp_url"
        case routes
        case connectors
        case error

        case rxBytes = "rx_bytes"
        case txBytes = "tx_bytes"
        case rxBps   = "rx_bps"
        case txBps   = "tx_bps"

        case rxBytesAlt1 = "rx"
        case txBytesAlt1 = "tx"
        case rxBytesAlt2 = "rx_total"
        case txBytesAlt2 = "tx_total"
        case rxBpsAlt1   = "rx_rate"
        case txBpsAlt1   = "tx_rate"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try? c.decodeIfPresent(Bool.self, forKey: .ok)
        host = try? c.decodeIfPresent(String.self, forKey: .host)
        tunnelIdent = try? c.decodeIfPresent(String.self, forKey: .tunnelIdent)
        tunnelID = try? c.decodeIfPresent(String.self, forKey: .tunnelID)
        enabled = try? c.decodeIfPresent(Bool.self, forKey: .enabled)
        running = try? c.decodeIfPresent(Bool.self, forKey: .running)
        connectorCount = try? c.decodeIfPresent(Int.self, forKey: .connectorCount)
        edgeConnections = try? c.decodeIfPresent(Int.self, forKey: .edgeConnections)
        hostnames = try? c.decodeIfPresent([String].self, forKey: .hostnames)
        stableURLs = try? c.decodeIfPresent([String].self, forKey: .stableURLs)
        tempURL = try? c.decodeIfPresent(String.self, forKey: .tempURL)
        routes = try? c.decodeIfPresent([Route].self, forKey: .routes)
        connectors = try? c.decodeIfPresent([Connector].self, forKey: .connectors)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        stableURL = try? c.decodeIfPresent(String.self, forKey: .stableURL)

        iface = try? c.decodeIfPresent(String.self, forKey: .iface)
        timestamp = try? c.decodeIfPresent(Date.self, forKey: .timestamp)

        rxBytes = (try? c.decodeIfPresent(UInt64.self, forKey: .rxBytes))
            ?? (try? c.decodeIfPresent(UInt64.self, forKey: .rxBytesAlt1))
            ?? (try? c.decodeIfPresent(UInt64.self, forKey: .rxBytesAlt2))

        txBytes = (try? c.decodeIfPresent(UInt64.self, forKey: .txBytes))
            ?? (try? c.decodeIfPresent(UInt64.self, forKey: .txBytesAlt1))
            ?? (try? c.decodeIfPresent(UInt64.self, forKey: .txBytesAlt2))

        rxBps = (try? c.decodeIfPresent(UInt64.self, forKey: .rxBps))
            ?? (try? c.decodeIfPresent(UInt64.self, forKey: .rxBpsAlt1))

        txBps = (try? c.decodeIfPresent(UInt64.self, forKey: .txBps))
            ?? (try? c.decodeIfPresent(UInt64.self, forKey: .txBpsAlt1))
    }

    struct Connector: Decodable, Sendable {
        let id: String?
        let created: String?
        let arch: String?
        let version: String?
        let originIP: String?
        let edges: [Edge]?

        private enum CodingKeys: String, CodingKey {
            case id
            case created
            case arch
            case version
            case originIP = "origin_ip"
            case edges
        }
    }

    struct Edge: Decodable, Sendable {
        let id: String?
        let colo: String?
        let originIP: String?
        let openedAt: String?
        let isPendingReconnect: Bool?

        private enum CodingKeys: String, CodingKey {
            case id
            case colo
            case originIP = "origin_ip"
            case openedAt = "opened_at"
            case isPendingReconnect = "is_pending_reconnect"
        }
    }

    struct Route: Decodable, Sendable {
        let hostname: String?
        let tunnelID: String?
        let tunnelName: String?

        private enum CodingKeys: String, CodingKey {
            case hostname
            case tunnelID = "tunnel_id"
            case tunnelName = "tunnel_name"
        }
    }
}

public enum ByteFormat {
    public static func bytes(_ v: UInt64?) -> String {
        guard let v else { return "—" }
        let b = Double(v)
        let units = ["B", "KB", "MB", "GB", "TB"]
        var idx = 0
        var x = b
        while x >= 1024, idx < units.count - 1 {
            x /= 1024
            idx += 1
        }
        if idx == 0 { return "\(UInt64(x)) \(units[idx])" }
        return String(format: "%.2f %@", x, units[idx])
    }

    public static func bps(_ v: UInt64?) -> String {
        guard let v else { return "—" }
        return "\(bytes(v))/s"
    }
}

// MARK: - Small helpers

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
