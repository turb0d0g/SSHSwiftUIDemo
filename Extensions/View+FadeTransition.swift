//
//  View+FadeTransistion.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 7/25/25.
//

// Extensions/View+FadeTransition.swift
import SwiftUI

extension View {
    /// One-liner to wrap Core Animation fade.
    func fadeTransition() -> some View {
        self.transition(.opacity.animation(.easeInOut(duration: 0.25)))
    }
}
