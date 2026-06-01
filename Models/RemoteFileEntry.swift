//
//  RemoteFileEntry.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 10/28/25.
//


//
//  RemoteFileEntry.swift
//  SSHSwiftUIDemo
//

import Foundation

public struct RemoteFileEntry: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable {
        case file, directory, symlink, socket, blockDevice, charDevice, fifo, unknown
    }

    public let id: String
    public let name: String
    public let path: String
    public let kind: Kind
    public let size: UInt64?
    public let modified: Date?
    public let mode: UInt32?

    public var isDirectory: Bool { kind == .directory }

    public init(name: String,
                path: String,
                kind: Kind,
                size: UInt64?,
                modified: Date?,
                mode: UInt32?) {
        self.id = path
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.mode = mode
    }

    public var formattedSize: String {
        guard let size else { return "—" }
        // Binary units
        let units = ["B","KB","MB","GB","TB"]
        var s = Double(size)
        var i = 0
        while s >= 1024 && i < units.count - 1 { s /= 1024; i += 1 }
        let f = i == 0 ? String(Int(s)) : String(format: "%.1f", s)
        return "\(f) \(units[i])"
    }
}
