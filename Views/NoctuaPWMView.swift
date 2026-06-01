//
//  NoctuaPWMView.swift
//  SSHSwiftUIDemo
//

//
//  NoctuaPWMView.swift
//  SSHSwiftUIDemo
//

import SwiftUI
import UIKit   // Only for UIPasteboard in JSON sheet. Remove if you want zero UIKit.

public struct NoctuaPWMView: View {
    @StateObject private var vm: NoctuaPWMViewModel
    private let device: Device
    private let title: String

    // Triple-tap title → show snapshot JSON
    @State private var showSnapshotSheet = false
    @State private var navTitleTapCount = 0
    @State private var navTitleLastTap = Date.distantPast

    init(device: Device, title: String) {
        self.device = device
        self.title = title
        _vm = StateObject(wrappedValue: NoctuaPWMViewModel(device: device))
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                metrics
                modeCard
                if vm.mode == .manual { manualCard }
                actionRow
                if let err = vm.lastError { errorLine(err) }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(title)
                    .font(.headline)
                    .contentShape(Rectangle())
                    .onTapGesture { handleTitleTap() }
                    .accessibilityLabel(Text("\(title). Triple tap to show snapshot JSON"))
            }

            // iOS 16-compatible placement
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await vm.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(vm.isBusy)
                .accessibilityLabel("Refresh")
            }
        }
        .sheet(isPresented: $showSnapshotSheet) {
            NavigationStack {
                ScrollView {
                    Text(vm.latestSnapshotJSON)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("Noctua Snapshot")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Done") { showSnapshotSheet = false }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Copy") {
                            UIPasteboard.general.string = vm.latestSnapshotJSON
                        }
                    }
                }
                .onAppear {
                    vm.updateSnapshotJSONNow()
                }
            }
        }
        .onAppear {
            vm.startPolling(every: 3.0)
        }
        .onDisappear {
            vm.stopPolling()
        }
        // onChange signature differs
        .modifier(SheetChangeHack(isPresented: $showSnapshotSheet) {
            vm.updateSnapshotJSONNow()
        })
    }

    // MARK: - Triple-tap handler

    private func handleTitleTap() {
        let now = Date()
        if now.timeIntervalSince(navTitleLastTap) > 0.6 { navTitleTapCount = 0 }
        navTitleLastTap = now
        navTitleTapCount += 1

        if navTitleTapCount >= 3 {
            navTitleTapCount = 0
            vm.updateSnapshotJSONNow()
            showSnapshotSheet = true
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "fan.desk")
                .imageScale(.large)

            VStack(alignment: .leading, spacing: 2) {
                Text("Fan Controller").font(.headline)
                Text("Actor stream telemetry").font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if vm.isBusy {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var metrics: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                labeledMetric("RPM", value: "\(vm.rpm)")
                labeledMetric("Temp", value: vm.temperatureC.isNaN ? "—" : String(format: "%.2f℃", vm.temperatureC))
                labeledMetric("Core V", value: vm.voltageV.isNaN ? "—" : String(format: "%.3fV", vm.voltageV))
            }
            powerHealthRow
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var powerHealthRow: some View {
        let (color, text) = powerHealthState
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var powerHealthState: (Color, String) {
        if vm.undervoltNow { return (.red, "Power: Undervoltage NOW") }
        if vm.undervoltHistory { return (.yellow, "Power: Undervoltage history") }
        return (.green, "Power: OK (no undervoltage)")
    }

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mode").font(.headline)

            Picker(
                "Mode",
                selection: Binding(
                    get: { vm.mode },
                    set: { new in
                        Task {
                            switch new {
                            case .auto:
                                await vm.setAuto()
                            case .manual:
                                await vm.setManual(duty: vm.manualDuty)
                            }
                        }
                    }
                )
            ) {
                Text("Auto").tag(NoctuaPWMViewModel.Mode.auto)
                Text("Manual").tag(NoctuaPWMViewModel.Mode.manual)
            }
            .pickerStyle(.segmented)
            .disabled(vm.isBusy)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var manualCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Manual Duty").font(.headline)
                Spacer()
                Text("\(vm.manualDuty)%").font(.headline.monospacedDigit())
            }

            Slider(
                value: Binding(
                    get: { Double(vm.manualDuty) },
                    set: { vm.manualDuty = Int($0.rounded()) }
                ),
                in: 0...100,
                step: 1
            )
            .disabled(vm.isBusy)

            HStack(spacing: 12) {
                Button { Task { await vm.nudge(-5) } } label: {
                    Label("–5%", systemImage: "minus.circle")
                }
                .buttonStyle(.bordered)
                .disabled(vm.isBusy)

                Button { Task { await vm.setManual(duty: vm.manualDuty) } } label: {
                    Label("Apply", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isBusy)

                Button { Task { await vm.nudge(+5) } } label: {
                    Label("+5%", systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)
                .disabled(vm.isBusy)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) { Task { await vm.stopFan() } } label: {
                Label("Stop", systemImage: "stop.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            Button { Task { await vm.refreshAll() } } label: {
                Label("Probe", systemImage: "waveform.path.ecg")
            }
            .buttonStyle(.bordered)
            .disabled(vm.isBusy)

            Spacer(minLength: 0)
        }
    }

    private func labeledMetric(_ title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func errorLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(text).font(.footnote)
            Spacer()
        }
        .padding(10)
        .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - iOS16-compatible onChange wrapper
private struct SheetChangeHack: ViewModifier {
    @Binding var isPresented: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.onChange(of: isPresented) { _, newValue in
                if newValue { action() }
            }
        } else {
            content.onChange(of: isPresented) { newValue in
                if newValue { action() }
            }
        }
    }
}
