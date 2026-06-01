//
//  FanStatus.swift
//  SSHSwiftUIDemo
//

import Foundation

struct FanStatus: Decodable, Equatable, Sendable {
    let ok: Bool
    let rpm: Int

    /// New fields you added
    let mode: Mode?

    /// Normalized to 0...100 for UI
    let dutyPercent: Double?

    let fanStalled: Bool?
    let health: Health?
    let lastEdgeAgeSec: Double?
    let timestamp: Date?

    // MARK: - Static helpers (avoid per-decode allocations)

    private nonisolated static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        // Be tolerant: allow fractional seconds when present.
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseISO8601(_ s: String) -> Date? {
        // Try fractional seconds first (most precise), then fallback to plain.
        if let d = iso8601.date(from: s) { return d }

        // Some scripts omit fractional seconds; try a second formatter config cheaply.
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }

    enum Mode: String, Decodable, CaseIterable, Sendable {
        case pid
        case auto
        case manual
        case unknown

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                self = Mode(rawValue: s.lowercased()) ?? .unknown
                return
            }
            _ = try? c.decode(Int.self) // tolerate numeric junk
            self = .unknown
        }
    }

    enum Health: String, Decodable, Sendable {
        case ok
        case stalled
        case noSignal = "no_signal"
        case unknown

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            let s = (try? c.decode(String.self))?.lowercased() ?? "unknown"
            self = Health(rawValue: s) ?? .unknown
        }
    }

    enum CodingKeys: String, CodingKey {
        case ok, rpm, mode, health, timestamp
        case duty                  // allow backend "duty"
        case dutyPercent = "duty_percent"
        case fanStalled = "fan_stalled"
        case lastEdgeAgeSec = "last_edge_age_sec"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        ok = (try? c.decode(Bool.self, forKey: .ok)) ?? false
        rpm = (try? c.decode(Int.self, forKey: .rpm)) ?? 0
        mode = try? c.decode(Mode.self, forKey: .mode)
        health = try? c.decode(Health.self, forKey: .health)
        fanStalled = try? c.decode(Bool.self, forKey: .fanStalled)
        lastEdgeAgeSec = try? c.decode(Double.self, forKey: .lastEdgeAgeSec)

        // timestamp tolerant:
        // - Prefer Date decoding (your shared JSONDecoder uses .iso8601)
        // - Fallback to string parse without allocating a formatter each time
        if let ts = try? c.decode(Date.self, forKey: .timestamp) {
            timestamp = ts
        } else if let s = try? c.decode(String.self, forKey: .timestamp) {
            timestamp = Self.parseISO8601(s)
        } else {
            timestamp = nil
        }

        // duty tolerant: accept Int or Double; accept 0..1 or 0..100; accept either key
        let dutyRaw: Double? = {
            if let d = try? c.decode(Double.self, forKey: .duty) { return d }
            if let i = try? c.decode(Int.self, forKey: .duty) { return Double(i) }
            if let d = try? c.decode(Double.self, forKey: .dutyPercent) { return d }
            if let i = try? c.decode(Int.self, forKey: .dutyPercent) { return Double(i) }
            return nil
        }()

        if let d = dutyRaw {
            if d <= 1.0 {
                dutyPercent = max(0, min(100, d * 100.0))
            } else {
                dutyPercent = max(0, min(100, d))
            }
        } else {
            dutyPercent = nil
        }
    }

    /// Safe debug string: never uses reflection.
    var dutyLogString: String {
        let dutyPct = dutyPercent.map { String(format: "%.1f", $0) } ?? "nil"
        return "dutyPercent=\(dutyPct)"
    }

    /// Preferred normalized duty for hardware calls.
    var dutyNormalizedInt: Int {
        let dutyDouble = dutyPercent ?? 0
        return max(0, min(100, Int(dutyDouble.rounded())))
    }

    var modeLogString: String {
        switch mode {
        case .some(let m): return String(describing: m)
        case .none: return "nil"
        }
    }
}
