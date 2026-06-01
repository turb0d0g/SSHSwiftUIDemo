//
//  LTECGI.swift
//  SSHSwiftUIDemo
//
//  Fully schema-tolerant client for Pi-side LTE + tunnel CGI scripts.
//  - Supports snake_case + legacy keys simultaneously
//  - Lossy decoding for Int/Double/Bool/String drift
//  - Emits drift diagnostics instead of silently returning nils
//
//  iOS 16+
//

import Foundation

// MARK: - Errors

enum LTECGIError: Error, LocalizedError {
    case badURL(String)
    case httpStatus(Int)
    case emptyBody
    case decode(String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let s):     return "Bad URL: \(s)"
        case .httpStatus(let c): return "HTTP \(c)"
        case .emptyBody:         return "Empty body"
        case .decode(let s):     return "Decode error: \(s)"
        case .other(let s):      return s
        }
    }
}

// MARK: - Lossy primitives (schema drift armor)

enum Lossy {
    struct BoolValue: Codable, Sendable {
        let value: Bool?

        init(_ v: Bool?) { self.value = v }

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()

            if c.decodeNil() { value = nil; return }

            if let b = try? c.decode(Bool.self) { value = b; return }

            // Some scripts return "true"/"false", "1"/"0", "yes"/"no"
            if let s = try? c.decode(String.self) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if ["true","1","yes","y","ok"].contains(t) { value = true; return }
                if ["false","0","no","n"].contains(t) { value = false; return }
                value = nil
                return
            }

            if let i = try? c.decode(Int.self) { value = (i != 0); return }

            value = nil
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(value)
        }
    }

    struct IntValue: Codable, Sendable {
        let value: Int?

        init(_ v: Int?) { self.value = v }

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { value = nil; return }

            if let i = try? c.decode(Int.self) { value = i; return }
            if let d = try? c.decode(Double.self) { value = Int(d); return }
            if let s = try? c.decode(String.self) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { value = nil; return }
                if let i = Int(t) { value = i; return }
                if let d = Double(t) { value = Int(d); return }
                value = nil
                return
            }
            value = nil
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(value)
        }
    }

    struct DoubleValue: Codable, Sendable {
        let value: Double?

        init(_ v: Double?) { self.value = v }

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { value = nil; return }

            if let d = try? c.decode(Double.self) { value = d; return }
            if let i = try? c.decode(Int.self) { value = Double(i); return }
            if let s = try? c.decode(String.self) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { value = nil; return }
                if let d = Double(t) { value = d; return }
                value = nil
                return
            }
            value = nil
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(value)
        }
    }

    struct StringValue: Codable, Sendable {
        let value: String?

        init(_ v: String?) { self.value = v }

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { value = nil; return }

            if let s = try? c.decode(String.self) { value = s; return }
            if let i = try? c.decode(Int.self) { value = String(i); return }
            if let d = try? c.decode(Double.self) { value = String(d); return }
            if let b = try? c.decode(Bool.self) { value = b ? "true" : "false"; return }

            value = nil
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(value)
        }
    }
}

// MARK: - Models (LTE)

public struct LTESignalMetrics: Codable, Sendable {
    public let rssi: Double?
    public let rsrp: Double?
    public let rsrq: Double?
    public let sinr: Double?
    public let ecio: Double?
    public let ber: Double?

    public let tech: String?
    public let band: String?
    public let earfcn: Int?
    public let cellID: String?

    private enum CodingKeys: String, CodingKey {
        case rssi, rsrp, rsrq, sinr, ecio, ber, tech, band, earfcn
        case cellID = "cell_id"
    }
}

/// `lte_connect.cgi` (tolerant superset)
public struct LTEConnectResponse: Codable, Sendable {
    public let ok: Bool?
    public let stage: String?
    public let iface: String?

    public let ip: String?
    public let ipv4: String?

    public let gw: String?
    public let ipv4Gateway: String?

    public let prefix: Int?
    public let ipv4Prefix: Int?

    public let dns0: String?
    public let dns1: String?
    public let apn: String?

    public let error: String?

    public var bestIP: String? { ip ?? ipv4 }
    public var bestGateway: String? { gw ?? ipv4Gateway }
    public var bestPrefix: Int? { prefix ?? ipv4Prefix }

