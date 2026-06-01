//
//  FileManagerViewModel.swift
//  SSHSwiftUIDemo
//
//  Unified model driving RemoteFileManagerView.
//  Works with either a raw SFTP child Channel or your SFTPConnection actor.
//

import Foundation
import NIOCore
import NIOSSH
import OSLog

@MainActor
final class FileManagerViewModel: ObservableObject {
    // MARK: Published state
    @Published var currentPath: String = "/home/hairpi"
    @Published var entries: [SFTPName] = []
    @Published var errorMessage: String?
    @Published var isLoading: Bool = false

    // MARK: Private
    private let logger = Logger(subsystem: "com.SSHSwiftUIDemo", category: "FileManagerVM")
    private var sftpChannel: Channel?
    private var sftpConn: SFTPConnection?              // ✅ support your actor
    private var isRefreshing: Bool = false
    
    deinit {
        print("[DEINIT] \(String(describing: Self.self))")
    }

    // MARK: Wiring
    func attachSFTPChildChannel(_ channel: Channel) {
        self.sftpChannel = channel
        self.sftpConn = nil
        logger.info("[FileManagerVM] Attached SFTP child channel (isActive=\(channel.isActive, privacy: .public))")
    }

    func attach(connection: SFTPConnection) {
        self.sftpConn = connection
        self.sftpChannel = nil
        logger.info("[FileManagerVM] Attached SFTPConnection actor")
    }

    // Convenience: attach + first refresh
    func bind(channel: Channel? = nil, connection: SFTPConnection? = nil, initialPath: String? = nil) {
        if let initialPath { currentPath = initialPath }
        if let channel { attachSFTPChildChannel(channel) }
        if let connection { attach(connection: connection) }
        refresh()
    }

    // MARK: Actions
    func refresh() {
        if let ch = sftpChannel {
            refreshViaChannel(ch)
        } else if sftpConn != nil {
            refreshViaActor()
        } else {
            errorMessage = "SFTP not ready"
            logger.error("[FileManagerVM] refresh aborted: no SFTP backend attached")
        }
    }

    private func refreshViaChannel(_ ch: Channel) {
        guard ch.isActive else {
            errorMessage = "SFTP channel inactive"
            logger.error("[FileManagerVM] refresh aborted: channel is not active")
            return
        }
        guard !isRefreshing else {
            logger.debug("[FileManagerVM] refresh coalesced (already refreshing)")
            return
        }
        isRefreshing = true; isLoading = true; errorMessage = nil

        Task {
            do {
                logger.debug("[FileManagerVM] list(start) path='\(self.currentPath, privacy: .public)' [via Channel]")
                let client = SFTPClient(channel: ch)
                let list = try await client.list(path: currentPath)
                apply(list: list)
            } catch {
                record(error: error)
            }
            isLoading = false; isRefreshing = false
        }
    }

    private func refreshViaActor() {
        guard !isRefreshing else {
            logger.debug("[FileManagerVM] refresh coalesced (already refreshing)")
            return
        }
        guard let conn = sftpConn else { return }
        isRefreshing = true; isLoading = true; errorMessage = nil

        Task {
            do {
                logger.debug("[FileManagerVM] list(start) path='\(self.currentPath, privacy: .public)' [via SFTPConnection]")
                let list = try await conn.list(path: currentPath)
                apply(list: list)
            } catch {
                record(error: error)
            }
            isLoading = false; isRefreshing = false
        }
    }

    private func apply(list: [SFTPName]) {
        let filtered = list.filter { $0.filename != "." && $0.filename != ".." }
        let sorted = filtered.sorted { lhs, rhs in
            let ld = Self.isDirectory(longname: lhs.longname, filename: lhs.filename)
            let rd = Self.isDirectory(longname: rhs.longname, filename: rhs.filename)
            if ld != rd { return ld && !rd }
            return lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
        }
        self.entries = sorted
        logger.info("[FileManagerVM] list ok count=\(sorted.count, privacy: .public) path='\(self.currentPath, privacy: .public)'")
    }

    private func record(error: Error) {
        let msg = String(describing: error)
        self.errorMessage = msg
        self.logger.error("[FileManagerVM] list error path='\(self.currentPath, privacy: .public)' error='\(msg, privacy: .public)'")
    }

    func navigateInto(_ entry: SFTPName) {
        guard Self.isDirectory(longname: entry.longname, filename: entry.filename) else { return }
        let next = currentPath.hasSuffix("/") ? currentPath + entry.filename : currentPath + "/" + entry.filename
        logger.debug("[FileManagerVM] cd '\(self.currentPath, privacy: .public)' → '\(next, privacy: .public)'")
        currentPath = next
        refresh()
    }

    func goUp() {
        guard currentPath != "/" else { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        let next = parent.isEmpty ? "/" : parent
        logger.debug("[FileManagerVM] cd .. '\(self.currentPath, privacy: .public)' → '\(next, privacy: .public)'")
        currentPath = next
        refresh()
    }

    // MARK: Helpers
    static func isDirectory(longname: String, filename: String) -> Bool {
        guard let c = longname.first else { return false }
        return c == "d" || c == "l"
    }
}
