//
//  HLSPlayerView.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 10/17/25.
//


import SwiftUI
import AVFoundation

struct HLSPlayerView: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> PlayerContainer {
        let v = PlayerContainer()
        v.playerLayer.videoGravity = .resizeAspectFill
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: PlayerContainer, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.setNeedsDisplay()
    }
}

final class PlayerContainer: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
