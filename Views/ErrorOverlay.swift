//
//  ErrorOverlay.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 7/25/25.
//


// Views/ErrorOverlay.swift
import SwiftUI

struct ErrorOverlay: View {
    let error: Error
    let retryAction: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            Text("Connection Failed")
                .font(.headline)
                .border(Color.red)
            Text(error.localizedDescription)
                .font(.caption)
                .multilineTextAlignment(.center)
                .border(Color.red)
            Button("Retry", action: retryAction)
                .border(Color.red)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .transition(.opacity.combined(with: .scale))
        .border(Color.red)
    }
}
