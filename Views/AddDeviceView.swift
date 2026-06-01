//
//  AddDeviceView.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 7/26/25.
//  Updated on 11/06/25: matches current Device struct (lteHost:String, no tunnelPort),
//  restores Test Connection button, KeychainService integration, robust async save.
//

import SwiftUI
import OSLog

private let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "AddDeviceView")

struct AddDeviceView: View {
    @ObservedObject var store: DeviceStore
    @Environment(\.dismiss) private var dismiss

    // MARK: - Form Fields
    @State private var name: String = ""
    @State private var host: String = ""
    @State private var lteHost: String = ""          // required but user can leave blank
    @State private var portString: String = "22"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var revealPassword = false

    // MARK: - Test Connection
    enum TestStatus: Equatable {
        case idle, running, success, failure(String), timeout
    }
    @State private var testStatus: TestStatus = .idle
    @State private var showTestingHUD = false

    // MARK: - Derived
    private var port: Int? { Int(portString.trimmingCharacters(in: .whitespaces)) }
    private var formValid: Bool { port != nil && !host.isEmpty && !username.isEmpty }
    private var canSave: Bool {
        formValid && !password.isEmpty && (testStatus == .success || testStatus == .idle)
    }
    private var accountKey: String {
        "\(username.trimmingCharacters(in: .whitespaces))@\(host.trimmingCharacters(in: .whitespaces))"
    }

    // MARK: - UI
    var body: some View {
        Form {
            Section {
                TextField("Name (optional)", text: $name)

                TextField("Host (LAN or DNS)", text: $host)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)

                TextField("SSH Port", text: $portString)
                    .keyboardType(.numberPad)

                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)

                HStack {
                    Group {
                        if revealPassword {
                            TextField("Password", text: $password)
                                .textContentType(.password)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                        } else {
                            SecureField("Password", text: $password)
                                .textContentType(.password)
                        }
                    }
                    Button {
                        revealPassword.toggle()
                    } label: {
                        Image(systemName: revealPassword ? "eye.slash" : "eye")
                    }
                }
            } header: {
                Text("Connection")
            }

            Section {
                TextField("LTE Host (optional, leave blank if unused)", text: $lteHost)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
            } header: {
                Text("LTE Host")
            }

            // Test Connection
            Section {
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        if showTestingHUD { ProgressView() }
                        Text(buttonLabel())
                        Spacer()
                        statusIcon()
                    }
                }
                .disabled(!formValid || password.isEmpty || showTestingHUD)
            } header: {
                Text("Connectivity Check")
            } footer: {
                switch testStatus {
                case .idle:
                    Text("Tap Test Connection to verify SSH login.")
                case .running:
                    Text("Testing SSH connectivity…")
                case .success:
                    Text("Test succeeded! You can save this device.").foregroundStyle(.green)
                case .failure(let msg):
                    Text("Failed: \(msg)").foregroundStyle(.red)
                case .timeout:
                    Text("Timeout — check network and retry.").foregroundStyle(.red)
                }
            }

            // Save
            Section {
                Button {
                    Task { await saveAndDismiss() }
                } label: {
                    Label("Save Device", systemImage: "tray.and.arrow.down")
                }
                .disabled(!canSave)
            }
        }
        .navigationTitle("Add Device")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { Task { await saveAndDismiss() } }
                    .disabled(!canSave)
            }
        }
    }

    // MARK: - Actions

    private func saveAndDismiss() async {
        guard let p = port else { return }
        let device = Device(
            id: UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: p,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            lteHost: lteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        log.info("[AddDevice] Saving \(device.username, privacy: .public)@\(device.host, privacy: .public):\(device.port)")

        await store.add(device)

        if !password.isEmpty {
            do {
                try KeychainService.savePassword(account: accountKey, password: password)
                log.debug("[AddDevice] Keychain saved for \(accountKey, privacy: .private(mask: .hash))")
            } catch {
                log.error("[AddDevice] Keychain save failed: \(String(describing: error), privacy: .public)")
            }
        }

        await MainActor.run { dismiss() }
    }

    private func testConnection() async {
        guard let p = port else { return }
        showTestingHUD = true
        testStatus = .running

        let result = await ConnectionTester.test(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: p,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password
        )

        await MainActor.run {
            switch result {
            case .success:
                testStatus = .success
            case .authFailed:
                testStatus = .failure("Authentication failed.")
            case .hostUnreachable:
                testStatus = .failure("Host unreachable.")
            case .connectionRefused:
                testStatus = .failure("Connection refused.")
            case .timeout:
                testStatus = .timeout
            case .hostKeyChanged:
                testStatus = .failure("Host key changed.")
            case .serverClosedEarly:
                testStatus = .failure("Server closed early.")
            case .unknown(let msg):
                testStatus = .failure(msg)
            case .timedOut:
                testStatus = .failure("Timed out.")
            case .failure:
                testStatus = .failure("Failed.")
            case .disconnected:
                testStatus = .failure("Disconnected.")
            }
            showTestingHUD = false
        }
    }

    // MARK: - UI helpers
    private func buttonLabel() -> String {
        switch testStatus {
        case .idle: return "Test Connection"
        case .running: return "Testing…"
        case .success: return "Re-Test Connection"
        case .failure, .timeout: return "Retry Test"
        }
    }

    @ViewBuilder
    private func statusIcon() -> some View {
        switch testStatus {
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure, .timeout:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        default:
            EmptyView()
        }
    }
}

