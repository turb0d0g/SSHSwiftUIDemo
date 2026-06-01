// ViewModels/TerminalViewModel.swift
// FULL FILE — SwiftTerm + NIOSSH glue with scroll/auto-follow, local banner pre-inject,
// transcript capture for share, and verbose debug prints.

// ViewModels/TerminalViewModel.swift
// FULL FILE — SwiftTerm + NIOSSH glue with scroll/auto-follow, local banner pre-inject,
// transcript capture for share, and verbose debug prints.

//
//  TerminalViewModel.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 2025-10-07.
//
//  SwiftTerm + NIOSSH glue:
//   - SSH bytes -> TerminalView.feed
//   - TerminalView -> SSH send()
//   - connection state -> published
//   - PTY resize throttling (WINCH hook point)
//
//  ARC tracking:
//   - Uses ARCTracker.registerToken(self) (non-retaining token)
//   - Unregisters by token in deinit (no DeinitHook; no self-retain cycle)
//
//  iOS 16+
//

import Foundation
import Combine
import SwiftTerm
import NIOSSH

@MainActor
final class TerminalViewModel: ObservableObject {

    // MARK: - Dependencies

    /// Injected SSH actor (handles NIO + authentication)
    let ssh: SSHManager

    // MARK: - UI bridge

    /// Reference to active TerminalView (UIKit view wrapped by SwiftUI)
    weak var terminal: TerminalView?

    // MARK: - Combine

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Published

    @Published var connectionState: SSHManager.ConnectionState = .idle

    // MARK: - ARC tracking

    /// Non-retaining token from ARCTracker. Safe to keep and use in deinit without capturing self.
    private var arcToken: ARCTracker.Token?

    // MARK: - Debug

    private let instanceID = UUID().uuidString
    private let debugLabel: String

    // MARK: - WINCH throttle

    private var lastWinch: (cols: Int, rows: Int, t: TimeInterval) = (0, 0, 0)

    // MARK: - Init

    init(ssh: SSHManager) {
        self.ssh = ssh
        self.debugLabel = "TerminalViewModel"

        let oid = ObjectIdentifier(self).hashValue.magnitude
        print("[TerminalVM] init id=\(instanceID) oidHash=\(oid)")

        // ✅ ARCTracker registration using token (no self-retain cycle).
        Task { [weak self] in
            guard let self else { return }
            let token = await ARCTracker.shared.registerToken(self, note: "TerminalViewModel", expectedLifetime: .transient)
            self.arcToken = token
            print("[TerminalVM] ARCTracker.registerToken ok id=\(self.instanceID) token.id=\(token.id) oidRaw=\(token.oidRaw)")
        }

        // Bytes → Terminal
        // Keep receive(on:) because ssh.output likely emits from NIO threads.
        ssh.output
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                guard let self else { return }
                guard let t = self.terminal else {
                    // If this is noisy for you, comment it out.
                    // print("[TerminalVM] drop \(data.count) bytes (no terminal attached) id=\(self.instanceID)")
                    return
                }

                // Optional trace:
                // print("[TerminalVM] ⬅︎ \(data.count) bytes id=\(self.instanceID)")

                data.withUnsafeBytes { raw in
                    let slice = ArraySlice(raw.bindMemory(to: UInt8.self))
                    t.feed(byteArray: slice)
                }
            }
            .store(in: &cancellables)

        // State → UI
        ssh.state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                guard let self else { return }
                self.connectionState = newState
                print("[TerminalVM] state=\(newState) id=\(self.instanceID)")
            }
            .store(in: &cancellables)
    }

    // MARK: - Deinit

    deinit {
        // Keep deinit simple. Combine cancellation is fine.
        print("[DEINIT] TerminalViewModel id=\(instanceID) → cancel Combine")
        cancellables.removeAll()

        // ✅ Unregister by token (no object capture).
        if let token = arcToken {
            let iid = instanceID
            Task {
                await ARCTracker.shared.unregister(token: token)
                print("[TerminalVM] ARCTracker.unregister(token) ok id=\(iid) token.id=\(token.id)")
            }
        } else {
            // If init Task never ran (very early deinit), that’s fine.
            print("[TerminalVM] deinit id=\(instanceID) (no arcToken yet)")
        }
    }

    // MARK: - Attach terminal

    func attachTerminal(_ tv: TerminalView) {
        self.terminal = tv
        print("[TerminalVM] attachTerminal id=\(instanceID) term=\(Unmanaged.passUnretained(tv).toOpaque())")
    }

    // MARK: - Outbound path (Terminal → SSH)

    func send(_ data: ArraySlice<UInt8>) async {
        do {
            // Optional trace:
            // print("[TerminalVM] ➡︎ send \(data.count) bytes id=\(instanceID)")
            try await ssh.send(data)
        } catch {
            print("[TerminalVM] send error id=\(instanceID): \(error)")
        }
    }

    // MARK: - Optional PTY resize event

    func windowChange(cols: Int, rows: Int) async {
        // Ignore garbage first call
        guard cols > 0, rows > 0 else { return }

        // Drop duplicates
        if cols == lastWinch.cols, rows == lastWinch.rows { return }

        // Throttle to max 5/sec
        let now = Date().timeIntervalSince1970
        if (now - lastWinch.t) < 0.20 { return }

        lastWinch = (cols, rows, now)
        print("[TerminalVM] windowChange cols=\(cols) rows=\(rows) id=\(instanceID) (throttled)")

        // Hook point:
        // await ssh.windowChange(cols: cols, rows: rows)
    }

    // MARK: - Connection lifecycle

    func connect(
        host: String,
        port: Int,
        username: String,
        passwordProvider: @escaping InteractivePasswordDelegate.Provider
    ) async {
        print("[TerminalVM] connect host=\(host) port=\(port) user=\(username) id=\(instanceID)")
        await ssh.connect(host: host, port: port, username: username, passwordProvider: passwordProvider)
    }

    func disconnect() async {
        print("[TerminalVM] disconnect id=\(instanceID)")
        await ssh.disconnect()
    }
}
