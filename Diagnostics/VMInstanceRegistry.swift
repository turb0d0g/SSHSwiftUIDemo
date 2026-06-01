//
//  VMInstanceRegistry.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 1/9/26.
//


//
//  VMInstanceRegistry.swift
//  SSHSwiftUIDemo
//
//  Live instance counter + IDs for ViewModels.
//  iOS 16+
//
//  Usage:
//    - In VM init:  self.vmToken = VMInstanceRegistry.shared.register(self, label: "optional")
//    - In deinit:   if let t = vmToken { VMInstanceRegistry.shared.unregister(t) }
//  Token does NOT retain the VM.
//

import Foundation
import OSLog

@MainActor
public final class VMInstanceRegistry: ObservableObject {
    public static let shared = VMInstanceRegistry()

    public struct Token: Hashable, Sendable {
        public let typeName: String
        public let instanceID: String
        public let createdAt: Date
        public let label: String

        public init(typeName: String, instanceID: String, createdAt: Date, label: String) {
            self.typeName = typeName
            self.instanceID = instanceID
            self.createdAt = createdAt
            self.label = label
        }
    }

    public struct SnapshotRow: Identifiable, Sendable {
        public let id: String              // "\(typeName)#\(instanceID)"
        public let typeName: String
        public let instanceID: String
        public let label: String
        public let ageSeconds: TimeInterval
    }

    private let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "VMRegistry")

    // typeName -> [instanceID -> Token]
    private var live: [String: [String: Token]] = [:]

    // Published flattened view for SwiftUI
    @Published public private(set) var rows: [SnapshotRow] = []
    @Published public private(set) var counts: [String: Int] = [:]
    @Published public var isOverlayEnabled: Bool = true

    private init() {}

    /// Register a VM instance and return a non-retaining token.
    @discardableResult
    public func register(_ object: AnyObject, label: String = "") -> Token {
        let typeName = String(reflecting: type(of: object))
        let instanceID = String(UUID().uuidString.prefix(6)).uppercased()
        let token = Token(typeName: typeName, instanceID: instanceID, createdAt: Date(), label: label)

        var bucket = live[typeName] ?? [:]
        bucket[instanceID] = token
        live[typeName] = bucket

        rebuildPublished()

        log.debug("[VMRegistry] + \(typeName, privacy: .public)#\(instanceID, privacy: .public) label=\(label, privacy: .public) count=\((self.counts[typeName] ?? 0), privacy: .public)")
        return token
    }

    public func unregister(_ token: Token) {
        guard var bucket = live[token.typeName] else { return }
        bucket[token.instanceID] = nil
        live[token.typeName] = bucket.isEmpty ? nil : bucket

        rebuildPublished()

        log.debug("[VMRegistry] - \(token.typeName, privacy: .public)#\(token.instanceID, privacy: .public) count=\((self.counts[token.typeName] ?? 0), privacy: .public)")
    }

    public func clearAll() {
        live.removeAll()
        rebuildPublished()
        log.info("[VMRegistry] cleared")
    }

    private func rebuildPublished() {
        // counts
        var newCounts: [String: Int] = [:]
        for (type, bucket) in live {
            newCounts[type] = bucket.count
        }
        counts = newCounts

        // rows
        let now = Date()
        var newRows: [SnapshotRow] = []
        for (type, bucket) in live {
            for (_, t) in bucket {
                newRows.append(
                    SnapshotRow(
                        id: "\(type)#\(t.instanceID)",
                        typeName: type,
                        instanceID: t.instanceID,
                        label: t.label,
                        ageSeconds: now.timeIntervalSince(t.createdAt)
                    )
                )
            }
        }

        // Stable-ish ordering: most “dangerous” VMs first, then by age desc
        newRows.sort {
            if $0.typeName != $1.typeName { return $0.typeName < $1.typeName }
            return $0.ageSeconds > $1.ageSeconds
        }

        rows = newRows
    }
}
