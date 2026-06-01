//
//  RemoteFilesystem.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 10/28/25.
//


// RemoteFiles/Protocols/RemoteFilesystem.swift
import Foundation

/// Abstraction the VM depends on (SFTPFileAPI and CGI adapter conform).
public protocol RemoteFilesystem: Sendable {
    func listDirectory(at path: RemotePath) async throws -> (cwd: RemotePath, entries: [RemoteFileEntry])
    func createDirectory(at path: RemotePath, name: String) async throws
    func createFile(at path: RemotePath, name: String, utf8: String) async throws
    func delete(path: RemotePath) async throws
    func move(from: RemotePath, to: RemotePath) async throws
    func copy(from: RemotePath, to: RemotePath) async throws
    func rename(path: RemotePath, newName: String) async throws
    func download(path: RemotePath) async throws -> Data
    func upload(to path: RemotePath, filename: String, data: Data) async throws
}