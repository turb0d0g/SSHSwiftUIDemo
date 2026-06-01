//
//  DotStatus.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 8/11/25.
//


//
//  DotStatus.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 8/11/25.
//

import SwiftUI

/// Represents the status of a service (SSH, HTTP, HLS, etc.)
enum DotStatus: Equatable {
    case online
    case offline
    case unknown
    case testing
    case connecting
    
    /// The display color for the status dot.
    var color: Color {
        switch self {
        case .online:
            return .green
        case .offline:
            return .red
        case .unknown:
            return .gray
        case .testing:
            return .blue
        case .connecting:
            return .yellow
        }
    }
    
    /// Optional: Short label for display
    var label: String {
        switch self {
        case .online:
            return "Online"
        case .offline:
            return "Offline"
        case .unknown:
            return "Unknown"
        case .testing:
            return "Testing. . ."
        case .connecting:
            return "Connecting. . ."
        }
    }
}
