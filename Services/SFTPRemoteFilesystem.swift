//
//  SFTPRemoteFilesystem.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 10/29/25.
//


//
//  SFTPRemoteFilesystem.swift
//  SSHSwiftUIDemo
//

//
//  SFTPRemoteFilesystem.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 2025-10-29
//

import Foundation

/// Adapter that exposes SFTPConnection as a RemoteFilesystem.
/// It auto-connects on first use and maps POSIX mode bits to RemoteFileEntry.Kind.
public actor SFTPRemoteFilesystem: RemoteFilesystem {

    // MARK: Configuration

    public struct Config: Sendable {
        public let host: String
        public let port: Int
        public let username: String
        public let password: String
        public init(host: String, port: Int = 22, username: String, password: String) {
            self.host = host
            self.port = port
            self.username = username
            self.password = password
        }
    }

    private enum State { case idle, connecting, ready(SFTPConnection) }
    private var state: State = .idle
    private let config: Config

    public init(config: Config) {
        self.config = config
    }

    // MARK: - RemoteFilesystem Conformance

    public func listDirectory(at path: RemotePath) async throws -> (cwd: RemotePath, entries: [RemoteFileEntry]) {
        let conn = try await ensureConnected()
        let items = try await conn.list(path: path.raw)

        let mapped: [RemoteFileEntry] = items.map { item in
            let full = path.appending(item.filename).raw
            return RemoteFileEntry(
                name: item.filename,
                path: full,
                kind: kindFrom(permissions: item.attrs.permissions),
                size: item.attrs.size,
                modified: item.attrs.mtime.flatMap { Date(timeIntervalSince1970: TimeInterval($0)) },
                mode: item.attrs.permissions
            )
        }

        // Directories first, then files, then alpha order
        let sorted = mapped.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        return (cwd: path, entries: sorted)
    }

    public func createDirectory(at path: RemotePath, name: String) async throws {
        let conn = try await ensureConnected()
        try await conn.mkdir(path: path.appending(name).raw)
    }

    public func createFile(at path: RemotePath, name: String, utf8: String) async throws {
        let conn = try await ensureConnected()
        let data = Data(utf8.utf8)
        try await conn.upload(data: data, to: path.appending(name).raw)
    }

    public func delete(path: RemotePath) async throws {
        let conn = try await ensureConnected()
        // Try file removal first
        do {
            try await conn.remove(path: path.raw)
            return
        } catch {
            // Fallback: only allow removing empty directories (rmdir not yet implemented)
            let (_, list) = try await listDirectory(at: path)
            guard list.isEmpty else {
                throw NSError(domain: "SFTP", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Directory not empty: \(path.raw)"
                ])
            }
            throw NSError(domain: "SFTP", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Directory removal not supported by current SFTP client (needs rmdir)."
            ])
        }
    }

    public func rename(path: RemotePath, newName: String) async throws {
        let conn = try await ensureConnected()
        try await conn.rename(from: path.raw, to: path.parent.appending(newName).raw)
    }

    public func move(from: RemotePath, to: RemotePath) async throws {
        let conn = try await ensureConnected()
        try await conn.rename(from: from.raw, to: to.raw) // rename == move
    }

    public func copy(from: RemotePath, to: RemotePath) async throws {
        let conn = try await ensureConnected()
        let data = try await conn.download(path: from.raw, maxBytes: .max)
        try await conn.upload(data: data, to: to.raw)
    }

    public func download(path: RemotePath) async throws -> Data {
        let conn = try await ensureConnected()
        return try await conn.download(path: path.raw, maxBytes: .max)
    }

    /// Optional convenience used by some codepaths.
    public func upload(data: Data, to path: RemotePath) async throws {
        let conn = try await ensureConnected()
        try await conn.upload(data: data, to: path.raw)
    }

    /// Required by your RemoteFilesystem protocol: upload to directory with filename.
    public func upload(to path: RemotePath, filename: String, data: Data) async throws {
        let conn = try await ensureConnected()
        let fullPath = path.appending(filename).raw
        try await conn.upload(data: data, to: fullPath)
    }

    // MARK: - Connection management

    private func ensureConnected() async throws -> SFTPConnection {
        switch state {
        case .ready(let c):
            return c

        case .connecting:
            while true {
                if case .ready(let c) = state { return c }
                try await Task.sleep(nanoseconds: 50_000_000)
            }

        case .idle:
            state = .connecting
            let conn = SFTPConnection(config: .init(
                host: config.host,
                port: config.port,
                credentials: .init(username: config.username,
                                   password: config.password)
            ))
            try await conn.connect()
            state = .ready(conn)
            return conn
        }
    }

    // MARK: - Helpers

    private func kindFrom(permissions mode: UInt32?) -> RemoteFileEntry.Kind {
        guard let m = mode else { return .unknown }
        let S_IFMT:  UInt32 = 0o170000
        let S_IFSOCK:UInt32 = 0o140000
        let S_IFLNK: UInt32 = 0o120000
        let S_IFREG: UInt32 = 0o100000
        let S_IFBLK: UInt32 = 0o060000
        let S_IFDIR: UInt32 = 0o040000
        let S_IFCHR: UInt32 = 0o020000
        let S_IFIFO: UInt32 = 0o010000

        switch (m & S_IFMT) {
        case S_IFDIR:  return .directory
        case S_IFLNK:  return .symlink
        case S_IFSOCK: return .socket
        case S_IFBLK:  return .blockDevice
        case S_IFCHR:  return .charDevice
        case S_IFIFO:  return .fifo
        case S_IFREG:  return .file
        default:       return .unknown
        }
    }
}