    enum CodingKeys: String, CodingKey {
        case ok, stage, iface, ip, ipv4, gw, prefix, dns0, dns1, apn, error
        case ipv4Gateway = "ipv4_gateway"
        case ipv4Prefix  = "ipv4_prefix"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        ok = (try? c.decode(Lossy.BoolValue.self, forKey: .ok))?.value
        stage = (try? c.decode(Lossy.StringValue.self, forKey: .stage))?.value
        iface = (try? c.decode(Lossy.StringValue.self, forKey: .iface))?.value

        ip = (try? c.decode(Lossy.StringValue.self, forKey: .ip))?.value
        ipv4 = (try? c.decode(Lossy.StringValue.self, forKey: .ipv4))?.value

        gw = (try? c.decode(Lossy.StringValue.self, forKey: .gw))?.value
        ipv4Gateway = (try? c.decode(Lossy.StringValue.self, forKey: .ipv4Gateway))?.value

        prefix = (try? c.decode(Lossy.IntValue.self, forKey: .prefix))?.value
        ipv4Prefix = (try? c.decode(Lossy.IntValue.self, forKey: .ipv4Prefix))?.value

        dns0 = (try? c.decode(Lossy.StringValue.self, forKey: .dns0))?.value
        dns1 = (try? c.decode(Lossy.StringValue.self, forKey: .dns1))?.value
        apn  = (try? c.decode(Lossy.StringValue.self, forKey: .apn))?.value

        error = (try? c.decode(Lossy.StringValue.self, forKey: .error))?.value
    }
}

/// `lte_status.cgi`
/// - Some scripts return prefix as String, some as Int
/// - ok can be Bool or string
public struct LTEStatusResponse: Codable, Sendable {
    public let ok: Bool?
    public let error: String?

    public let stage: String?
    public let message: String?
    public let progressStage: String?
    public let progressPercent: Double?

    public let iface: String?
    public let operstate: String?
    public let apn: String?

    public let ipv4: String?
    public let prefix: String?
    public let gw: String?

    public let signal: LTESignalMetrics?

    private enum CodingKeys: String, CodingKey {
        case ok, error
        case stage, message
        case progressStage = "progress_stage"
        case progressPercent = "progress_percent"
        case iface, operstate, apn
        case ipv4, prefix, gw
        case signal
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        ok = (try? c.decode(Lossy.BoolValue.self, forKey: .ok))?.value
        error = (try? c.decode(Lossy.StringValue.self, forKey: .error))?.value

        stage = (try? c.decode(Lossy.StringValue.self, forKey: .stage))?.value
        message = (try? c.decode(Lossy.StringValue.self, forKey: .message))?.value
        progressStage = (try? c.decode(Lossy.StringValue.self, forKey: .progressStage))?.value
        progressPercent = (try? c.decode(Lossy.DoubleValue.self, forKey: .progressPercent))?.value

        iface = (try? c.decode(Lossy.StringValue.self, forKey: .iface))?.value
        operstate = (try? c.decode(Lossy.StringValue.self, forKey: .operstate))?.value
        apn = (try? c.decode(Lossy.StringValue.self, forKey: .apn))?.value

        ipv4 = (try? c.decode(Lossy.StringValue.self, forKey: .ipv4))?.value

        // prefix can be "24" or 24 or "255.255.255.0" depending on the day’s vibe
        if let s = (try? c.decode(Lossy.StringValue.self, forKey: .prefix))?.value {
            prefix = s
        } else if let i = (try? c.decode(Lossy.IntValue.self, forKey: .prefix))?.value {
            prefix = String(i)
        } else {
            prefix = nil
        }

        gw = (try? c.decode(Lossy.StringValue.self, forKey: .gw))?.value

        signal = try? c.decode(LTESignalMetrics.self, forKey: .signal)
    }

    /// Your app treats "ok" as session state
    public var sessionActive: Bool? { ok }

    public var bestIP: String? { ipv4 }
}

// MARK: - Models (Tunnel)

/// `tunnel_start.cgi` (tolerant superset)
public struct TunnelStartResponse: Codable, Sendable {
    public let ok: Bool?
    public let error: String?

    public let alreadyRunning: Bool?

    public let tunnelTempURL: String?
    public let tempURL: String?
    public let url: String?

    public let id: String?
    public let name: String?

    public let pid: Int?

    private enum CodingKeys: String, CodingKey {
        case ok, error, id, name, url, pid
        case alreadyRunning = "already_running"
        case tunnelTempURL = "tunnel_temp_url"
        case tempURL = "temp_url"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        ok = (try? c.decode(Lossy.BoolValue.self, forKey: .ok))?.value
        error = (try? c.decode(Lossy.StringValue.self, forKey: .error))?.value

