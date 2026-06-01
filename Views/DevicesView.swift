//
//  DevicesView.swift
//  SSHSwiftUIDemo
//

//
//  DevicesView.swift
//  SSHSwiftUIDemo
//

import SwiftUI
import OSLog

private let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "DevicesView")

struct DevicesView: View {
    @Environment(\.scenePhase) private var scenePhase

    // ✅ injected from SSHSwiftUIDemoApp
    @EnvironmentObject private var router: NavigationRouter
    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var vm: DevicesViewModel

    @State private var didRunInitialProbe = false

    // Scroll-reactive glass state
    @State private var scrollMinY: CGFloat = 0

    var body: some View {
        ZStack {
            GlassScreenBackground()

            Group {
                if vm.devices.isEmpty {
                    emptyState
                } else {
                    devicesList
                }
            }
        }
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.large)

        // Base glass on the actual navigation bar
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)

        // Scroll-reactive “thickening” glass layer
        .safeAreaInset(edge: .top, spacing: 0) {
            ScrollReactiveNavGlass(progress: navGlassProgress(from: scrollMinY))
        }

        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.goToAddDevice()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }

        // --- Triggers ---------------------------------------------------------
        .task {
            guard !didRunInitialProbe else { return }
            didRunInitialProbe = true
            log.info("[DevicesView] Initial task -> requestRefresh(all)")
            vm.requestRefresh(.all, reason: "DevicesView.initialTask")
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            log.info("[DevicesView] scenePhase=.active -> requestRefresh(all)")
            vm.requestRefresh(.all, reason: "DevicesView.scenePhase.active")
        }
        .task(id: vm.devices.map(\.id)) {
            log.info("[DevicesView] devices changed -> requestRefresh(all)")
            vm.requestRefresh(.all, reason: "DevicesView.devicesChanged")
        }
    }

    private var devicesList: some View {
        List {
            // Offset probe sentinel (top of list)
            ScrollOffsetSentinel()

            ForEach(vm.devices) { device in
                row(device)
                    .id(device.id)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowBackground(Color.clear)
            }
            .onDelete(perform: vm.delete)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .coordinateSpace(name: "devices.scroll")
        .onPreferenceChange(ScrollMinYKey.self) { newValue in
            scrollMinY = newValue
        }
        .refreshable {
            log.info("[DevicesView] Pull-to-refresh -> requestRefresh(all)")
            vm.requestRefresh(.all, reason: "DevicesView.pullToRefresh")
        }
    }

    // MARK: - Row
    @ViewBuilder
    private func row(_ d: Device) -> some View {
        let triple = vm.serviceStatuses[d.id] ?? ServiceTriple()

        LiquidGlassRow {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.name.isEmpty ? d.host : d.name)
                        .font(.headline)

                    Text("\(d.username)@\(d.host):\(d.port)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                LabeledTripleStatusDots(
                    ssh:  triple.ssh,
                    hls:  triple.hls,
                    http: triple.http,
                    size: 8,
                    spacing: 5
                )

                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .onTapGesture {
            // ✅ push using the ONE router instance bound to NavigationStack(path:)
            router.goToDeviceDetail(d)
        }
        .contextMenu {
            Button {
                vm.requestRefresh(.single(d), reason: "DevicesView.contextMenu.probeSingle")
            } label: {
                Label("Probe Now", systemImage: "dot.radiowaves.left.and.right")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                if let idx = vm.devices.firstIndex(of: d) {
                    vm.delete(at: IndexSet(integer: idx))
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(d.name.isEmpty ? d.host : d.name) status")
    }

    // MARK: - Empty state
    private var emptyState: some View {
        LiquidGlass {
            VStack(spacing: 16) {
                Image(systemName: "wifi.router")
                    .font(.system(size: 44, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)

                Text("No Devices")
                    .font(.headline)

                Text("Tap the plus to add a device. I’ll probe it the second it lands here.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)

                Button {
                    router.goToAddDevice()
                } label: {
                    Label("Add Device", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    // MARK: - Progress mapping
    private func navGlassProgress(from minY: CGFloat) -> CGFloat {
        let dy = max(0, -minY)
        let maxDy: CGFloat = 90
        return min(1, dy / maxDy)
    }
}

// MARK: - LiquidGlass row wrapper
private struct LiquidGlassRow<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        LiquidGlass {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .shadow(radius: 10, y: 6)
    }
}

// MARK: - Background
private struct GlassScreenBackground: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    Color.primary.opacity(0.06),
                    Color.clear,
                    Color.primary.opacity(0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Scroll offset plumbing
private enum ScrollMinYKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// A zero-height row at the top of the List that reports its minY in our named coordinate space.
private struct ScrollOffsetSentinel: View {
    var body: some View {
        Color.clear
            .frame(height: 0)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ScrollMinYKey.self,
                        value: proxy.frame(in: .named("devices.scroll")).minY
                    )
                }
            }
    }
}

// MARK: - Scroll-reactive navbar glass
private struct ScrollReactiveNavGlass: View {
    /// 0...1
    let progress: CGFloat

    var body: some View {
        let base: CGFloat = 0
        let extra: CGFloat = 22 * progress

        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.70 + 0.25 * progress)

            Rectangle()
                .fill(.thinMaterial)
                .opacity(0.10 + 0.35 * progress)

            LinearGradient(
                colors: [
                    .white.opacity(0.00),
                    .white.opacity(0.18 * progress),
                    .white.opacity(0.00)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .blendMode(.screen)
            .offset(x: 60 * progress)

            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(.white.opacity(0.18 * progress))
        }
        .frame(height: base + extra)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }
}
