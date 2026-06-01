//
//  NoctuaPollingActor.swift
//  SSHSwiftUIDemo
//

//
//  NoctuaPollingActor.swift
//  SSHSwiftUIDemo
//

import Foundation
import OSLog

public struct NoctuaSnapshot: Codable, Sendable, Equatable {
    public var rpm: Int
    public var temperatureC: Double
    public var voltageV: Double
    public var undervoltNow: Bool
    public var undervoltHistory: Bool
    public var mode: NoctuaMode              // ✅ Swift 6 Sendable-safe
    public var manualDuty: Int
    public var lastError: String?
    public var timestamp: Date

    public static var empty: NoctuaSnapshot {
        .init(
            rpm: 0,
            temperatureC: .nan,
            voltageV: .nan,
            undervoltNow: false,
            undervoltHistory: false,
            mode: .auto,
            manualDuty: 40,
            lastError: nil,
            timestamp: Date()
        )
    }
}

public actor NoctuaPollingActor {
    private let device: Device
    private let baseURL: URL

    private let fan: FanCGI
    private let volt: RPiVoltCGI

    private let http: PollingHTTPClient
    private let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "NoctuaPollingActor")

    private var pollTask: Task<Void, Never>?
    private var continuation: AsyncStream<NoctuaSnapshot>.Continuation?

    private var preferredTempURL: URL?
    private var snapshot: NoctuaSnapshot = .empty
    private var isRefreshing: Bool = false

    // Precompiled temp regexes
    private nonisolated static let tempRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?i)temp\s*[:=]\s*([-+]?\d+(?:\.\d+)?)\s*Â°?\s*([CF])"#),
        try! NSRegularExpression(pattern: #"(?i)([-+]?\d+(?:\.\d+)?)\s*Â°?\s*([CF])"#),
        try! NSRegularExpression(pattern: #"(?i)temp[^0-9-+]*([-+]?\d+(?:\.\d+)?)"#)
    ]

    init(device: Device) {
        self.device = device
        self.baseURL = Self.deriveBaseURL(from: device)
        self.fan = FanCGI(baseURL: baseURL)
        self.volt = RPiVoltCGI(baseURL: baseURL)
        self.http = PollingHTTPClient(category: "NoctuaPollingActor", config: .init(timeout: 3, cacheBuster: false))

        log.debug("[NoctuaActor] init device=\(device.name, privacy: .public) baseURL=\(self.baseURL.absoluteString, privacy: .public)")
    }

    deinit {
        log.debug("[NoctuaActor] deinit → stop()")
        pollTask?.cancel()
        pollTask = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Streaming / Polling

    public func start(interval: TimeInterval) -> AsyncStream<NoctuaSnapshot> {
        log.debug("[NoctuaActor] start(interval=\(interval, privacy: .public))")
        stop()

        let ns = UInt64(max(0.25, interval) * 1_000_000_000)

        return AsyncStream<NoctuaSnapshot> { cont in
            self.continuation = cont

            cont.onTermination = { @Sendable _ in
                Task { await self.stop() }
            }

            cont.yield(self.snapshot)

            self.pollTask = Task {
                self.log.debug("[NoctuaActor] pollTask started intervalNs=\(ns, privacy: .public)")

                while !Task.isCancelled {
                    let snap = await self.refreshOnce(source: "pollTick")
                    await self.emit(snap, source: "pollTick")
                    do { try await Task.sleep(nanoseconds: ns) } catch { break }
                }

                self.log.debug("[NoctuaActor] pollTask exiting cancelled=\(Task.isCancelled)")
            }
        }
    }

    public func stop() {
        log.debug("[NoctuaActor] stop()")
        pollTask?.cancel()
        pollTask = nil
        continuation?.finish()
        continuation = nil
    }

    private func emit(_ snap: NoctuaSnapshot, source: String) {
        snapshot = snap
        log.debug("[NoctuaActor] emit source=\(source, privacy: .public) rpm=\(snap.rpm) temp=\(snap.temperatureC, privacy: .public) V=\(snap.voltageV, privacy: .public) mode=\(snap.mode.rawValue, privacy: .public) duty=\(snap.manualDuty) err=\(snap.lastError ?? "nil", privacy: .public)")
        continuation?.yield(snap)
    }

    // MARK: - Intents

    public func refreshNow() async -> NoctuaSnapshot {
        let snap = await refreshOnce(source: "refreshNow")
        emit(snap, source: "refreshNow")
        return snap
    }

    public func setAuto() async -> NoctuaSnapshot {
        log.debug("[NoctuaActor] setAuto()")
        do {
            _ = try await fan.startAuto(curve: .balanced)
            try? await Task.sleep(nanoseconds: 150_000_000)
        } catch {
            log.error("[NoctuaActor] setAuto failed: \(String(describing: error), privacy: .public)")
            snapshot.lastError = normalize(error)
        }
        let snap = await refreshOnce(source: "setAuto")
        emit(snap, source: "setAuto")
        return snap
    }

    public func setManual(duty: Int) async -> NoctuaSnapshot {
        let clamped = max(0, min(100, duty))
        log.debug("[NoctuaActor] setManual(duty=\(clamped))")
        do {
            _ = try await fan.set(duty: clamped)
            try? await Task.sleep(nanoseconds: 200_000_000)
        } catch {
            log.error("[NoctuaActor] setManual failed: \(String(describing: error), privacy: .public)")
            snapshot.lastError = normalize(error)
        }
        let snap = await refreshOnce(source: "setManual")
        emit(snap, source: "setManual")
        return snap
    }

    public func stopFan() async -> NoctuaSnapshot {
        log.debug("[NoctuaActor] stopFan()")
        do {
            _ = try await fan.stopAuto()
            try? await Task.sleep(nanoseconds: 250_000_000)
        } catch {
            log.error("[NoctuaActor] stopFan failed: \(String(describing: error), privacy: .public)")
            snapshot.lastError = normalize(error)
        }
        let snap = await refreshOnce(source: "stopFan")
        emit(snap, source: "stopFan")
        return snap
    }

    // MARK: - Core probe

    private func refreshOnce(source: String) async -> NoctuaSnapshot {
        if isRefreshing {
            log.debug("[NoctuaActor] refreshOnce(\(source, privacy: .public)) skipped (already refreshing) → returning last snapshot")
            return snapshot
        }

        isRefreshing = true
        defer { isRefreshing = false }

        log.debug("[NoctuaActor] refreshOnce(\(source, privacy: .public)) start base=\(self.baseURL.absoluteString, privacy: .public)")

        var snap = snapshot
        snap.timestamp = Date()
        snap.lastError = nil

        do {
            // ✅ Swift 6: async-let + throws requires `try` at initializer
            async let statusTask = try fan.status()
            async let voltTask   = try volt.status()
            async let rpmTask    = try fetchFanRPM()

            let (s, v, r) = try await (statusTask, voltTask, rpmTask)

            snap.rpm = r
            snap.voltageV = v.coreVolts ?? .nan
            snap.undervoltNow = v.isUndervoltedNow
            snap.undervoltHistory = v.wasEverUndervolted

            if let tFromStatus = extractTempFromStatus(s) {
                snap.temperatureC = tFromStatus
            } else if let t = try await fetchTemperatureC() {
                snap.temperatureC = t
            }

            let dutyInt = max(0, min(100, Int((s.dutyPercent ?? 0).rounded())))

            switch s.mode {
            case .manual:
                snap.mode = .manual
                snap.manualDuty = dutyInt
            case .auto, .pid:
                snap.mode = .auto
            case .unknown, .none:
                snap.mode = .auto
            }

            log.debug("[NoctuaActor] ok mode=\(snap.mode.rawValue, privacy: .public) rpm=\(snap.rpm) temp=\(snap.temperatureC, privacy: .public) V=\(snap.voltageV, privacy: .public)")
            return snap
        } catch {
            let msg = normalize(error)
            snap.lastError = msg
            log.error("[NoctuaActor] refresh error: \(msg, privacy: .public)")
            return snap
        }
    }

    // MARK: - Temperature sources

    private func extractTempFromStatus(_ status: FanStatus) -> Double? {
        let candKeys = ["tempC","temperatureC","temp_c","cpu_temp_c","cpuTempC","gpu_temp_c","temp"]
        let m = Mirror(reflecting: status)
        for child in m.children {
            if let label = child.label, candKeys.contains(label) {
                if let d = child.value as? Double { return d }
                if let i = child.value as? Int { return Double(i) }
                if let s = child.value as? String, let d = Double(s) { return d }
            }
        }
        return nil
    }

    private func fetchTemperatureC() async throws -> Double? {
        if let cached = preferredTempURL {
            do {
                if let t = try await attemptTemperature(from: cached) {
                    log.debug("[NoctuaActor][temp] cached OK \(cached.path, privacy: .public) → \(t, privacy: .public)℃")
                    return t
                } else {
                    log.error("[NoctuaActor][temp] cached MISS \(cached.path, privacy: .public); clearing cache")
                    preferredTempURL = nil
                }
            } catch {
                log.error("[NoctuaActor][temp] cached FAIL \(cached.path, privacy: .public): \(String(describing: error), privacy: .public); clearing cache")
                preferredTempURL = nil
            }
        }

        let candidates: [URL] = [
            baseURL.appendingPathComponent("cgi-bin/monitoring_v12.py").appending(queryItems: [URLQueryItem(name: "only", value: "temp")]),
            baseURL.appendingPathComponent("cgi-bin/monitoring_v12.py").appending(queryItems: [URLQueryItem(name: "only", value: "cpu_temp_c")]),
            baseURL.appendingPathComponent("cgi-bin/get_temp.cgi"),
            baseURL.appendingPathComponent("metrics/temp"),
            baseURL.appendingPathComponent("cgi-bin/vcgencmd.cgi").appending(queryItems: [URLQueryItem(name: "cmd", value: "measure_temp")])
        ]

        for url in candidates {
            do {
                if let t = try await attemptTemperature(from: url) {
                    log.debug("[NoctuaActor][temp] OK \(url.path, privacy: .public) → \(t, privacy: .public)℃ (caching)")
                    preferredTempURL = url
                    return t
                } else {
                    log.error("[NoctuaActor][temp] MISS \(url.path, privacy: .public) (200 but unparsable)")
                }
            } catch {
                log.error("[NoctuaActor][temp] FAIL \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return nil
    }

    private func attemptTemperature(from url: URL) async throws -> Double? {
        let data = try await http.getData(url, endpoint: "temp")

        // Try JSON-ish first
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let keys = ["tempC","temperatureC","temp_c","cpu_temp_c","gpu_temp_c","cpuTempC","temp","CpuTemp","CpuTempC"]
            for k in keys {
                if let val = obj[k] {
                    if let d = val as? Double { return d }
                    if let i = val as? Int { return Double(i) }
                    if let s = val as? String, let d = Double(s) { return d }
                }
            }
        }

        // Text parse with precompiled regex
        let str = String(decoding: data, as: UTF8.self)
        return parseTempFromText(str)
    }

    private func parseTempFromText(_ s: String) -> Double? {
        let lower = s.lowercased()

        if let range = lower.range(of: "temp") {
            let start = lower.index(range.lowerBound, offsetBy: -20, limitedBy: lower.startIndex) ?? lower.startIndex
            let end = lower.index(range.upperBound, offsetBy: 20, limitedBy: lower.endIndex) ?? lower.endIndex
            let window = String(s[start..<end])
            if let d = parseAnyNumberWithUnits(window) { return d }
        }

        return parseAnyNumberWithUnits(s)
    }

    private func parseAnyNumberWithUnits(_ s: String) -> Double? {
        for rx in Self.tempRegexes {
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            if let m = rx.firstMatch(in: s, options: [], range: range) {
                guard m.numberOfRanges >= 2 else { continue }
                guard let nr = Range(m.range(at: 1), in: s) else { continue }
                guard let val = Double(String(s[nr])) else { continue }

                if m.numberOfRanges >= 3, let ur = Range(m.range(at: 2), in: s) {
                    let unit = String(s[ur]).uppercased()
                    if unit == "F" { return (val - 32.0) / 1.8 }
                }
                return val
            }
        }
        return nil
    }

    // MARK: - RPM Fetcher

    private struct FanRPMResponse: Decodable {
        let ok: Bool
        let rpm: Int
    }

    private func fetchFanRPM() async throws -> Int {
        let url = baseURL
            .appendingPathComponent("cgi-bin/get_fan_rpm.cgi")
            .appending(queryItems: [URLQueryItem(name: "only", value: "rpm")])

        let decoded: FanRPMResponse = try await http.getJSON(FanRPMResponse.self, url: url, endpoint: "get_fan_rpm(rpm)")
        guard decoded.ok else { throw RPMError.remote("ok=false rpm=\(decoded.rpm)") }
        return max(0, decoded.rpm)
    }

    private enum RPMError: LocalizedError {
        case remote(String)
        var errorDescription: String? {
            switch self {
            case .remote(let msg): return msg
            }
        }
    }

    // MARK: - BaseURL resolution

    private static func deriveBaseURL(from device: Device) -> URL {
        let dm = Mirror(reflecting: device)
        if let url = lookupURL(in: dm, keys: ["tunnelBaseURL", "httpBaseURL", "webBaseURL"]) { return url }
        if let host = lookupString(in: dm, keys: ["lteHost", "host"]),
           let httpPort = lookupInt(in: dm, keys: ["httpPort", "webPort", "hlsPort", "tunnelPort"]) {
            return URL(string: "http://\(host):\(httpPort)")!
        }
        if let lte = lookupString(in: dm, keys: ["lteHost"]), !lte.isEmpty { return URL(string: "http://\(lte)")! }
        if let host = lookupString(in: dm, keys: ["host"]), !host.isEmpty { return URL(string: "http://\(host)")! }
        return URL(string: "http://127.0.0.1")!
    }

    private static func lookupURL(in m: Mirror, keys: [String]) -> URL? {
        for k in keys { if let v = m.children.first(where: { $0.label == k })?.value as? URL { return v } }
        return nil
    }
    private static func lookupString(in m: Mirror, keys: [String]) -> String? {
        for k in keys { if let v = m.children.first(where: { $0.label == k })?.value as? String, !v.isEmpty { return v } }
        return nil
    }
    private static func lookupInt(in m: Mirror, keys: [String]) -> Int? {
        for k in keys { if let v = m.children.first(where: { $0.label == k })?.value as? Int { return v } }
        return nil
    }

    // MARK: - Errors

    private func normalize(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return String(describing: error)
    }
}

// MARK: - URL helper

private extension URL {
    func appending(queryItems: [URLQueryItem]) -> URL {
        guard var comps = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        comps.queryItems = (comps.queryItems ?? []) + queryItems
        return comps.url ?? self
    }
}
