//
//  MemoryHUDProviderShim.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 12/30/25.
//


import Foundation

public final class MemoryHUDProviderShim: AnyMemoryHUDProviding {
    private let getFootprintMB: () -> Double
    private let getResidentMB: () -> Double
    private let getDeltaMB: () -> Double
    private let getSlope: () -> Double
    private let getStatus: () -> String

    public init(
        footprintMB: @escaping () -> Double,
        residentMB: @escaping () -> Double,
        deltaMB: @escaping () -> Double,
        slopeMBPerMin: @escaping () -> Double,
        statusText: @escaping () -> String
    ) {
        self.getFootprintMB = footprintMB
        self.getResidentMB = residentMB
        self.getDeltaMB = deltaMB
        self.getSlope = slopeMBPerMin
        self.getStatus = statusText
    }

    public var footprintMB: Double { getFootprintMB() }
    public var residentMB: Double { getResidentMB() }
    public var deltaMB: Double { getDeltaMB() }
    public var slopeMBPerMin: Double { getSlope() }
    public var statusText: String { getStatus() }
}