        alreadyRunning = (try? c.decode(Lossy.BoolValue.self, forKey: .alreadyRunning))?.value

        tunnelTempURL = (try? c.decode(Lossy.StringValue.self, forKey: .tunnelTempURL))?.value
        tempURL = (try? c.decode(Lossy.StringValue.self, forKey: .tempURL))?.value
        url = (try? c.decode(Lossy.StringValue.self, forKey: .url))?.value

        id = (try? c.decode(Lossy.StringValue.self, forKey: .id))?.value
        name = (try? c.decode(Lossy.StringValue.self, forKey: .name))?.value

        pid = (try? c.decode(Lossy.IntValue.self, forKey: .pid))?.value
    }

    /// One canonical URL string to use in VMs
    public var bestTempURLString: String? {
        let candidates: [String?] = [tunnelTempURL, tempURL, url]
        for c in candidates {
            guard let s = c else { continue }
            let trimmed = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

// MARK: - Public API

enum LTECGI {

    // MARK: LTE connect

    static func connect(
        host: String,
        port: Int? = nil,
        timeout: TimeInterval = 15.0
    ) async throws -> LTEConnectResponse {

        let path = "/cgi-bin/lte_connect.cgi"
        let url = try makeURL(host: host, port: port, path: path)
        print("[LTECGI] connect → \(url.absoluteString)")

        let (data, resp) = try await data(for: url, timeout: timeout, tag: "lte_connect")
        try ensureHTTPOK(resp)
        try ensureBodyNotEmpty(data, tag: "lte_connect")

        do {
            let decoded = try tolerantDecoder().decode(LTEConnectResponse.self, from: data)
            driftReportConnect(decoded, body: data)
            print("[LTECGI] connect decoded: ok=\(decoded.ok.map(String.init) ?? "nil") stage=\(decoded.stage ?? "nil") iface=\(decoded.iface ?? "nil") ip=\(decoded.bestIP ?? "nil") gw=\(decoded.bestGateway ?? "nil") prefix=\(decoded.bestPrefix.map(String.init) ?? "nil")")
            return decoded
        } catch {
            let snippet = bodySnippet(data)
            print("[LTECGI] connect decode error: \(error)\n[LTECGI] body-snippet=\(snippet)")
            throw LTECGIError.decode("lte_connect: \(error.localizedDescription)")
        }
    }

    // MARK: LTE status

    static func status(
        host: String,
        port: Int? = nil,
        timeout: TimeInterval = 8.0
    ) async throws -> LTEStatusResponse {

        let path = "/cgi-bin/lte_status.cgi"
        let url = try makeURL(host: host, port: port, path: path)
        print("[LTECGI] status → \(url.absoluteString)")

        let (data, resp) = try await data(for: url, timeout: timeout, tag: "lte_status")
        try ensureHTTPOK(resp)
        try ensureBodyNotEmpty(data, tag: "lte_status")

        do {
            let decoded = try tolerantDecoder().decode(LTEStatusResponse.self, from: data)
            driftReportStatus(decoded, body: data)
            print("[LTECGI] status decoded: ok=\(decoded.ok.map(String.init) ?? "nil") sessionActive=\(decoded.sessionActive.map(String.init) ?? "nil") iface=\(decoded.iface ?? "nil") ip=\(decoded.bestIP ?? "nil") prefix=\(decoded.prefix ?? "nil") gw=\(decoded.gw ?? "nil")")
            return decoded
        } catch {
            let snippet = bodySnippet(data)
            print("[LTECGI] status decode error: \(error)\n[LTECGI] body-snippet=\(snippet)")
            throw LTECGIError.decode("lte_status: \(error.localizedDescription)")
        }
    }

    // MARK: Tunnel start

    static func startTunnel(
        host: String,
        port: Int? = nil,
        timeout: TimeInterval = 25.0
    ) async throws -> TunnelStartResponse {

        let path = "/cgi-bin/tunnel_start.cgi"
        let url = try makeURL(host: host, port: port, path: path)
        print("[LTECGI] startTunnel → \(url.absoluteString)")

        let (data, resp) = try await data(for: url, timeout: timeout, tag: "tunnel_start")
        try ensureHTTPOK(resp)
        try ensureBodyNotEmpty(data, tag: "tunnel_start")

        do {
            let decoded = try tolerantDecoder().decode(TunnelStartResponse.self, from: data)
            driftReportTunnelStart(decoded, body: data)
            print("[LTECGI] startTunnel decoded: ok=\(decoded.ok.map(String.init) ?? "nil") alreadyRunning=\(decoded.alreadyRunning.map(String.init) ?? "nil") url=\(decoded.bestTempURLString ?? decoded.url ?? "nil") pid=\(decoded.pid.map(String.init) ?? "nil")")
            return decoded
        } catch {
            let snippet = bodySnippet(data)
            print("[LTECGI] startTunnel decode error: \(error)\n[LTECGI] body-snippet=\(snippet)")
            throw LTECGIError.decode("tunnel_start: \(error.localizedDescription)")
        }
    }

    // MARK: - Internals

    private static func makeURL(host: String, port: Int?, path: String) throws -> URL {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host
        comps.port = port
        comps.path = path
        guard let url = comps.url else {
            throw LTECGIError.badURL("\(host):\(port ?? 80)\(path)")
        }
        return url
    }

    private static func data(for url: URL, timeout: TimeInterval, tag: String) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData

        print("[LTECGI] \(tag) request timeout=\(timeout)s")
        let (data, resp) = try await URLSession.shared.data(for: req)

        if let http = resp as? HTTPURLResponse {
            let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "unknown").lowercased()
            print("[LTECGI] \(tag) ← HTTP \(http.statusCode) content-type=\(ct) bytes=\(data.count)")
        } else {
            print("[LTECGI] \(tag) ← non-HTTP bytes=\(data.count) resp=\(resp)")
        }

        return (data, resp)
    }

    private static func ensureHTTPOK(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            print("[LTECGI] http status \(http.statusCode)")
            throw LTECGIError.httpStatus(http.statusCode)
        }
    }

