//
//  DeviceServiceStatus.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 8/10/25.
//


import SwiftUI

/// Represents a single service's availability state.
enum DeviceServiceStatus {
    case testing
    case connecting
    case unknown
    case online
    case offline

    var color: Color {
        switch self {
        case .unknown: return .gray
        case .online:  return .green
        case .offline: return .red
        case .connecting: return .yellow
        case .testing: return .blue
        }
    }
}

extension DeviceServiceStatus {
    var name: String {
        switch self {
        case .testing:    return "testing"
        case .connecting: return "connecting"
        case .unknown:    return "unknown"
        case .online:     return "online"
        case .offline:    return "offline"
        }
    }
}
