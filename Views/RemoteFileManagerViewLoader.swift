//
//  RemoteFileManagerViewLoader.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 11/6/25.
//

//
//  RemoteFileManagerViewLoader.swift
//  SSHSwiftUIDemo
//

import SwiftUI
import NIO
import NIOSSH
import OSLog

private let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "RemoteFileManager")

struct RemoteFileManagerViewLoader: View {
    @EnvironmentObject private var devicesVM: DevicesViewModel
    let device: Device

    @State private var sftpChannel: Channel?
    @State private var error: Error?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let sftpChannel {
                RemoteFileManagerView(
                    sftpChannel: sftpChannel,
                    initialPath: "/home/\(device.username)"
                )
            } else if let error {
                // Your ErrorOverlay apparently requires a retryAction closure.
                ErrorOverlay(error: error, retryAction: {
                    Task { await connectAndOpenSFTP(isRetry: true) }
                })
            } else {
                ProgressView("Opening SFTP to \(device.host)…")
                    .task { await connectAndOpenSFTP(isRetry: false) }
            }
        }
        .navigationTitle("File Manager")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            // Optional: Close the SFTP channel when leaving
            if let ch = sftpChannel {
                log.debug("[RemoteFileManager] closing SFTP channel on disappear")
                _ = ch.close(mode: .all)
            }
        }
    }

    @Sendable
    private func connectAndOpenSFTP(isRetry: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            log.debug("[RemoteFileManager] connectAndOpenSFTP start host=\(self.device.host, privacy: .public) retry=\(isRetry, privacy: .public)")

            // Prefer your shared/pooled manager for this device
            let ssh = SSHManager.shared(for: device)

            // Ensure SSH is connected; if you already guarantee connection upstream, this is harmless.
            try await ssh.ensureConnected()

            // Open SFTP child channel
            let ch = try await ssh.openSFTPChannel()

            await MainActor.run {
                self.error = nil
                self.sftpChannel = ch
            }

            log.info("[RemoteFileManager] SFTP channel ready for \(self.device.name, privacy: .public)")
        } catch {
            await MainActor.run {
                self.sftpChannel = nil
                self.error = error
            }
            log.error("[RemoteFileManager] failed to open SFTP: \(String(describing: error), privacy: .public)")
        }
    }
}