    private static func ensureBodyNotEmpty(_ data: Data, tag: String) throws {
        guard !data.isEmpty else {
            print("[LTECGI] \(tag) → empty body")
            throw LTECGIError.emptyBody
        }
    }

    /// Decoder that *doesn't* rely on convertFromSnakeCase (we handle keys explicitly)
    private static func tolerantDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        // leave keyDecodingStrategy default; our CodingKeys are explicit.
        return d
    }

    private static func bodySnippet(_ data: Data, limit: Int = 500) -> String {
        let s = String(decoding: data.prefix(limit), as: UTF8.self)
        if s.isEmpty { return "<\(data.count) bytes (non-UTF8 or empty)>" }
        return s.replacingOccurrences(of: "\n", with: "\\n")
    }

    // MARK: - Drift reports (no more silent nils)

    private static func jsonTopKeys(_ data: Data) -> [String] {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data),
            let dict = obj as? [String: Any]
        else { return [] }
        return dict.keys.sorted()
    }

    private static func driftReportConnect(_ r: LTEConnectResponse, body: Data) {
        var missing: [String] = []
        if r.ok == nil { missing.append("ok") }
        if r.iface == nil { missing.append("iface") }
        if r.bestIP == nil { missing.append("ip/ipv4") }
        if r.bestGateway == nil { missing.append("gw/ipv4_gateway") }
        if r.bestPrefix == nil { missing.append("prefix/ipv4_prefix") }

        if !missing.isEmpty {
            print("[LTECGI][DRIFT][lte_connect] missing=\(missing) keys=\(jsonTopKeys(body))")
        }
    }

    private static func driftReportStatus(_ r: LTEStatusResponse, body: Data) {
        var missing: [String] = []
        if r.ok == nil { missing.append("ok") }
        if r.iface == nil { missing.append("iface") }
        if r.operstate == nil { missing.append("operstate") }
        if r.apn == nil { missing.append("apn") }
        if r.ipv4 == nil { missing.append("ipv4") }

        if !missing.isEmpty {
            print("[LTECGI][DRIFT][lte_status] missing=\(missing) keys=\(jsonTopKeys(body))")
        }
    }

    private static func driftReportTunnelStart(_ r: TunnelStartResponse, body: Data) {
        var missing: [String] = []
        if r.ok == nil { missing.append("ok") }
        if r.bestTempURLString == nil { missing.append("tunnel_temp_url/temp_url/url") }

        if !missing.isEmpty {
            print("[LTECGI][DRIFT][tunnel_start] missing=\(missing) keys=\(jsonTopKeys(body))")
        }
    }
}
