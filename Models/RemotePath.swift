//
//  RemotePath.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 10/28/25.
//


//
//  RemotePath.swift
//  SSHSwiftUIDemo
//

import Foundation

public struct RemotePath: Hashable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) {
        self.raw = RemotePath.normalize(raw)
    }

    public var description: String { raw }

    public var components: [String] {
        raw.split(separator: "/").map(String.init).prependedIfNeeded("/")
    }

    public var parent: RemotePath {
        guard raw != "/" else { return self }
        var comps = raw.split(separator: "/").map(String.init)
        _ = comps.popLast()
        if comps.isEmpty { return RemotePath("/") }
        return RemotePath("/" + comps.joined(separator: "/"))
    }

    public func appending(_ name: String) -> RemotePath {
        guard raw != "/" else { return RemotePath("/" + name) }
        return RemotePath(raw + "/" + name)
    }

    private static func normalize(_ s: String) -> String {
        var p = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { p = "/" }
        if !p.hasPrefix("/") { p = "/" + p }
        // collapse // and resolve '.' (keep .. naive)
        p = p.replacingOccurrences(of: "//", with: "/")
        let parts = p.split(separator: "/").map(String.init).filter { $0 != "." }
        return "/" + parts.joined(separator: "/")
    }
}

private extension Array where Element == String {
    func prependedIfNeeded(_ root: String) -> [String] {
        if isEmpty { return [root] }
        return [root] + self
    }
}
