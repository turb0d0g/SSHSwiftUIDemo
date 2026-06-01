//
//  RemoteFileViewerViewModel.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 12/25/25.
//


//
//  RemoteFileViewerViewModel.swift
//  SSHSwiftUIDemo
//

import Foundation
import OSLog

@MainActor
final class RemoteFileViewerViewModel: ObservableObject {
    private let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "RemoteFileViewerVM")

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var state: LoadState = .idle
    @Published var text: String = ""
    @Published private(set) var lastLoadedAt: Date?

    private let sshManager: SSHManager
    private let hostLabel: String

    init(sshManager: SSHManager, hostLabel: String) {
        self.sshManager = sshManager
        self.hostLabel = hostLabel
    }
    
    deinit {
        print("[DEINIT] \(String(describing: Self.self))")
    }

    /// Bounded read to protect UI + bandwidth. Default ~256KB.
    func load(path: String, maxBytes: Int = 256 * 1024) async {
        log.debug("[RemoteFileViewerVM] load start host=\(self.hostLabel, privacy: .public) path=\(path, privacy: .public) maxBytes=\(maxBytes)")
        state = .loading

        do {
            let content = try await readRemoteTextFile(path: path, maxBytes: maxBytes)
            self.text = content
            self.lastLoadedAt = Date()
            self.state = .loaded
            log.debug("[RemoteFileViewerVM] load ok bytes=\(content.utf8.count) path=\(path, privacy: .public)")
        } catch {
            let msg = String(describing: error)
            self.state = .failed(msg)
            log.error("[RemoteFileViewerVM] load FAIL path=\(path, privacy: .public) err=\(msg, privacy: .public)")
        }
    }

    // MARK: - Remote read implementation

    private func readRemoteTextFile(path: String, maxBytes: Int) async throws -> String {
        // Strategy:
        // 1) dd a bounded byte count (works for any file; avoids huge output)
        // 2) Attempt UTF-8 decode (lossy fallback) so we can still show "something"
        // 3) Add a notice if truncated
        //
        // We also force a stable locale to reduce weird encoding surprises.
        let qPath = ShellEscaping.singleQuoted(path)
        let cmd = """
        set -euo pipefail
        LC_ALL=C dd if=\(qPath) bs=1 count=\(maxBytes) 2>/dev/null || true
        """

        log.debug("[RemoteFileViewerVM] ssh exec dd cmd=\(cmd, privacy: .public)")

        // ---- ADAPT THIS ONE CALL if your SSHManager differs ----
        let data = try await sshExecData(cmd)
        // -------------------------------------------------------

        let decoded = String(decoding: data, as: UTF8.self) // lossy but safe for UI
        let truncatedHint = data.count >= maxBytes ? "\n\n…(truncated at \(maxBytes) bytes)…\n" : ""
        return decoded + truncatedHint
    }

    /// Preferred: SSH exec that returns raw stdout bytes (not pre-decoded).
    /// If your SSHManager only returns String, convert that to Data.
    private func sshExecData(_ command: String) async throws -> Data {
        log.debug("[RemoteFileViewerVM] sshExecData start host=\(self.hostLabel, privacy: .public)")
        // Replace with your real implementation.
        // Common pattern: try await sshManager.exec(command: command) -> String
        // If you only have String, do: Data(result.utf8)
        let stdout: String = try await sshManager.exec(command: command, timeout: 10, requireZeroExit: false)
        log.debug("[RemoteFileViewerVM] sshExecData done chars=\(stdout.count)")
        return Data(stdout.utf8)
    }
}
