//
//  RPiVoltStatusView.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 11/2/25.
//


//
//  RPiVoltStatusView.swift
//  SSHSwiftUIDemo
//
//  A compact status widget that polls rpiVolt in real time
//  and color-codes undervoltage conditions.
//  Created by ChatGPT on 2025-11-02.
//

import SwiftUI
import OSLog

public struct RPiVoltStatusView: View {
    public let baseURL: URL
    public var pollInterval: TimeInterval = 1.0

    @State private var volts: Double?
    @State private var lastError: String?
    private let logger = Logger(subsystem: "com.SSHSwiftUIDemo", category: "RPiVoltView")

    public init(baseURL: URL, pollInterval: TimeInterval = 1.0) {
        self.baseURL = baseURL
        self.pollInterval = pollInterval
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.body.weight(.semibold))
                .symbolRenderingMode(.hierarchical)

            Text(labelText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(foreground)
                .contentTransition(.numericText())
                .animation(.snappy, value: volts)
        }
        .padding(.vertical, 4)
        .task(id: baseURL) { await poll() }
        .accessibilityLabel("Core voltage")
        .accessibilityValue(labelText)
        .overlay(alignment: .trailing) {
            if let err = lastError {
                // Tiny error dot with tooltip in debug
                #if DEBUG
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                #endif
            }
        }
    }

    private func poll() async {
        logger.debug("[RPiVoltView] start polling base=\(self.baseURL.absoluteString, privacy: .public)")
        while !Task.isCancelled {
            do {
                let reading = try await RPiVoltService.read(from: baseURL)
                await MainActor.run {
                    self.volts = reading.volts
                    self.lastError = nil
                }
            } catch {
                logger.error("[RPiVoltView] poll error: \(error, privacy: .public)")
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    // keep old volts; show stale value rather than zeroing UI
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    // MARK: - Presentation

    private var iconName: String {
        guard let v = volts else { return "bolt.badge.questionmark" }
        // Flag undervoltage with an exclamation variant if very low
        return v < 0.80 ? "bolt.trianglebadge.exclamationmark" : "bolt.circle"
    }

    private var foreground: Color {
        guard let v = volts else { return .secondary }
        if v < 0.80 { return .red }
        if v < 0.85 { return .orange }
        return .secondary
    }

    private var labelText: String {
        if let v = volts {
            return String(format: "Vcore %.3f V", v)
        } else {
            return "Vcore —"
        }
    }
}