/*
import SwiftUI

struct AddDeviceView: View {
    // Store is injected at the app level
    @ObservedObject var store: DeviceStore

    // Use dismiss() to pop after saving (works for stacks and sheets)
    @Environment(\.dismiss) private var dismiss

    // Router is optional; kept in case you use it elsewhere
    @EnvironmentObject private var router: NavigationRouter

    // Form fields
    @State private var name: String = ""
    @State private var host: String = ""
    @State private var portString: String = "22"
    @State private var username: String = ""

    // Password (only written to Keychain on Save)
    @State private var password: String = ""
    @State private var revealPassword = false

    // Test connection state
    enum TestStatus: Equatable {
        case idle
        case running
        case success
        case failure(String)
        case timeout
    }
    @State private var testStatus: TestStatus = .idle
    @State private var showTestingHUD = false
    @State private var showResultAlert = false
    @State private var resultTitle = ""
    @State private var resultMessage = ""

    private var port: Int? { Int(portString.trimmingCharacters(in: .whitespaces)) }
    private var formValid: Bool {
        if let p = port, (1...65535).contains(p) {
            return !host.isEmpty && !username.isEmpty
        }
        return false
    }
    private var canSave: Bool {
        formValid && !password.isEmpty && testStatus == .success
    }

    var body: some View {
        Form {
            Section(header: Text("Connection")) {
                TextField("Name (optional)", text: $name)

                TextField("Host", text: $host)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)

                TextField("Port", text: $portString)
                    .keyboardType(.numberPad)

                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)

                HStack {
                    Group {
                        if revealPassword {
                            TextField("Password", text: $password)
                                .textContentType(.password)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                        } else {
                            SecureField("Password", text: $password)
                                .textContentType(.password)
                        }
                    }
                    Button {
                        revealPassword.toggle()
                    } label: {
                        Image(systemName: revealPassword ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        if showTestingHUD { ProgressView().padding(.trailing, 6) }
                        Text(buttonTitleForTest())
                        Spacer()
                        statusGlyph()
                    }
                }
                .disabled(!formValid || password.isEmpty || showTestingHUD)

                Button("Save Device") { saveDevice() }
                    .disabled(!canSave)
            } footer: {
                switch testStatus {
                case .idle:
                    Text("Enter host, port, username, and password; tap Test Connection before saving.")
                case .running:
                    Text("Testing… this performs a real SSH handshake and will print details to the console.")
                case .success:
                    Text("Test passed. You can save this device now.")
                        .foregroundStyle(.green)
                case .failure(let msg):
                    Text("Test failed: \(msg)").foregroundStyle(.red)
                case .timeout:
                    Text("Timed out. Check host, port, or network and try again.").foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Add Device")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save", action: saveDevice)
                    .disabled(!canSave)
            }
        }
        .alert(resultTitle, isPresented: $showResultAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(resultMessage)
        }
    }

    // MARK: - Test

    private func testConnection() async {
        guard let p = port, !host.isEmpty, !username.isEmpty, !password.isEmpty else { return }

        showTestingHUD = true
        testStatus = .running
        print("[AddDevice] Testing \(username)@\(host):\(p)…")

        let candidate = Device(
            id: UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            port: p,
            username: username.trimmingCharacters(in: .whitespaces)
            //lastConnected: (nil as Date?)   // <-- explicit type to avoid 'nil requires contextual type'
        )

        let tester = ConnectionTester()
        let result = await ConnectionTester.test(host: host, port: port!, username: username, password: password, timeout: 10)
        showTestingHUD = false

        switch result {
            
        case .success:
            print("[AddDevice] Test succeeded.")
            resultTitle = "Connection Successful"
            resultMessage = "Handshake completed. See console for SSH details."
            testStatus = .success
            showResultAlert = true

        case .failure:
            //print("[AddDevice] Test failed: \(err.localizedDescription)")
            resultTitle = "Connection Failed"
            //resultMessage = err.localizedDescription
            //testStatus = .failure(err.localizedDescription)
            showResultAlert = true
        case .timedOut:
            print("[AddDevice] Test timed out.")
            resultTitle = "Timed Out"
            resultMessage = "No response within 10 seconds."
            testStatus = .timeout
            showResultAlert = true
        case .disconnected:
            print("[AddDevice] Disconnected.")
            resultTitle = "Disconnected"
            resultMessage = "Connection disconnected."
            testStatus = .timeout
            showResultAlert = true
        case .authFailed:
            print("[AddDevice] Auth failed.")
            resultTitle = "Auth Failed"
            resultMessage = "Auth failed. Check credentials."
            showResultAlert = true
        case .hostUnreachable:
            print("[AddDevice] Host unreachable. Check hostname.")
            resultTitle = "Host Unreachable"
            resultMessage = "Host unreachable. Check hostname."
            showResultAlert = true
        case .connectionRefused:
            print("[AddDevice] Connection refused. Check credentials.")
            resultTitle = "Connection Refused"
            resultMessage = "Connection refused. Check credentials."
            showResultAlert = true
        case .timeout:
            print("[AddDevice] Timeout.")
            resultTitle = "Timeout"
            resultMessage = "Timeout. Check credentials."
            showResultAlert = true
        case .hostKeyChanged:
            print("[AddDevice] Host key changed.")
            resultTitle = "Host Key Changed"
            resultMessage = "Host key changed. Check credentials."
            showResultAlert = true
        case .serverClosedEarly:
            print("[AddDevice] Server closed early.")
            resultTitle = "Server Closed Early"
            resultMessage = "Server closed early. Check credentials."
            showResultAlert = true
        case .unknown(message: let message):
            print("[AddDevice] Unknown error: \(message)")
            resultTitle = "Unknown Error"
            resultMessage = "Unknown error. Check credentials."
            showResultAlert = true
        }
    }

    // MARK: - Save

    private func saveDevice() {
        guard canSave, let p = port else { return }

        let device = Device(
            id: UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            port: p,
            username: username.trimmingCharacters(in: .whitespaces)
            //lastConnected: (nil as Date?)   // <-- explicit type again
        )

        // Save password to Keychain
        let account = "\(device.username)@\(device.host)"
        do {
            try KeychainService.savePassword(account: account, password: password)
            print("[AddDevice] Saved password for \(account) to Keychain.")
        } catch {
            print("[AddDevice] Failed to save password to Keychain: \(error)")
        }

        // Save device to store and pop back
        store.add(device)
        print("[AddDevice] Saved device \(device).")
        dismiss()
    }

    // MARK: - UI helpers

    @ViewBuilder
    private func statusGlyph() -> some View {
        switch testStatus {
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure, .timeout:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .running, .idle:
            EmptyView()
        }
    }

    private func buttonTitleForTest() -> String {
        switch testStatus {
        case .idle:    return "Test Connection"
        case .running: return "Testing…"
        case .success: return "Re-test Connection"
        case .failure: return "Retry Test"
        case .timeout: return "Retry Test"
        }
    }
}
*/
