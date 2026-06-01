//
//  JSONDecoders.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 12/30/25.
//


import Foundation
import OSLog

enum JSONDecoders {
    static let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "JSONDecoders")

    /// Handles:
    /// - 2025-12-30T18:15:06Z
    /// - 2025-12-20T06:14:43.540743Z  (microseconds)
    static func makeISO8601FlexibleDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)

            if let dt = ISO8601Flexible.parse(s) {
                return dt
            }

            log.error("Failed to parse ISO8601 date: \(s, privacy: .public)")
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid ISO8601 date: \(s)")
        }
        return d
    }
}

private enum ISO8601Flexible {
    private static let f0: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime] // no fractional
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private static let f1: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds] // fractional (1–9 digits)
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    static func parse(_ s: String) -> Date? {
        // Try fractional first (covers both fractional + non-fractional in practice)
        if let d = f1.date(from: s) { return d }
        if let d = f0.date(from: s) { return d }
        return nil
    }
}