//
//  NavigationRouter.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 7/26/25.
//

//
//  NavigationRouter.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 7/26/25.
//

import SwiftUI

/// Central navigation hub used across the app.
///
/// ✅ @MainActor ensures all NavigationPath mutations are serialized on the main thread.
/// This prevents subtle SwiftUI retention / state weirdness and occasional path corruption.
@MainActor
final class NavigationRouter: ObservableObject {

    enum Route: Hashable {
        case deviceDetail(Device)
        case terminal(Device)
        case metrics(Device)
        case camera(Device)
        case remoteFileManager(Device)
        case noctuaPWM(Device)
        case sixfab(Device)
        case addDevice
    }

    @Published var path = NavigationPath()

    // MARK: - Push helpers
    func goToDeviceDetail(_ device: Device)     { path.append(Route.deviceDetail(device)) }
    func goToTerminal(_ device: Device)         { path.append(Route.terminal(device)) }
    func goToMetrics(_ device: Device)          { path.append(Route.metrics(device)) }
    func goToCamera(_ device: Device)           { path.append(Route.camera(device)) }
    func goToRemoteFileManager(_ device: Device){ path.append(Route.remoteFileManager(device)) }
    func goToNoctuaPWM(_ device: Device)        { path.append(Route.noctuaPWM(device)) }
    func goToSixfab(_ device: Device)           { path.append(Route.sixfab(device)) }
    func goToAddDevice()                        { path.append(Route.addDevice) }

    // MARK: - Pop helpers (crash-proof)
    func pop() {
        guard path.count > 0 else {
            print("[Router][WARN] pop() ignored (path empty)")
            return
        }
        path.removeLast()
    }

    func popToRoot() {
        guard path.count > 0 else {
            print("[Router][WARN] popToRoot() ignored (path empty)")
            return
        }
        path.removeLast(path.count)
    }
}
