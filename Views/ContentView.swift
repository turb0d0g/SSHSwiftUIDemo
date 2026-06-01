//
//  ContentView.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 7/25/25.
//

import SwiftUI
import Combine

/// Add Device form (compactly composed to avoid type-checker blowups)
struct ContentView: View {
    // Connection tester state (instead of TerminalViewModel(device:))
    @State private var connState: SSHManager.ConnectionState = .idle
    @State private var cancellable: AnyCancellable?

    // Form inputs
    @State private var deviceName = ""
    @State private var host = ""
    @State private var portString = "22"
    @State private var timeoutString = "15"
    @State private var username = ""
    enum AuthMethod: String, CaseIterable { case password = "Password", sshKey = "SSH Key" }
    @State private var auth: AuthMethod = .password
    @State private var password = ""
    @State private var showPassword = false

    // UI state
    @State private var showConnectingHUD = false
    @State private var showResult = false
    @State private var resultTitle = ""
    @State private var resultMessage = ""

    private var formValid: Bool {
        !host.isEmpty && Int(portString) != nil && !username.isEmpty && (auth == .password ? !password.isEmpty : true)
    }
    private var isConnecting: Bool {
        if case .connecting = connState { return true }
        return false
    }
    
    init() {
        print("🔥 ContentView init")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView { formContent }
                if showConnectingHUD || isConnecting { connectingHUD }
            }
            .navigationTitle("Add Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .alert(resultTitle, isPresented: $showResult) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(resultMessage)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var formContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            LabeledField("Device name:", placeholder: "e.g. Kitchen Pi", text: $deviceName)
            hostRow
            portTimeoutRow
            LabeledField("Username:", placeholder: "e.g. pi", text: $username)
            authPickerRow
            if auth == .password { passwordRow }
            connectionTestButton
            helpTiles
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 28)
    }

    private var hostRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Host / IP Address:").font(.callout).foregroundStyle(.secondary)
                TextField("e.g. 192.168.1.148", text: $host)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .textFieldStyle(.roundedBorder)
            }
            Button {
                print("[UI] Host discovery tapped")
            } label: {
                Image(systemName: "magnifyingglass.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .accessibilityLabel("Discover Host on Network")
        }
    }

    private var portTimeoutRow: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SSH Port:").font(.callout).foregroundStyle(.secondary)
                TextField("22", text: $portString)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Timeout (Sec):").font(.callout).foregroundStyle(.secondary)
                TextField("15", text: $timeoutString)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    
                    
            }
        }
    }

    private var authPickerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Authentication:").font(.callout).foregroundStyle(.secondary)
            HStack {
                Picker("", selection: $auth) {
                    ForEach(AuthMethod.allCases, id: \.self) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
                .pickerStyle(.menu)
                .tint(.blue)
                Spacer()
                Image(systemName: "chevron.down").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        }
    }

    private var passwordRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Password:").font(.callout).foregroundStyle(.secondary)
            HStack {
                if showPassword {
                    TextField("Password", text: $password)
                        .textContentType(.password)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .textFieldStyle(.roundedBorder)
                }
                Button { showPassword.toggle() } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var connectionTestButton: some View {
        Button(action: connectionTest) {
            Text("Connection test")
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
        }
        .buttonStyle(.borderedProminent)
        .tint(.blue)
        .disabled(!formValid)
        .padding(.top, 8)
    }

    private var helpTiles: some View {
        HStack(spacing: 24) {
            HelpTile(systemImage: "lifepreserver.fill",
                     title: "Raspberry Pi configuration for use with RaspController") {
                print("[UI] Open Pi configuration guide")
            }
            HelpTile(systemImage: "key.fill",
                     title: "Using SSH Keys for authentication with RaspController") {
                print("[UI] Open SSH keys guide")
            }
        }
        .padding(.top, 28)
    }

    private var connectingHUD: some View {
        ProgressView("Connecting…")
            .progressViewStyle(.circular)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .allowsHitTesting(false)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Devices") { print("[UI] Back to Devices") }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button("Save") { saveDevice() }.disabled(!formValid)
        }
    }

    // MARK: - Actions

    private func connectionTest() {
        guard let port = Int(portString) else { return }
        let timeout = Double(timeoutString) ?? 15
        print("[UI] Connection test → \(host):\(port) as \(username) (auth: \(auth.rawValue)), timeout \(timeout)s")

        showConnectingHUD = true
        resultTitle = ""; resultMessage = ""
        connState = .connecting

        Task {
            print("---->>>>> ContentView task start")
            // Throwaway manager used only for the test
            let tester = SSHManager()

            // Mirror tester state into our local `connState` for the HUD
            cancellable = tester.state
                .receive(on: RunLoop.main)
                .sink { st in
                    print("[ConnTest] state → \(st)")
                    connState = st
                }

            // Build a password provider using the typed password
            let provider: InteractivePasswordDelegate.Provider = { [password] in
                print("[ConnTest] providing typed password (\(password.count) chars)")
                return password
            }

            // Start, wait briefly, then decide
            await tester.connect(host: host, port: port, username: username, passwordProvider: provider)

            // Wait up to `timeout` seconds for the state to flip away from `.connecting`
            let start = Date()
            while Date().timeIntervalSince(start) < timeout {
                if case .connected = connState { break }
                if case .failed = connState { break }
                try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s poll
            }

            showConnectingHUD = false

            switch connState {
            case .connected:
                resultTitle = "Connection Successful"
                resultMessage = "Handshake completed. Check the Xcode console for SSH logs."
                showResult = true
                await tester.disconnect()

            case .failed(let err):
                resultTitle = "Connection Failed"
                resultMessage = err.localizedDescription
                showResult = true
                await tester.disconnect()

            default:
                resultTitle = "Connection Inconclusive"
                resultMessage = "Still negotiating… or timed out after \(Int(timeout))s. Check the console for logs."
                showResult = true
                await tester.disconnect()
            }

            // Clean up subscription
            cancellable?.cancel()
            cancellable = nil
            connState = .idle
        }
    }

    private func saveDevice() {
        print("[UI] Save device '\(deviceName)' → \(host):\(portString) user=\(username) auth=\(auth.rawValue)")
        let account = "\(username)@\(host)"
        if auth == .password, !password.isEmpty {
            do { try KeychainService.savePassword(account: account, password: password) }
            catch { print("[UI] Keychain save failed: \(error)") }
        }
    }
}

// MARK: - Small reusable pieces

private struct LabeledField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    init(_ title: String, placeholder: String, text: Binding<String>) {
        self.title = title
        self.placeholder = placeholder
        self._text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct HelpTile: View {
    let systemImage: String
    let title: String
    var tap: () -> Void

    var body: some View {
        Button(action: tap) {
            VStack(spacing: 8) {
                Image(systemName: systemImage).font(.title2)
                Text(title).font(.footnote).multilineTextAlignment(.center)
            }
            .foregroundStyle(.blue)
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(UIColor.systemGray6))
            )
        }
        .buttonStyle(.plain)
    }
}
