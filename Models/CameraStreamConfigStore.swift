//
//  CameraStreamConfigStore.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 12/24/25.
//


//
//  CameraStreamConfigStore.swift
//  SSHSwiftUIDemo
//
//  Simple per-host config persistence (UserDefaults).
//

import Foundation
import OSLog

@MainActor
public final class CameraStreamConfigStore: ObservableObject {
    private let log = Logger(subsystem: "SSHSwiftUIDemo", category: "CameraStreamConfigStore")
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(for host: String) -> String { "camera.stream.config.\(host)" }

    public func load(host: String) -> CameraStreamConfig {
        let k = key(for: host)
        guard let data = defaults.data(forKey: k) else {
            log.debug("[ConfigStore] load host=\(host, privacy: .public) -> default")
            return CameraStreamConfig()
        }
        do {
            let cfg = try JSONDecoder().decode(CameraStreamConfig.self, from: data)
            log.debug("[ConfigStore] load host=\(host, privacy: .public) -> \(String(describing: cfg), privacy: .public)")
            return cfg
        } catch {
            log.error("[ConfigStore] load decode failed host=\(host, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return CameraStreamConfig()
        }
    }

    public func save(_ config: CameraStreamConfig, host: String) {
        let k = key(for: host)
        do {
            let data = try JSONEncoder().encode(config)
            defaults.set(data, forKey: k)
            log.debug("[ConfigStore] save host=\(host, privacy: .public) prores=\(config.proRes) dyn=\(config.dynamicRange.rawValue, privacy: .public) res=\(config.resolution.rawValue, privacy: .public) fps=\(config.fps)")
        } catch {
            log.error("[ConfigStore] save encode failed host=\(host, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
