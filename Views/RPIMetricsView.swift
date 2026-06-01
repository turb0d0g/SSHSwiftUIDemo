//
//  RPIMetricsView.swift
//  SSHSwiftUIDemo
//
//  Screenshot-style layout:
//  - Big panel cards (CPU, RAM, Storage per mount, Download, Upload)
//  - Center ring gauge + key/value rows
//  - JSON-first decode (metrics.cgi), fallback to legacy Key=Value text
//
//  iOS 16+
//

import SwiftUI

// MARK: - ViewModel

@MainActor
final class RPIMetricsViewModel: ObservableObject {

    // MARK: Published state
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?

    // CPU
    @Published var cpuUsagePct: Double?
    @Published var cpuTempC: Double?
    @Published var cpuFreqCurMHz: Double?
    @Published var cpuFreqMinMHz: Double?
    @Published var cpuFreqMaxMHz: Double?

    // RAM
    @Published var ramPercent: Double?
    @Published var ramTotalMB: Double?
    @Published var ramUsedMB: Double?
    @Published var ramFreeMB: Double?
    @Published var ramAvailMB: Double?

    // NET
    @Published var dlSpeed: (value: Double, unit: String)? // e.g. (0.24, "kB/s")
    @Published var ulSpeed: (value: Double, unit: String)?
    @Published var rxBytesMB: Double?
    @Published var txBytesMB: Double?
    @Published var rxPackets: Int?
    @Published var txPackets: Int?
    @Published var errIn: Int?
    @Published var errOut: Int?

    // FS mounts
    struct MountFS: Identifiable, Equatable {
        let id = UUID()
        let mountpoint: String
        let totalGB: Double?
        let usedGB: Double?
        let freeGB: Double?
        let percentUsed: Double?
    }
    @Published var mounts: [MountFS] = []

    // MARK: Polling
    private let monitorURL: URL
    private var pollTask: Task<Void, Never>?

    init(monitorURL: URL) {
        self.monitorURL = monitorURL
        print("[RPIMetricsVM] init url=\(monitorURL.absoluteString)")
    }

    deinit {
        print("[RPIMetricsVM] deinit -> cancel pollTask")
        pollTask?.cancel()
        pollTask = nil
    }

