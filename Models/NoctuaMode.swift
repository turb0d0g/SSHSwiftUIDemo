//
//  used.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 2/5/26.
//


//  NoctuaMode.swift
//  SSHSwiftUIDemo
//
//  Shared, Sendable mode enum used by snapshots + UI.
//  Swift 6: do NOT reference a nested type inside an @MainActor class from a Sendable model.
//

import Foundation

public enum NoctuaMode: String, CaseIterable, Codable, Sendable {
    case auto
    case manual
}