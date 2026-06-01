//
//  ARCTracker.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 12/30/25.
//


//
//  ARCTracker.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 12/30/25.
//
//  ARC lifecycle tracker (init/register + deinit/unregister) with leak-suspect scanning.
//  Adds "pinned" (expected-alive) objects to avoid false positives.
//  iOS 16+
//
//  Updated: 2026-01-12
//

import Foundation
import OSLog

public actor ARCTracker {
    public static let shared = ARCTracker()

    // MARK: - Types

    public enum ExpectedLifetime: Sendable, Equatable {
        case transient
        case appLifetime
    }

    /// Non-retaining registration token.
    /// Store this in your VM and call `unregister(token)` in deinit.
    public struct Token: Sendable, Hashable {
        public let oidRaw: UInt
        public let id: String
        public let typeName: String
        public init(oid: ObjectIdentifier, id: String, typeName: String) {
            self.oidRaw = oid.hashValue.magnitude
            self.id = id
            self.typeName = typeName
        }
    }

    public struct Suspect: Sendable, Identifiable {
        public let id: String
        public let typeName: String
        public let createdAt: Date
        public let ageSeconds: TimeInterval
        public let note: String
        public let creationStack: [String]
    }

    private struct Entry {
        weak var object: AnyObject?
        let id: String
        let typeName: String
        let createdAt: Date
        let creationStack: [String]
        let note: String
        let expectedLifetime: ExpectedLifetime
        let oidHashMagnitude: UInt
    }

    // MARK: - Logging / State

    private let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "ARCTracker")

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var leakWatchTask: Task<Void, Never>?

    private var lastPinnedCount: Int = 0
    private var lastPinnedTypesFingerprint: String = ""

    private init() {}

    // MARK: - Register / Unregister

    /// Registers an object and returns a non-retaining token. Prefer this API.
    @discardableResult
    public func registerToken(
        _ object: AnyObject,
        note: String = "",
        expectedLifetime: ExpectedLifetime = .transient,
        stack: [String] = Thread.callStackSymbols
    ) -> Token {
        let oid = ObjectIdentifier(object)
        let id = UUID().uuidString
        let typeName = String(reflecting: type(of: object))

        let entry = Entry(
            object: object,
            id: id,
            typeName: typeName,
            createdAt: Date(),
            creationStack: stack,
            note: note,
            expectedLifetime: expectedLifetime,
            oidHashMagnitude: oid.hashValue.magnitude
        )

        entries[oid] = entry

        log.debug("[ARC] register \(entry.typeName, privacy: .public) id=\(id, privacy: .public) lifetime=\(String(describing: expectedLifetime), privacy: .public) note=\(note, privacy: .public)")
        return Token(oid: oid, id: id, typeName: typeName)
    }

    /// Back-compat: registers and returns id string only.
    @discardableResult
    public func register(
        _ object: AnyObject,
        note: String = "",
        expectedLifetime: ExpectedLifetime = .transient,
        stack: [String] = Thread.callStackSymbols
    ) -> String {
        registerToken(object, note: note, expectedLifetime: expectedLifetime, stack: stack).id
    }

    /// Unregister by object instance (requires a reference). Fine, but deinit shouldn’t need it.
    public func unregister(_ object: AnyObject) {
        let oid = ObjectIdentifier(object)
        if let entry = entries.removeValue(forKey: oid) {
            log.debug("[ARC] unregister \(entry.typeName, privacy: .public) id=\(entry.id, privacy: .public)")
        }
    }

    /// ✅ Unregister by token. This avoids capturing the object in a deinit closure.
    public func unregister(token: Token) {
        // Find entry by oidHashMagnitude + id (safer than hash alone).
        let match = entries.first { (_, e) in
            e.oidHashMagnitude == token.oidRaw && e.id == token.id
        }
        if let (oid, entry) = match {
            entries.removeValue(forKey: oid)
            log.debug("[ARC] unregister(token) \(entry.typeName, privacy: .public) id=\(entry.id, privacy: .public)")
        } else {
            log.debug("[ARC] unregister(token) miss type=\(token.typeName, privacy: .public) id=\(token.id, privacy: .public)")
        }
    }

    /// ✅ Convenience overload (no label).
    public func unregister(_ token: Token) {
        unregister(token: token)
    }

    /// ✅ Unregister by ObjectIdentifier hash magnitude + id (exact-match without needing Token type).
    public func unregister(oidHashMagnitude: UInt, id: String) {
        let match = entries.first { (_, e) in
            e.oidHashMagnitude == oidHashMagnitude && e.id == id
        }
        if let (oid, entry) = match {
            entries.removeValue(forKey: oid)
            log.debug("[ARC] unregister(oidHash+id) \(entry.typeName, privacy: .public) id=\(entry.id, privacy: .public)")
        } else {
            log.debug("[ARC] unregister(oidHash+id) miss oidHash=\(oidHashMagnitude, privacy: .public) id=\(id, privacy: .public)")
        }
    }

    /// ✅ Unregister by ObjectIdentifier hash magnitude only (last resort).
    public func unregister(oidHashMagnitude: UInt) {
        let match = entries.first { (_, e) in e.oidHashMagnitude == oidHashMagnitude }
        if let (oid, entry) = match {
            entries.removeValue(forKey: oid)
            log.debug("[ARC] unregister(oidHash) \(entry.typeName, privacy: .public) id=\(entry.id, privacy: .public)")
        }
    }

    // MARK: - Pin / Unpin convenience

    public func pin(
        _ object: AnyObject,
        note: String = "",
        stack: [String] = Thread.callStackSymbols
    ) {
        let oid = ObjectIdentifier(object)

        if let existing = entries[oid] {
            entries[oid] = Entry(
                object: existing.object,
                id: existing.id,
                typeName: existing.typeName,
                createdAt: existing.createdAt,
                creationStack: existing.creationStack,
                note: note.isEmpty ? existing.note : note,
                expectedLifetime: .appLifetime,
                oidHashMagnitude: existing.oidHashMagnitude
            )
            log.info("[ARC] pin existing \(existing.typeName, privacy: .public) id=\(existing.id, privacy: .public)")
        } else {
            _ = registerToken(object, note: note, expectedLifetime: .appLifetime, stack: stack)
            log.info("[ARC] pin new \(String(reflecting: type(of: object)), privacy: .public)")
        }
    }

    public func unpin(_ object: AnyObject) {
        let oid = ObjectIdentifier(object)
        guard let existing = entries[oid] else { return }

        entries[oid] = Entry(
            object: existing.object,
            id: existing.id,
            typeName: existing.typeName,
            createdAt: existing.createdAt,
            creationStack: existing.creationStack,
            note: existing.note,
            expectedLifetime: .transient,
            oidHashMagnitude: existing.oidHashMagnitude
        )

        log.info("[ARC] unpin \(existing.typeName, privacy: .public) id=\(existing.id, privacy: .public)")
    }

    // MARK: - Leak Watch

    public func startLeakWatch(
        intervalSeconds: TimeInterval = 2,
        suspectAfterSeconds: TimeInterval = 8,
        warnOnPinnedGrowth: Bool = true
    ) {
        guard leakWatchTask == nil else {
            log.info("[ARC] leak watch already running; ignoring start")
            return
        }

        leakWatchTask = Task { [intervalSeconds, suspectAfterSeconds, warnOnPinnedGrowth] in
            log.info("[ARC] leak watch started interval=\(intervalSeconds, privacy: .public)s suspectAfter=\(suspectAfterSeconds, privacy: .public)s pinnedGrowthWarn=\(warnOnPinnedGrowth, privacy: .public)")

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
                await self.scan(suspectAfterSeconds: suspectAfterSeconds, warnOnPinnedGrowth: warnOnPinnedGrowth)
            }

            log.info("[ARC] leak watch ended (cancelled=\(Task.isCancelled, privacy: .public))")
        }
    }

    public func stopLeakWatch() {
        leakWatchTask?.cancel()
        leakWatchTask = nil
        log.info("[ARC] leak watch stopped")
    }

    // MARK: - Query

    public func currentSuspects(suspectAfterSeconds: TimeInterval) -> [Suspect] {
        let now = Date()

        // prune dead
        entries = entries.filter { $0.value.object != nil }

        var out: [Suspect] = []
        for (_, e) in entries {
            guard e.object != nil else { continue }
            guard e.expectedLifetime == .transient else { continue }

            let age = now.timeIntervalSince(e.createdAt)
            if age >= suspectAfterSeconds {
                out.append(Suspect(
                    id: e.id,
                    typeName: e.typeName,
                    createdAt: e.createdAt,
                    ageSeconds: age,
                    note: e.note,
                    creationStack: e.creationStack
                ))
            }
        }

        return out.sorted { $0.ageSeconds > $1.ageSeconds }
    }

    // MARK: - Scan

    private func scan(suspectAfterSeconds: TimeInterval, warnOnPinnedGrowth: Bool) async {
        // prune dead
        entries = entries.filter { $0.value.object != nil }

        if warnOnPinnedGrowth {
            let pinned = entries.values.filter { $0.object != nil && $0.expectedLifetime == .appLifetime }
            let pinnedCount = pinned.count

            let typeList = pinned.map { $0.typeName }.sorted()
            let fingerprint = typeList.joined(separator: "|")

            if pinnedCount > lastPinnedCount && fingerprint != lastPinnedTypesFingerprint {
                log.error("[ARC] ⚠️ pinned grew: \(self.lastPinnedCount, privacy: .public) -> \(pinnedCount, privacy: .public)")
                log.error("[ARC] pinned types: \(typeList.joined(separator: ", "), privacy: .public)")
            }

            lastPinnedCount = pinnedCount
            lastPinnedTypesFingerprint = fingerprint
        }

        let suspects = currentSuspects(suspectAfterSeconds: suspectAfterSeconds)
        guard !suspects.isEmpty else { return }

        log.error("[ARC] ⚠️ suspects=\(suspects.count, privacy: .public)")
        for s in suspects.prefix(5) {
            log.error("[ARC] suspect \(s.typeName, privacy: .public) age=\(s.ageSeconds, privacy: .public)s note=\(s.note, privacy: .public)")
            let top = s.creationStack.prefix(8).joined(separator: "\n")
            log.error("[ARC] creation stack (top):\n\(top, privacy: .public)")
        }
    }
}

