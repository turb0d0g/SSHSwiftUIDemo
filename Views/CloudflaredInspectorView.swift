//
//  CloudflaredInspectorView.swift
//  SSHSwiftUIDemo
//
//  UI for Cloudflared tunnel health + URL discovery.
//  Uses CloudflaredInspectorViewModel (cloudflared_inspector.cgi shape).
//
//  iOS 16+
//

//
//  CloudflaredInspectorView.swift
//  SSHSwiftUIDemo
//
//  UI for Cloudflared tunnel health + URL discovery.
//  Uses CloudflaredInspectorViewModel (cloudflared_inspector.cgi shape).
//
//  iOS 16+
//

import SwiftUI

public struct CloudflaredInspectorView: View {

    // MARK: - Inputs

    let device: Device
    public let title: String

    // MARK: - State

    private let baseCGIURL: URL
    @StateObject private var viewModel: CloudflaredInspectorViewModel

    // MARK: - Init

    init(
        device: Device,
        title: String = "Cloudflared Inspector"
    ) {
        self.device = device
        self.title = title

        let base = URL(string: "http://\(device.host)/cgi-bin")!
        self.baseCGIURL = base

        // Canonical stable hostname for this project.
        // Treat this as human-configured (what you WANT), not what cloudflared happens to output.
        let stable = "https://hairpi.org"

        _viewModel = StateObject(wrappedValue: CloudflaredInspectorViewModel(
            baseCGIURL: base,
            preferredTunnelName: "hairpi",
            expectedStableURL: stable
        ))
    }

    // MARK: - Body

    public var body: some View {
        List {
            statusSection
            tunnelSection
            urlsSection
            metaSection

            if !viewModel.lastRawBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rawSection
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await viewModel.refreshOnce() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
            }
        }

        // ✅ Single source of truth for lifecycle:
        // SwiftUI cancels this task automatically on disappear / pop / sheet dismissal.
        .task(id: baseCGIURL) {
            print("[CloudflaredInspectorView] task start base=\(baseCGIURL.absoluteString)")
            await viewModel.refreshOnce()
            viewModel.startPolling(interval: 3.0)

            // If the view disappears, this task is cancelled -> ensure VM stops polling.
            do {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
            } catch { /* ignore */ }

            print("[CloudflaredInspectorView] task cancelled -> stopPolling base=\(baseCGIURL.absoluteString)")
            viewModel.stopPolling()
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: viewModel.tunnelOK ? "checkmark.seal.fill" : "xmark.octagon.fill")
                    .symbolRenderingMode(.hierarchical)

                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.tunnelOK ? "Tunnel Healthy" : "Tunnel Unhealthy")
                        .font(.headline)

                    if viewModel.isLoading {
                        Text("Updating…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if let err = viewModel.tunnelError, !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(err)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    } else {
                        Text("cloudflared_inspector.cgi")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

            if let lastErr = viewModel.lastError, !lastErr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Last Error: \(lastErr)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Status")
        }
    }

    private var tunnelSection: some View {
        Section {
            row("Tunnel Name", value: viewModel.tunnelName ?? "—")
            row("Tunnel ID", value: viewModel.tunnelID ?? "—")
            row("Tunnel Count", value: "\(viewModel.tunnelCount)")
            row("Connector Count", value: "\(viewModel.connectorCount)")
        } header: {
            Text("Tunnel")
        }
    }

    private var urlsSection: some View {
        Section {
            urlRow("Stable URL", value: viewModel.tunnelStableURL)
            urlRow("Temp URL", value: viewModel.dynamicTempURL)
        } header: {
            Text("URLs")
        } footer: {
            Text("Stable URL is what you *want* (hairpi.org). Temp URL is the Cloudflare-generated fallback.")
        }
    }

    private var metaSection: some View {
        Section {
            row("Base CGI", value: baseCGIURL.absoluteString)
            row("Last Updated", value: viewModel.lastUpdated.map { Self.timeFormatter.string(from: $0) } ?? "—")
        } header: {
            Text("Diagnostics")
        }
    }

    private var rawSection: some View {
        Section {
            DisclosureGroup {
                Text(viewModel.lastRawBody)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(nil)
            } label: {
                Text("Raw Response")
            }
        } header: {
            Text("Debug")
        } footer: {
            Text("If the inspector breaks again, this is the body Swift received (decode failures usually mean HTML/log noise or schema drift).")
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func urlRow(_ title: String, value: String?) -> some View {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let v = (trimmed?.isEmpty == false) ? trimmed! : nil

        if let v {
            HStack {
                Text(title)
                Spacer()

                // Normalize into something Link can digest.
                let normalized = v.hasPrefix("http://") || v.hasPrefix("https://") ? v : "https://\(v)"
                if let url = URL(string: normalized) {
                    Link(v, destination: url)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                } else {
                    Text(v)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
            }
            .textSelection(.enabled)
        } else {
            row(title, value: "—")
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()
}
