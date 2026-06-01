import Foundation

public struct CameraStreamConfig: Sendable, Equatable, Codable {
    public enum Resolution: String, Sendable, Codable { case hd, k4 }
    public enum DynamicRange: String, Sendable, Codable { case log, hdr }

    public var resolution: Resolution
    public var fps: Int
    public var dynamicRange: DynamicRange
    public var proRes: Bool

    public init(
        resolution: Resolution = .hd,
        fps: Int = 30,
        dynamicRange: DynamicRange = .log,
        proRes: Bool = false
    ) {
        self.resolution = resolution
        self.fps = fps
        self.dynamicRange = dynamicRange
        self.proRes = proRes
    }

    /// Your “safe” baseline profile.
    public static let `default` = CameraStreamConfig()

    /// Convenience presets (optional)
    public static let hd30 = CameraStreamConfig(resolution: .hd, fps: 30, dynamicRange: .log, proRes: false)
    public static let hd60 = CameraStreamConfig(resolution: .hd, fps: 60, dynamicRange: .log, proRes: false)
    public static let k4_30 = CameraStreamConfig(resolution: .k4, fps: 30, dynamicRange: .log, proRes: false)
    public static let k4_60 = CameraStreamConfig(resolution: .k4, fps: 60, dynamicRange: .log, proRes: false)
}

public extension CameraStreamConfig.Resolution {
    /// Matches your Pi script: `res=hd|4k`
    var cgiValue: String { self == .k4 ? "4k" : "hd" }
}
