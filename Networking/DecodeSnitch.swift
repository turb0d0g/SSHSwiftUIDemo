//
//  DecodeSnitch.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 12/30/25.
//


import Foundation
import OSLog

enum DecodeSnitch {
    static let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "DecodeSnitch")

    static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        decoder: JSONDecoder,
        label: String
    ) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch let err as DecodingError {
            let bodyHead = String(decoding: data.prefix(1400), as: UTF8.self)

            switch err {
            case .typeMismatch(let t, let ctx):
                log.error("[\(label, privacy: .public)] DecodingError.typeMismatch(\(String(describing: t), privacy: .public)) path=\(Self.path(ctx), privacy: .public) \(ctx.debugDescription, privacy: .public)\nRAW_HEAD:\n\(bodyHead, privacy: .public)")
            case .valueNotFound(let t, let ctx):
                log.error("[\(label, privacy: .public)] DecodingError.valueNotFound(\(String(describing: t), privacy: .public)) path=\(Self.path(ctx), privacy: .public) \(ctx.debugDescription, privacy: .public)\nRAW_HEAD:\n\(bodyHead, privacy: .public)")
            case .keyNotFound(let k, let ctx):
                log.error("[\(label, privacy: .public)] DecodingError.keyNotFound(\(k.stringValue, privacy: .public)) path=\(Self.path(ctx), privacy: .public) \(ctx.debugDescription, privacy: .public)\nRAW_HEAD:\n\(bodyHead, privacy: .public)")
            case .dataCorrupted(let ctx):
                log.error("[\(label, privacy: .public)] DecodingError.dataCorrupted path=\(Self.path(ctx), privacy: .public) \(ctx.debugDescription, privacy: .public)\nRAW_HEAD:\n\(bodyHead, privacy: .public)")
            @unknown default:
                log.error("[\(label, privacy: .public)] DecodingError unknown\nRAW_HEAD:\n\(bodyHead, privacy: .public)")
            }

            throw err
        } catch {
            let bodyHead = String(decoding: data.prefix(1400), as: UTF8.self)
            log.error("[\(label, privacy: .public)] Non-DecodingError: \(String(describing: error), privacy: .public)\nRAW_HEAD:\n\(bodyHead, privacy: .public)")
            throw error
        }
    }

    private static func path(_ ctx: DecodingError.Context) -> String {
        ctx.codingPath.map(\.stringValue).joined(separator: ".")
    }
}