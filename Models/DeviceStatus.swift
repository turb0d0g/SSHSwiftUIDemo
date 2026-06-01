//
//  DeviceStatus.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 7/29/25.
//


// Models/DeviceStatus.swift
import Foundation

/// Logical connection state for a saved device (separate from UI rendering).
public enum DeviceStatus: String, Codable, Equatable {
    case unknown
    case testing
    case connecting
    case online
    case offline
}