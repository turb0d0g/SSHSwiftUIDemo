//
//  RemoteFileAPI.swift
//  SSHSwiftUIDemo
//
//  Unified high-level remote file utilities shared by multiple backends
//  (CGI-based HTTP adapters, SFTPRemoteFilesystem, etc.).
//
//  Created by Jesse Herring on 2025-10-29
//

import Foundation
import OSLog

/// A general façade for listing, creating, deleting, renaming, copying, and transferring
/// remote files over a variety of protocols (SFTP, CGI, HTTP JSON).
///
/// The API normalizes each backend’s response into `[RemoteFileEntry]` models used by
/// `RemoteFileManagerViewModel`.
public actor RemoteFileAPI {

    // MARK: - Types

    public enum APIError: Error, LocalizedError {
        case unsupported
        case notConnected
        case httpError(Int)
        case decodeError(String)
        case invalidResponse
        case unknown(String)

        public var errorDescription: String? {
            switch self {
            case .unsupported:        return "Operation not supported by this backend"
            case .notConnected:       return "Remote service not connected"
            case .httpError(let c):   return "HTTP error \(c)"
            case .decodeError(let m): return "Decode error: \(m)"
            case .invalidResponse:    return "Invalid response from remote API"
            case .unknown(let m):     return m
            }
        }
    }

    private let log = Logger(subsystem: "SSHSwiftUIDemo", category: "RemoteFileAPI")

    // MARK: - Public Entry Points

    /// Parse a JSON-style directory listing (array of dicts) into model objects.
    public func parseListingResponse(_ json: Any, cwd: String) throws -> (RemotePath, [RemoteFileEntry]) {
        guard let array = json as? [[String: Any]] else {
            throw APIError.decodeError("Expected array of dictionaries")
        }

        let cwdPath = RemotePath(cwd)
        var entries: [RemoteFileEntry] = []

        for obj in array {
            guard let name = obj["name"] as? String else { continue }
            let fullPath = cwdPath.appending(name).raw

            let kind: RemoteFileEntry.Kind
            if let type = obj["type"] as? String {
                switch type.lowercased() {
                case "dir", "directory": kind = .directory
                case "file":             kind = .file
                case "link", "symlink":  kind = .symlink
                default:                 kind = .unknown
                }
            } else { kind = .unknown }

            let size  = (obj["size"] as? NSNumber)?.uint64Value
            let perms = (obj["mode"] as? NSNumber)?.uint32Value

            // ✅ FIXED: direct conversion to Date if mtime is present
            let mtime = (obj["mtime"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue)
            }

            let entry = RemoteFileEntry(
                name: name,
                path: fullPath,
                kind: kind,
                size: size,
                modified: mtime,
                mode: perms
            )
            entries.append(entry)
        }

        // Sort: directories first, then files alphabetically
        entries.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        return (cwdPath, entries)
    }

    /// Convenience: construct entries from a legacy dictionary list used by CGI endpoints.
    public func parseLegacyCGIListing(_ list: [[String: Any]], cwd: String) -> (RemotePath, [RemoteFileEntry]) {
        let cwdPath = RemotePath(cwd)
        var out: [RemoteFileEntry] = []

        for dict in list {
            guard let name = dict["name"] as? String else { continue }
            let full = cwdPath.appending(name).raw

            let kind: RemoteFileEntry.Kind
            if let t = dict["type"] as? String {
                switch t {
                case "dir":  kind = .directory
                case "file": kind = .file
                default:     kind = .unknown
                }
            } else { kind = .unknown }

            let size  = (dict["size"] as? NSNumber)?.uint64Value
            let perms = (dict["mode"] as? NSNumber)?.uint32Value
            let mtime = (dict["mtime"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue)
            }

            let entry = RemoteFileEntry(
                name: name,
                path: full,
                kind: kind,
                size: size,
                modified: mtime,
                mode: perms
            )
            out.append(entry)
        }

        return (cwdPath, out)
    }

    /// Utility: convert any decoded JSON into pretty-printed text (for debugging).
    public func prettyPrintedJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
              let s = String(data: data, encoding: .utf8)
        else { return "<non-JSON>" }
        return s
    }
}

// MARK: - NSNumber helpers (for bridging C/JSON types)
private extension NSNumber {
    var uint32Value: UInt32 { UInt32(truncating: self) }
    var uint64Value: UInt64 { UInt64(truncating: self) }
}