// MARK: - Listing

public extension ARCTracker {

    enum ListFilter: Sendable, Equatable {
        case suspects(suspectAfterSeconds: TimeInterval)
        case pinned
        case all(includePinned: Bool = true)
        case transientAll
    }

    struct Tracked: Sendable, Identifiable {
        public let id: String
        public let typeName: String
        public let createdAt: Date
        public let ageSeconds: TimeInterval
        public let note: String
        public let expectedLifetime: ExpectedLifetime
        public let creationStack: [String]
    }

    func currentTracked(_ filter: ListFilter) -> [Tracked] {
        let now = Date()
        entries = entries.filter { $0.value.object != nil }

        func toTracked(_ e: Entry) -> Tracked {
            Tracked(
                id: e.id,
                typeName: e.typeName,
                createdAt: e.createdAt,
                ageSeconds: now.timeIntervalSince(e.createdAt),
                note: e.note,
                expectedLifetime: e.expectedLifetime,
                creationStack: e.creationStack
            )
        }

        switch filter {
        case .suspects(let suspectAfterSeconds):
            return currentSuspects(suspectAfterSeconds: suspectAfterSeconds).map {
                Tracked(
                    id: $0.id,
                    typeName: $0.typeName,
                    createdAt: $0.createdAt,
                    ageSeconds: $0.ageSeconds,
                    note: $0.note,
                    expectedLifetime: .transient,
                    creationStack: $0.creationStack
                )
            }

        case .pinned:
            return entries.values
                .filter { $0.object != nil && $0.expectedLifetime == .appLifetime }
                .map(toTracked)
                .sorted { $0.ageSeconds > $1.ageSeconds }

        case .transientAll:
            return entries.values
                .filter { $0.object != nil && $0.expectedLifetime == .transient }
                .map(toTracked)
                .sorted { $0.ageSeconds > $1.ageSeconds }

        case .all(let includePinned):
            return entries.values
                .filter { $0.object != nil && (includePinned || $0.expectedLifetime == .transient) }
                .map(toTracked)
                .sorted { $0.ageSeconds > $1.ageSeconds }
        }
    }
}