    func startPolling(interval: TimeInterval = 3.0) async {
        stopPolling()
        print("[RPIMetricsVM] startPolling interval=\(interval)s")
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshOnce()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        if pollTask != nil { print("[RPIMetricsVM] stopPolling -> cancel") }
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshOnce() async {
        isLoading = true
        defer { isLoading = false }

        do {
            print("[RPIMetricsVM] refreshOnce -> GET \(monitorURL.absoluteString)")
            var req = URLRequest(url: monitorURL)
            req.httpMethod = "GET"
            req.timeoutInterval = 8
            req.cachePolicy = .reloadIgnoringLocalCacheData

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            print("[RPIMetricsVM] HTTP \(http.statusCode) bytes=\(data.count)")
            guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            guard !data.isEmpty else { throw NSError(domain: "RPIMetrics", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty response"]) }

            // JSON-first
            if let decoded = try? JSONDecoder().decode(MetricsResponse.self, from: data) {
                print("[RPIMetricsVM] decoded JSON ok=\(decoded.ok) ts=\(decoded.timestamp ?? "nil")")
                apply(decoded)
                self.lastUpdated = Date()
                self.errorMessage = nil
                return
            }

            // Fallback: legacy text format (monitoring_v12.py style)
            let text = String(decoding: data, as: UTF8.self)
            print("[RPIMetricsVM] JSON decode failed -> fallback to text parse (len=\(text.count))")
            let legacy = Self.parseLegacyKeyValue(text)
            applyLegacy(legacy)
            self.lastUpdated = Date()
            self.errorMessage = nil

        } catch {
            print("[RPIMetricsVM] refresh error: \(error.localizedDescription)")
            self.errorMessage = error.localizedDescription
        }
    }

    // MARK: - JSON decode model (matches your metrics.cgi wrapper)

    private struct MetricsResponse: Decodable {
        let ok: Bool
        let timestamp: String?
        let metrics: MetricsBlock
    }

    private struct MetricsBlock: Decodable {
        let cpu: CPUBlock
        let ram_mb: RAMBlock
        let net: NetBlock
        let fs: [FSBlock]
    }

    private struct CPUBlock: Decodable {
        let temp: Double?
        let usage_pct: Double?
        let count: Int?
        let freq_mhz: CPUFreqBlock
    }

    private struct CPUFreqBlock: Decodable {
        let current: Double?
        let min: Double?
        let max: Double?
    }

    private struct RAMBlock: Decodable {
        let total: Double?
        let used: Double?
        let free: Double?
        let available: Double?
        let percent: Double?
    }

    private struct NetBlock: Decodable {
        let download_speed: Double?
        let upload_speed: Double?
        let download_speed_unit: String?
        let upload_speed_unit: String?
        let bytes_recv_mb: Double?
        let bytes_sent_mb: Double?
        let packets_recv: Int?
        let packets_sent: Int?
        let errors_in: Int?
        let errors_out: Int?
    }

    private struct FSBlock: Decodable {
        let mountpoint: String?
        let total_gb: Double?
        let used_gb: Double?
        let free_gb: Double?
        let percent: Double?
    }

    private func apply(_ r: MetricsResponse) {
        cpuUsagePct = r.metrics.cpu.usage_pct
        cpuTempC = r.metrics.cpu.temp
        cpuFreqCurMHz = r.metrics.cpu.freq_mhz.current
        cpuFreqMinMHz = r.metrics.cpu.freq_mhz.min
        cpuFreqMaxMHz = r.metrics.cpu.freq_mhz.max

        ramPercent = r.metrics.ram_mb.percent
        ramTotalMB = r.metrics.ram_mb.total
        ramUsedMB = r.metrics.ram_mb.used
        ramFreeMB = r.metrics.ram_mb.free
        ramAvailMB = r.metrics.ram_mb.available

        if let v = r.metrics.net.download_speed, let u = r.metrics.net.download_speed_unit {
            dlSpeed = (v, u)
        } else {
            dlSpeed = nil
        }
        if let v = r.metrics.net.upload_speed, let u = r.metrics.net.upload_speed_unit {
            ulSpeed = (v, u)
        } else {
            ulSpeed = nil
        }

        rxBytesMB = r.metrics.net.bytes_recv_mb
        txBytesMB = r.metrics.net.bytes_sent_mb
        rxPackets = r.metrics.net.packets_recv
        txPackets = r.metrics.net.packets_sent
        errIn = r.metrics.net.errors_in
        errOut = r.metrics.net.errors_out

        mounts = r.metrics.fs.compactMap { fs in
            guard let mp = fs.mountpoint else { return nil }
            return MountFS(
                mountpoint: mp,
                totalGB: fs.total_gb,
                usedGB: fs.used_gb,
                freeGB: fs.free_gb,
                percentUsed: fs.percent
            )
        }
    }

    // MARK: - Legacy Key=Value parsing (your monitoring_v12.py output)

    private struct LegacyKV {
        var map: [String: String] = [:]
        var fs: [(mount: String, total: String?, used: String?, free: String?, percent: String?)] = []
    }

    private static func parseLegacyKeyValue(_ text: String) -> LegacyKV {
        var out = LegacyKV()
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var i = 0
        var inFS = false

        var curMount: String?
        var curTotal: String?
        var curUsed: String?
        var curFree: String?
        var curPct: String?

        func flushFS() {
            if let m = curMount {
                out.fs.append((m, curTotal, curUsed, curFree, curPct))
            }
            curMount = nil; curTotal = nil; curUsed = nil; curFree = nil; curPct = nil
        }

        while i < lines.count {
            let line = lines[i]; i += 1
            if line.isEmpty { continue }

            if line == "FS = [" {
                inFS = true
                continue
            }

            if inFS {
                if line == "]" {
                    flushFS()
                    inFS = false
                    continue
                }
                if line == "," {
                    flushFS()
                    continue
                }
                if let eq = line.firstIndex(of: "=") {
                    let k = line[..<eq].trimmingCharacters(in: .whitespaces)
                    let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    let lk = k.lowercased()
                    if lk.contains("mountpoint") { curMount = v }
                    if lk.contains("disktotal") { curTotal = v }
                    if lk.contains("diskused") { curUsed = v }
                    if lk.contains("diskfree") { curFree = v }
                    if lk.contains("diskpercent") { curPct = v }
                }
                continue
            }

            if let eq = line.firstIndex(of: "=") {
                let k = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                let v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if !k.isEmpty { out.map[k] = v }
            }
        }

        return out
    }

    private func applyLegacy(_ kv: LegacyKV) {
        func num(_ s: String?) -> Double? {
            guard var t = s else { return nil }
            t = t.replacingOccurrences(of: "°C", with: "")
                .replacingOccurrences(of: "C", with: "")
                .replacingOccurrences(of: "MHz", with: "")
                .replacingOccurrences(of: "MB", with: "")
                .replacingOccurrences(of: "GB", with: "")
                .replacingOccurrences(of: "kB/s", with: "")
                .replacingOccurrences(of: "%", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Double(t)
        }
        func intv(_ s: String?) -> Int? {
            guard let s else { return nil }
            return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        cpuTempC = num(kv.map["CpuTemp"])
        cpuUsagePct = num(kv.map["CpuUsage"])
        cpuFreqCurMHz = num(kv.map["CpuFreqCurrent"])
        cpuFreqMinMHz = num(kv.map["CpuFreqMin"])
        cpuFreqMaxMHz = num(kv.map["CpuFreqMax"])

        ramTotalMB = num(kv.map["RamTotal"])
        ramUsedMB = num(kv.map["RamUsed"])
        ramFreeMB = num(kv.map["RamFree"])
        ramAvailMB = num(kv.map["RamAvailable"])
        ramPercent = num(kv.map["RamPercent"])

        if let v = num(kv.map["DownloadSpeed"]) {
            dlSpeed = (v, kv.map["DownloadSpeed"]?.contains("kB/s") == true ? "kB/s" : "kB/s")
        } else {
            dlSpeed = nil
        }
        if let v = num(kv.map["UploadSpeed"]) {
            ulSpeed = (v, kv.map["UploadSpeed"]?.contains("kB/s") == true ? "kB/s" : "kB/s")
        } else {
            ulSpeed = nil
        }

        rxBytesMB = num(kv.map["BytesRecv"])
        txBytesMB = num(kv.map["BytesSent"])
        rxPackets = intv(kv.map["PacketsRecv"])
        txPackets = intv(kv.map["PacketsSent"])
        errIn = intv(kv.map["NetErrorIn"])
        errOut = intv(kv.map["NetErrorOut"])

        mounts = kv.fs.map { fs in
            MountFS(
                mountpoint: fs.mount,
                totalGB: num(fs.total),
                usedGB: num(fs.used),
                freeGB: num(fs.free),
                percentUsed: num(fs.percent)
            )
        }
    }
}

// MARK: - View

struct RPIMetricsView: View {
    @EnvironmentObject private var devicesVM: DevicesViewModel

    let device: Device
    @StateObject private var vm: RPIMetricsViewModel

    init(device: Device) {
        self.device = device
        // Prefer JSON endpoint
        let url = URL(string: "http://\(device.host)/cgi-bin/metrics.cgi")
            ?? URL(string: "http://\(device.host)/cgi-bin/monitoring_v12.py")!
        _vm = StateObject(wrappedValue: RPIMetricsViewModel(monitorURL: url))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {

                headerCard

                if let err = vm.errorMessage {
                    errorCard(err)
                }

                cpuCard
                ramCard
                storageCards

                downloadCard
                uploadCard

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("CPU, RAM, Storage and Network…")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await vm.refreshOnce() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(vm.isLoading)
            }
        }
        .refreshable {
            await vm.refreshOnce()
        }
        .task(id: device.id) {
            devicesVM.requestRefresh(.single(device), reason: "RPIMetricsView.onAppear")
            await vm.startPolling(interval: 3.0)
        }
        .onDisappear {
            vm.stopPolling()
        }
    }

    // MARK: Header

    private var headerCard: some View {
        PanelCard {
            HStack(spacing: 10) {
                Image(systemName: "caravan.fill")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name.isEmpty ? device.host : device.name)
                        .font(.headline)
                        .lineLimit(1)

                    if let last = vm.lastUpdated {
                        Text("Updated \(last.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(vm.isLoading ? "Loading…" : "—")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if vm.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    private func errorCard(_ msg: String) -> some View {
        PanelCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connection Error")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    // MARK: CPU

    private var cpuCard: some View {
        PanelCard {
            VStack(spacing: 12) {
                RingGauge(
                    title: "CPU",
                    valueText: percentString(vm.cpuUsagePct),
                    fraction: fractionPercent(vm.cpuUsagePct),
                    subtitle: "%"
                )

                Divider().opacity(0.25)

                KVRow("Current frequency:", value: mhz(vm.cpuFreqCurMHz))
                KVRow("Minimum frequency:", value: mhz(vm.cpuFreqMinMHz))
                KVRow("Maximum frequency:", value: mhz(vm.cpuFreqMaxMHz))
                KVRow("Temperature:", value: temp(vm.cpuTempC))
            }
        }
    }

    // MARK: RAM

    private var ramCard: some View {
        PanelCard {
            VStack(spacing: 12) {
                RingGauge(
                    title: "RAM",
                    valueText: percentString(vm.ramPercent),
                    fraction: fractionPercent(vm.ramPercent),
                    subtitle: "%"
                )

                Divider().opacity(0.25)

                KVRow("Total:", value: mb(vm.ramTotalMB))
                KVRow("Used:", value: mb(vm.ramUsedMB))
                KVRow("Free:", value: mb(vm.ramFreeMB))
                KVRow("Available:", value: mb(vm.ramAvailMB))
            }
        }
    }

    // MARK: Storage

    private var storageCards: some View {
        VStack(spacing: 14) {
            ForEach(vm.mounts) { m in
                PanelCard {
                    VStack(spacing: 12) {
                        Text("STORAGE")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .padding(.top, 2)

                        Divider().opacity(0.25)

                        KVRow("Mountpoint:", value: m.mountpoint)

                        KVRow("Total:", value: gb(m.totalGB))
                        KVRow("Used:", value: gb(m.usedGB))
                        KVRow("Free:", value: gb(m.freeGB))

                        if let p = m.percentUsed {
                            // Optional ring shown below the rows (you can move it above if you want)
                            Divider().opacity(0.25)
                            RingGauge(
                                title: "",
                                valueText: String(format: "%.1f", p),
                                fraction: min(max(p / 100.0, 0), 1),
                                subtitle: "%"
                            )
                            .opacity(0.9)
                        }
                    }
                }
            }
        }
    }

    // MARK: Download / Upload

    private var downloadCard: some View {
        PanelCard {
            VStack(spacing: 12) {
                let speed = vm.dlSpeed?.value
                let unit = vm.dlSpeed?.unit ?? "kB/s"
                RingGauge(
                    title: "DOWNLOAD",
                    valueText: speedString(speed),
                    fraction: fractionSpeed(speed),
                    subtitle: unit
                )

                Divider().opacity(0.25)

                KVRow("Speed:", value: speedLine(vm.dlSpeed))
                KVRow("RX Bytes:", value: mb(vm.rxBytesMB))
                KVRow("RX Packets:", value: vm.rxPackets.map(String.init) ?? "—")
                KVRow("Incoming errors:", value: vm.errIn.map(String.init) ?? "—")
            }
        }
    }

    private var uploadCard: some View {
        PanelCard {
            VStack(spacing: 12) {
                let speed = vm.ulSpeed?.value
                let unit = vm.ulSpeed?.unit ?? "kB/s"
                RingGauge(
                    title: "UPLOAD",
                    valueText: speedString(speed),
                    fraction: fractionSpeed(speed),
                    subtitle: unit
                )

                Divider().opacity(0.25)

                KVRow("Speed:", value: speedLine(vm.ulSpeed))
                KVRow("TX Bytes:", value: mb(vm.txBytesMB))
                KVRow("TX Packets:", value: vm.txPackets.map(String.init) ?? "—")
                KVRow("Outgoing errors:", value: vm.errOut.map(String.init) ?? "—")
            }
        }
    }

    // MARK: Formatting helpers

    private func mhz(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.0f MHz", v)
    }

    private func temp(_ c: Double?) -> String {
        guard let c else { return "—" }
        return String(format: "%.1f °C", c)
    }

    private func mb(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.2f MB", v)
    }

    private func gb(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.2f GB", v)
    }

    private func percentString(_ p: Double?) -> String {
        guard let p else { return "—" }
        return String(format: "%.1f", p)
    }

    private func fractionPercent(_ p: Double?) -> Double {
        guard let p else { return 0 }
        return min(max(p / 100.0, 0), 1)
    }

    private func speedString(_ v: Double?) -> String {
        guard let v else { return "—" }
        // Screenshot shows one decimal-ish; we’ll do 1 decimal when < 10, else 0 decimals.
        if v < 10 { return String(format: "%.1f", v) }
        return String(format: "%.0f", v)
    }

    private func speedLine(_ s: (value: Double, unit: String)?) -> String {
        guard let s else { return "—" }
        return "\(speedString(s.value)) \(s.unit)"
    }

    private func fractionSpeed(_ v: Double?) -> Double {
        guard let v else { return 0 }
        // Dynamic max so the ring isn’t always pegged at 0.
        // Clamp: max at least 1, and keep headroom so it looks alive.
        let maxVal = max(1.0, v * 4.0, 10.0)
        return min(max(v / maxVal, 0), 1)
    }
}

// MARK: - UI Components (panel style)

private struct PanelCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
    }
}

private struct KVRow: View {
    let key: String
    let value: String

    init(_ key: String, value: String) {
        self.key = key
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .foregroundStyle(.blue)
                .font(.body)
            Spacer()
            Text(value)
                .foregroundStyle(.primary)
                .font(.body.monospacedDigit())
        }
    }
}

private struct RingGauge: View {
    let title: String
    let valueText: String
    let fraction: Double   // 0...1
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Gauge(value: fraction, in: 0...1) {
                EmptyView()
            } currentValueLabel: {
                VStack(spacing: 2) {
                    Text(valueText)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .frame(width: 120, height: 120)

            if !title.isEmpty {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
