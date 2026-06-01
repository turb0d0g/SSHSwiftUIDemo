//
//  FanRPMView.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 12/17/25.
//
import SwiftUI
import OSLog

/// Sheet UI that polls `/cgi-bin/get_fan_rpm.cgi` and shows health + last-edge age.
struct FanRPMView: View {

    @StateObject private var vm: FanRPMViewModel

    init(baseURL: URL) {
        _vm = StateObject(wrappedValue: FanRPMViewModel(baseURL: baseURL))
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "fanblades.fill")
                        .font(.title2)
                        .foregroundStyle(vm.healthColor)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Tach Health")
                                .font(.headline)
                            Text(vm.healthText)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(vm.healthColor)
                        }

                        if let err = vm.lastError, !err.isEmpty {
                            Text(err)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .lineLimit(3)
                        } else {
                            Text(vm.timestampLine)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()
                }
                .padding(.vertical, 6)
            }

            Section("RPM") {
                labeledRow("RPM (smoothed)", value: vm.rpmString)
                labeledRow("RPM (raw)", value: vm.rpmRawString)
            }

            Section("Health") {
                labeledRow("health", value: vm.healthText, valueColor: vm.healthColor)
                labeledRow("fan_stalled", value: vm.fanStalledString, valueColor: vm.fanStalledColor)
                labeledRow("last_edge_age_sec", value: vm.lastEdgeAgeString, valueColor: vm.lastEdgeAgeColor)
            }

            Section("Debug") {
                labeledRow("tach_pin", value: vm.tachPinString)
                labeledRow("pulses_per_rev", value: vm.pprString)
            }
        }
        .navigationTitle("Fan RPM")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await vm.refreshOnce() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh now")
            }
        }
        .onAppear { vm.startPolling() }
        .onDisappear { vm.stopPolling() }
    }

    @ViewBuilder
    private func labeledRow(_ title: String, value: String, valueColor: Color = .primary) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(valueColor)
        }
    }
} 