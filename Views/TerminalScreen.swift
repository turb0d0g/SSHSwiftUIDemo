//
//  TerminalScreen.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 7/26/25.
//

//
//  TerminalScreen.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 7/26/25.
//  Updated: 2026-01-12
//

import SwiftUI
import SwiftTerm

struct TerminalScreen: View {
    let device: Device

    @EnvironmentObject private var devicesVM: DevicesViewModel
    @StateObject private var vm: TerminalViewModel

    // Track the lifecycle of this specific screen instance (debug)
    private let screenInstanceID = UUID().uuidString

    // Cancelable connect task (prevents zombie connects holding things alive)
    @State private var connectTask: Task<Void, Never>?

    // A stable identity key for this screen/connection.
    // This avoids accidental VM churn if `Device` is replaced with a new value instance.
    private var stableKey: String {
        "\(device.username)@\(device.host):\(device.port)"
    }

    init(device: Device) {
        self.device = device
        _vm = StateObject(wrappedValue: TerminalViewModel(ssh: SSHManager()))
    }

    var body: some View {
        ZStack {
            SwiftUITerminalView(viewModel: vm)
                .ignoresSafeArea(edges: .bottom)

            switch vm.connectionState {
            case .connecting:
                ProgressView("Connecting…")
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

            case .failed(let err):
                VStack(spacing: 12) {
                    Text("Connection Failed").font(.headline)
                    Text(err.localizedDescription)
                        .font(.footnote)
                        .multilineTextAlignment(.center)

                    Button("Dismiss") {
                        print("[TerminalScreen] dismiss tapped instance=\(screenInstanceID) key=\(stableKey)")
                        Task { await vm.disconnect() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

            default:
                EmptyView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)

        // ✅ Make the view identity stable per device connection key.
        // If Device changes as a value type, but key is the same, SwiftUI is less likely to churn state.
        .id(stableKey)

        // ✅ Run connect logic once per stableKey. If the key changes, SwiftUI cancels previous task and starts a new one.
        .task(id: stableKey) {
            print("[TerminalScreen] task start instance=\(screenInstanceID) key=\(stableKey)")

            // Cancel any prior connect task (belt + suspenders)
            connectTask?.cancel()

            // Kick a probe (coalesced / single-flight in DevicesVM)
            devicesVM.requestRefresh(.single(device), reason: "TerminalScreen.task.preConnectProbe key=\(stableKey)")

            // Spawn a child task we can explicitly cancel onDisappear.
            connectTask = Task { [stableKey] in
                if Task.isCancelled {
                    print("[TerminalScreen] connectTask cancelled before start instance=\(screenInstanceID) key=\(stableKey)")
                    return
                }

                // Provider *must* be async -> String?
                let provider: InteractivePasswordDelegate.Provider = { () async -> String? in
                    let account = stableKey
                    do {
                        let pw = try KeychainService.loadPassword(account: account)
                        // print("[TerminalScreen] Keychain ok account=\(account)")
                        return pw
                    } catch {
                        print("[TerminalScreen] Keychain lookup failed account=\(account): \(error.localizedDescription)")
                        return nil
                    }
                }

                print("[TerminalScreen] connect begin instance=\(screenInstanceID) key=\(stableKey)")
                await vm.connect(
                    host: device.host,
                    port: device.port,
                    username: device.username,
                    passwordProvider: provider
                )
                print("[TerminalScreen] connect end instance=\(screenInstanceID) key=\(stableKey)")
            }

            // Await so SwiftUI task cancellation propagates cleanly.
            await connectTask?.value
            print("[TerminalScreen] task end instance=\(screenInstanceID) key=\(stableKey)")
        }

        .onDisappear {
            print("[TerminalScreen] disappear instance=\(screenInstanceID) key=\(stableKey)")

            // ✅ Kill any in-flight connect work first.
            connectTask?.cancel()
            connectTask = nil

            // ✅ Then disconnect the SSH session.
            Task { await vm.disconnect() }
        }
    }
}
