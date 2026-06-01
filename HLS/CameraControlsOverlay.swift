//
//  CameraControlsOverlay.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 10/17/25.
//


//
//  CameraControlsOverlay.swift
//  SSHSwiftUIDemo
//

import SwiftUI

struct CameraControlsOverlay: View {
    // Use the VM’s Mode type (fixes “Cannot find type 'CameraMode' in scope”)
    @Binding var mode: CameraViewModel.Mode
    let isRecording: Bool
    let elapsed: TimeInterval

    var onCapture: () -> Void
    var onSwitchCamera: () -> Void
    var onThumbnailTap: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            // Mode selector
            HStack(spacing: 28) {
                ModePill(title: "PHOTO", isActive: mode == .photo)
                    .onTapGesture { mode = .photo }
                ModePill(title: "VIDEO", isActive: mode == .video)
                    .onTapGesture { mode = .video }
            }
            .padding(.top, 6)

            // Shutter row (+ mirrored timer under shutter)
            HStack {
                Button { onThumbnailTap?() } label: {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title2)
                }

                Spacer()

                VStack(spacing: 6) {
                    Button { onCapture() } label: {
                        ShutterButton(kind: mode == .photo
                                      ? .photo
                                      : (isRecording ? .videoStop : .videoStart))
                    }
                    .accessibilityLabel(accessibilityLabelFor(mode: mode,
                                                              isRecording: isRecording))

                    if mode == .video {
                        RecordingTimer(isRecording: isRecording, elapsed: elapsed)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }

                Spacer()

                Button { onSwitchCamera() } label: {
                    Image(systemName: "camera.rotate")
                        .font(.title2)
                }
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 6)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .foregroundStyle(.white)
    }
}

// MARK: - Timer under shutter (with blinking dot)

private struct RecordingTimer: View {
    let isRecording: Bool
    let elapsed: TimeInterval

    // Blink at 2 Hz (leverages VM’s 0.5s ticker)
    private var blinkOn: Bool { (Int(elapsed * 2) % 2) == 0 }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isRecording ? Color.red : Color.gray)
                .frame(width: 6, height: 6)
                .opacity(isRecording ? (blinkOn ? 1.0 : 0.25) : 0.45)

            Text(format(elapsed))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(isRecording ? .red : .gray)
                .opacity(isRecording ? 1.0 : 0.75)
        }
        .animation(.linear(duration: 0.25), value: blinkOn)
    }

    private func format(_ t: TimeInterval) -> String {
        let total = Int(t.rounded(.down))
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Shutter visuals

private enum ShutterKind { case photo, videoStart, videoStop }

private struct ShutterButton: View {
    let kind: ShutterKind

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(.white, lineWidth: 5)
                .frame(width: 86, height: 86)

            switch kind {
            case .photo:
                Circle()
                    .fill(.white.opacity(0.95))
                    .frame(width: 72, height: 72)

            case .videoStart:
                Circle()
                    .fill(Color.red)
                    .frame(width: 64, height: 64)

            case .videoStop:
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.red)
                    .frame(width: 54, height: 54)
            }
        }
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.18), value: kindHash)
    }

    private var kindHash: Int {
        switch kind {
        case .photo: return 0
        case .videoStart: return 1
        case .videoStop: return 2
        }
    }
}

private struct ModePill: View {
    let title: String
    let isActive: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(isActive ? .white : .gray)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isActive ? .white.opacity(0.12) : .clear)
            )
    }
}

private func accessibilityLabelFor(mode: CameraViewModel.Mode, isRecording: Bool) -> String {
    switch mode {
    case .photo: return "Shutter"
    case .video: return isRecording ? "Stop Recording" : "Start Recording"
    }
}

// MARK: - Preview

#Preview {
    @State var mode: CameraViewModel.Mode = .photo
    return ZStack {
        Color.black.ignoresSafeArea()
        CameraControlsOverlay(
            mode: $mode,
            isRecording: false,
            elapsed: 0,
            onCapture: {},
            onSwitchCamera: {},
            onThumbnailTap: {}
        )
    }
}
