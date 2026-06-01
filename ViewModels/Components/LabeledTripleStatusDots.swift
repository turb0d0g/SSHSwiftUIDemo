//
//  LabeledTripleStatusDots.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 8/10/25.
//


// Views/Components/LabeledTripleStatusDots.swift
import SwiftUI


/// Three tiny dots (SSH – HLS – HTTP). Pass small `size` (e.g. 8) in nav bars.
struct LabeledTripleStatusDots: View {
    // Stored as DotStatus for rendering
    private let sshDot: DotStatus
    private let hlsDot: DotStatus
    private let httpDot: DotStatus

    var size: CGFloat = 8
    var spacing: CGFloat = 5

    // Designated init for DotStatus
    init(ssh: DotStatus, hls: DotStatus, http: DotStatus, size: CGFloat = 8, spacing: CGFloat = 5) {
        self.sshDot = ssh
        self.hlsDot = hls
        self.httpDot = http
        self.size = size
        self.spacing = spacing
    }

    // Convenience init for DeviceServiceStatus (no DotStatus initializer needed)
    init(ssh: DeviceServiceStatus, hls: DeviceServiceStatus, http: DeviceServiceStatus, size: CGFloat = 8, spacing: CGFloat = 5) {
        self.sshDot = Self.map(ssh)
        self.hlsDot = Self.map(hls)
        self.httpDot = Self.map(http)
        self.size = size
        self.spacing = spacing
    }

    var body: some View {
        HStack(spacing: spacing) {
            StatusDot(status: sshDot,  size: size)
            StatusDot(status: hlsDot,  size: size)
            StatusDot(status: httpDot, size: size)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Statuses: SSH \(Self.label(sshDot)), HLS \(Self.label(hlsDot)), HTTP \(Self.label(httpDot))")
    }

    // MARK: - Mapping helpers

    private static func map(_ s: DeviceServiceStatus) -> DotStatus {
        switch s {
        case .online:  return .online
        case .offline: return .offline
        case .unknown: return .unknown
        case .testing: return .testing
        case .connecting: return .connecting
            
        }
    }

    private static func label(_ s: DotStatus) -> String {
        switch s {
        case .online:  return "online"
        case .offline: return "offline"
        case .unknown: return "unknown"
        case .testing: return "testing"
        case .connecting: return "connecting"
        }
    }
}
