//
//  SFTPConnection+ReadText.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 12/29/25.
//
//
//  SFTPConnection+ReadText.swift
//  SSHSwiftUIDemo
//

import Foundation

public extension SFTPConnection {

    /// Downloads up to `maxBytes` from `path` and decodes as UTF-8 (lossy).
    /// Appends a truncation banner if data likely hit the cap.
    ///
    /// Why lossy UTF-8? Because logs/configs often contain garbage bytes and you still want *something* visible.
    func readTextFile(path: String, maxBytes: Int = 256 * 1024) async throws -> String {
        print("[SFTPConnection] readTextFile start path=\(path) maxBytes=\(maxBytes)")

        let data = try await download(path: path, maxBytes: maxBytes)

        // Lossy decode keeps UI resilient
        var text = String(decoding: data, as: UTF8.self)

        if data.count >= maxBytes {
            text += "\n\n…(truncated at \(maxBytes) bytes)…\n"
        }

        print("[SFTPConnection] readTextFile ok bytes=\(data.count) chars=\(text.count) path=\(path)")
        return text
    }
}
