//  DeviceDetailView.swift
//  SSHSwiftUIDemo

//
//  DeviceDetailView.swift
//  SSHSwiftUIDemo
//

import SwiftUI

struct DeviceDetailView: View {
    @EnvironmentObject private var devicesVM: DevicesViewModel
    @EnvironmentObject private var router: NavigationRouter

    let device: Device

    @StateObject private var viewModel: DeviceDetailViewModel

    init(device: Device) {
        self.device = device
        _viewModel = StateObject(
            wrappedValue: DeviceDetailViewModel.placeholder(device: device)
        )
    }

    var body: some View {
        List {
            Section { deviceHeader }

            Section {
                Button { viewModel.openShell() } label: {
                    row(
                        icon: "terminal.fill",
                        title: "SSH Shell",
                        subtitle: "\(viewModel.device.username)@\(viewModel.device.host):\(viewModel.device.port)"
                    )
                }

                Button { viewModel.openMetrics() } label: {
                    row(
                        icon: "gauge.with.dots.needle.67percent",
                        title: "RPI Metrics",
                        subtitle: "System / CPU / Memory / Network"
                    )
                }

                Button {
                    // Let CameraStreamViewModel own stream startup on camera-screen appear.
                    // Do not double-start HLS here.
                    viewModel.openCamera()
                } label: {
                    row(
                        icon: "camera.aperture",
                        title: "Camera (Libcamera)",
                        subtitle: "HLS + snapshot controls"
                    )
                }

                Button { viewModel.openFileManager() } label: {
                    row(
                        icon: "externaldrive",
                        title: "Remote File Manager",
                        subtitle: "/"
                    )
                }

                Button { viewModel.openNoctuaPWM() } label: {
                    row(
                        icon: "fan.desk",
                        title: "Noctua PWM",
                        subtitle: "Control fan duty / auto mode"
                    )
                }

                Button { viewModel.openSixfab() } label: {
                    row(
                        icon: "antenna.radiowaves.left.and.right",
                        title: "Sixfab Hat",
                        subtitle: "4G/LTE HAT controls"
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(viewModel.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                let triple = devicesVM.serviceStatuses[device.id] ?? ServiceTriple()
                LabeledTripleStatusDots(
                    ssh: triple.ssh,
                    hls: triple.hls,
                    http: triple.http,
                    size: 10,
                    spacing: 4
                )
            }
        }
        .onAppear {
            viewModel.attachRouterIfNeeded(router)
            devicesVM.requestRefresh(
                .single(device),
                reason: "DeviceDetailView.onAppear.singleDeviceProbe"
            )
        }
    }

    // MARK: - Header

    private var deviceHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            rowLine("Host", value: device.host)
            rowLine("Port", value: String(device.port))
            rowLine("User", value: device.username)

            if let when = device.lastSeen {
                rowLine(
                    "Last Seen",
                    value: when.formatted(date: .abbreviated, time: .shortened)
                )
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Rows

    private func row(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(.systemGray6))
                    .frame(width: 34, height: 34)

                Image(systemName: icon)
                    .font(.subheadline)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func rowLine(_ key: String, value: String) -> some View {
        HStack {
            Text(key)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.system(.body, design: .monospaced))
        }
    }
}
