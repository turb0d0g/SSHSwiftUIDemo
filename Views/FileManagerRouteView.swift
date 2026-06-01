//
//  FileManagerRouteView.swift
//  SSHSwiftUIDemo
//
//  Created by You on 11/02/25.
//

import SwiftUI
import OSLog

/// Wraps SFTP connection setup and injects a live `SFTPConnection` into `RemoteFileManagerView`.
struct FileManagerRouteView: View {
    let device: Device

    @State private var sftp: SFTPConnection?
    @State private var connectError: String?
    @State private var isConnecting = false

    private let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "FileManagerRoute")

    var body: some View {
        Group {
            if let conn = sftp {
                RemoteFileManagerView(
                    sftpConnection: conn,
                    initialPath: "/home/\(device.username)" // adjust if home differs
                )
            } else if let err = connectError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .imageScale(.large)
                    Text("SFTP connection failed")
                        .font(.headline)
                    Text(err)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await openSFTP() }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(isConnecting ? "Opening SFTP…" : "Preparing…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .task { await openSFTP() } // kick once on appear
            }
        }
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - SFTP bootstrap

    @MainActor
    private func openSFTP() async {
        guard !isConnecting, sftp == nil else { return }
        isConnecting = true
        connectError = nil
        defer { isConnecting = false }

        do {
            let account = "\(device.username)@\(device.host)"
            let password = (try? KeychainService.loadPassword(account: account)) ?? ""
            let creds = SFTPCredentials(username: device.username, password: password)

            let conn = SFTPConnection(config: .init(
                host: device.host,
                port: device.port,            // assumes `Device.port: Int`
                credentials: creds
            ))

            log.info("[FileManagerRoute] connect → \(device.host, privacy: .public):\(device.port, privacy: .public)")
            try await conn.connect()
            self.sftp = conn
            log.info("[FileManagerRoute] ✅ SFTP ready for \(device.host, privacy: .public)")
        } catch {
            let msg = String(describing: error)
            connectError = msg
            log.error("[FileManagerRoute] ❌ connect error: \(msg, privacy: .public)")
        }
    }
}
