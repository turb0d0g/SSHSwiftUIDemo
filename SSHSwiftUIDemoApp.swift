//
//  SSHSwiftUIDemoApp.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 7/25/25.
//

import SwiftUI

@main
struct SSHSwiftUIDemoApp: App {

    @StateObject private var router: NavigationRouter
    @StateObject private var store: DeviceStore
    @StateObject private var devicesVM: DevicesViewModel
    @StateObject private var memoryHUD: MemoryHUDViewModel

    @AppStorage("hud.visible") private var hudVisible: Bool = true

    init() {
        let routerInstance = NavigationRouter()
        let storeInstance  = DeviceStore()
        let devicesVMInst  = DevicesViewModel(router: routerInstance, store: storeInstance)

        let hudInstance = MemoryHUDViewModel(
            warnDeltaMB: 25,
            errorDeltaMB: 75,
            warnSlopeMBPerMin: 20,
            errorSlopeMBPerMin: 50
        )

        _router    = StateObject(wrappedValue: routerInstance)
        _store     = StateObject(wrappedValue: storeInstance)
        _devicesVM = StateObject(wrappedValue: devicesVMInst)
        _memoryHUD = StateObject(wrappedValue: hudInstance)

        print("[AppInit] routerOID=\(ObjectIdentifier(routerInstance)) storeOID=\(ObjectIdentifier(storeInstance)) devicesVMOID=\(ObjectIdentifier(devicesVMInst)) hudOID=\(ObjectIdentifier(hudInstance))")

        // Load devices once
        Task {
            print("[AppInit] store.load() begin")
            await storeInstance.load()
            print("[AppInit] store.load() done")
        }

        // Start profiler + attach HUD once
        Task {
            print("[AppInit] MemoryProfiler configure/start begin")

            var cfg = MemoryProfilerConfig()
            cfg.interval = .seconds(1)
            cfg.ringBufferCapacity = 180
            cfg.warnDeltaMB = 25
            cfg.errorDeltaMB = 75
            cfg.verbosePrintEachSample = false

            await MemoryProfiler.shared.configure(cfg)
            await MemoryProfiler.shared.start(reason: "App init")

            let stream = await MemoryProfiler.shared.subscribe(reason: "MemoryHUD")
            await hudInstance.attach(to: stream, reason: "App init attach")

            print("[AppInit] MemoryProfiler configure/start done")
        }

        // Pin globals + start leak-watch once
        Task {
            print("[AppInit] ARCTracker pin + leak watch start")

            await ARCTracker.shared.pin(routerInstance, note: "NavigationRouter (app lifetime)")
            await ARCTracker.shared.pin(storeInstance,  note: "DeviceStore (app lifetime)")
            await ARCTracker.shared.pin(devicesVMInst,  note: "DevicesViewModel (app lifetime)")
            await ARCTracker.shared.pin(hudInstance,    note: "MemoryHUDViewModel (app lifetime)")

            await ARCTracker.shared.startLeakWatch(intervalSeconds: 2, suspectAfterSeconds: 8, warnOnPinnedGrowth: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                NavigationStack(path: $router.path) {
                    DevicesView()
                        .navigationDestination(for: NavigationRouter.Route.self) { route in
                            switch route {
                            case .deviceDetail(let device):
                                DeviceDetailView(device: device)

                            case .terminal(let device):
                                TerminalScreen(device: device)

                            case .sixfab(let device):
                                SixfabView(device: device, title: "4G / LTE")

                            case .metrics(let device):
                                RPIMetricsView(device: device)

                            case .camera(let device):
                                CameraView(device: device)

                            case .remoteFileManager(let device):
                                FileManagerRouteView(device: device)

                            case .noctuaPWM(let device):
                                NoctuaPWMView(
                                    device: device,
                                    title: "Noctua PWM – \(device.name.isEmpty ? device.host : device.name)"
                                )

                            case .addDevice:
                                AddDeviceView(store: store)
                            }
                        }
                }
                .environmentObject(router)
                .environmentObject(store)
                .environmentObject(devicesVM)

                if hudVisible {
                    UnifiedDiagnosticsHUDOverlay(memoryHUD: memoryHUD)
                        .zIndex(9_000)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !hudVisible {
                    Button {
                        hudVisible = true
                        print("[AppRoot] HUD revive button → hud.visible=true")
                    } label: {
                        Label("HUD", systemImage: "waveform.path.ecg")
                            .labelStyle(.titleAndIcon)
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 14)
                    .padding(.top, 12)
                    .zIndex(10_000)
                    .transition(.opacity)
                }
            }
            .simultaneousGesture(
                TapGesture(count: 3).onEnded {
                    guard !hudVisible else { return }
                    hudVisible = true
                    print("[AppRoot] triple-tap → hud.visible=true")
                }
            )
        }
    }
}
