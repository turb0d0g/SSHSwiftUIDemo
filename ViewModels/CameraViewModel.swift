//
//  CameraViewModel.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 10/07/25.
//

import AVFoundation
import Photos
import SwiftUI
import OSLog
import UniformTypeIdentifiers

@MainActor
final class CameraViewModel: NSObject, ObservableObject {
    enum Mode { case photo, video }

    enum StatusLevel {
        case info, success, warning, error
    }

    struct StatusMessage: Equatable {
        let text: String
        let level: StatusLevel
    }

    let session = AVCaptureSession()
    private let log = Logger(subsystem: "SSHSwiftUIDemo", category: "CameraVM")
    
    @Published var statusBanner: String? = nil

    private var photoOutput = AVCapturePhotoOutput()
    private var movieOutput: AVCaptureMovieFileOutput?
    private var deviceInput: AVCaptureDeviceInput?

    @Published var isFlashOn = false
    @Published var isRecording = false
    @Published var lastSavedFilename: String?
    @Published var lastPhotosIdentifier: String?

    // Recording timer
    @Published var recordingElapsed: TimeInterval = 0 // seconds
    private var recordingStart: Date?
    private var recordingTicker: Task<Void, Never>?
    private var recordStartDate: Date?
    private let photoLibrary = PhotoLibraryService()

    // Status HUD
    @Published var status: StatusMessage?
    private var statusClearTask: Task<Void, Never>?

    private var currentMode: Mode = .photo

    // MARK: - Lifecycle

    func startSession() async {
        session.beginConfiguration()
        session.sessionPreset = .high
        defer { session.commitConfiguration() }

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: .back) else {
            log.error("❌ No available camera.")
            postStatus("No available camera", level: .error)
            return
        }

        do {
            let mo = AVCaptureMovieFileOutput()
            if session.canAddOutput(mo) {
                session.addOutput(mo)
                self.movieOutput = mo
                log.debug("[CameraVM] Added AVCaptureMovieFileOutput")
            } else {
                log.error("[CameraVM] Cannot add AVCaptureMovieFileOutput")
                self.movieOutput = nil
            }
            if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
            if session.canAddOutput(movieOutput!) { session.addOutput(movieOutput!) }

            log.info("✅ Session configured (inputs/outputs added).")
        } catch {
            log.error("❌ Setup failed: \(String(describing: error), privacy: .public)")
            postStatus("Camera setup failed", level: .error)
        }

        session.startRunning()
        log.info("▶️ Session started.")
    }

    func stopSession() {
        session.stopRunning()
        log.info("⏹️ Session stopped.")
    }

    // MARK: - Mode / UI

    func setMode(_ newMode: Mode) {
        currentMode = newMode
        log.debug("Mode → \(String(describing: newMode), privacy: .public)")
        switch newMode {
        case .photo:
            postStatus("Photo mode", level: .info, autoClearAfter: 1.5)
        case .video:
            // show idle timer 00:00 under shutter; HUD shows mode switch briefly
            postStatus("Video mode", level: .info, autoClearAfter: 1.5)
        }
    }

    func toggleFlash() { isFlashOn.toggle() }

    func captureAction() {
        switch currentMode {
        case .photo: capturePhoto()
        case .video: isRecording ? stopRecording() : startRecording()
        }
    }

    // MARK: - Photo

    private func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        settings.flashMode = isFlashOn ? .on : .off
        log.info("📸 Capturing photo (flash=\(self.isFlashOn))")

        photoOutput.capturePhoto(with: settings, delegate: PhotoDelegate { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let data):
                    do {
                        let filename = MediaSaver.uniqueImageFilename()
                        let (docURL, phID) = try await MediaSaver.saveJPEGToDocumentsAndPhotos(data, filename: filename)
                        self.lastSavedFilename = docURL.lastPathComponent
                        self.lastPhotosIdentifier = phID
                        self.log.info("✅ Photo saved filename=\(filename, privacy: .public) phID=\(phID, privacy: .public)")
                        self.postStatus("Saved: \(filename)", level: .success)
                    } catch {
                        self.log.error("❌ Saving photo failed: \(String(describing: error), privacy: .public)")
                        self.postStatus("Save failed (photo)", level: .error)
                    }
                case .failure(let err):
                    self.log.error("❌ Capture photo failed: \(String(describing: err), privacy: .public)")
                    self.postStatus("Capture failed (photo)", level: .error)
                }
            }
        })
    }

    // MARK: - Video

    func startRecording() {
        guard let movieOutput = movieOutput else {
            log.error("[CameraVM] startRecording: movieOutput is nil")
            showBanner("Camera not ready")
            return
        }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        recordStartDate = Date()
        movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true

        log.debug("[CameraVM] 🎥 start → \(url.path)")
    }

    func stopRecording() {
        guard let movieOutput = movieOutput else {
            log.error("[CameraVM] stopRecording: movieOutput is nil")
            return
        }
        movieOutput.stopRecording()
        log.debug("[CameraVM] ⏹️ stop requested")
    }

    // MARK: - Camera

    func switchCamera() {
        guard let currentInput = deviceInput else { return }
        session.beginConfiguration()
        session.removeInput(currentInput)

        let newPosition: AVCaptureDevice.Position = (currentInput.device.position == .back) ? .front : .back

        if let newCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition) {
            do {
                let newInput = try AVCaptureDeviceInput(device: newCamera)
                if session.canAddInput(newInput) {
                    session.addInput(newInput)
                    deviceInput = newInput
                } else {
                    log.error("❌ Cannot add new camera input.")
                    postStatus("Camera switch failed", level: .error)
                }
            } catch {
                log.error("❌ Camera switch failed: \(String(describing: error), privacy: .public)")
                postStatus("Camera switch failed", level: .error)
            }
        }

        session.commitConfiguration()
        log.info("🔁 Camera switched → \(newPosition == .back ? "rear" : "front")")
    }

    func openFilters() { log.debug("🎨 Filters tapped (not implemented).") }

    // MARK: - Status HUD

    func postStatus(_ text: String, level: StatusLevel, autoClearAfter seconds: TimeInterval? = 2.5) {
        status = .init(text: text, level: level)

        statusClearTask?.cancel()
        if let seconds {
            statusClearTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                await MainActor.run { self?.status = nil }
            }
        } else {
            statusClearTask = nil
        }
    }
    
    private func showBanner(_ text: String) {
        statusBanner = text
        // auto-hide after 2.5s
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { self?.statusBanner = nil }
        }
    }

    private func formattedDuration(since start: Date?) -> String? {
        guard let start else { return nil }
        let s = Int(Date().timeIntervalSince(start).rounded(.down))
        let mm = s / 60
        let ss = s % 60
        return String(format: "%02d:%02d", mm, ss)
    }

        // MAR
}

// MARK: - AVCapturePhotoCaptureDelegate wrapper

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    enum Result { case success(Data); case failure(Error) }
    private let handler: (Result) -> Void

    init(handler: @escaping (Result) -> Void) { self.handler = handler }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error = error {
            handler(.failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            handler(.failure(MediaSaverError.writeFailed("No JPEG data.")))
            return
        }
        handler(.success(data))
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraViewModel: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        log.debug("▶️ Recording started temp=\(fileURL.path, privacy: .public)")
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                        didFinishRecordingTo outputFileURL: URL,
                        from connections: [AVCaptureConnection],
                    error: Error?) {
        
        isRecording = false
        
        if let error {
            log.error("[CameraVM] ❌ recording error: \(error.localizedDescription)")
            showBanner("Save failed: \(error.localizedDescription)")
            return
        }
        
        let durationText = formattedDuration(since: recordStartDate)
        Task {
            do {
                let result = try await photoLibrary.saveVideo(from: outputFileURL,
                                                              filename: outputFileURL.lastPathComponent)
                // UI banner with filename + duration
                showBanner("Recording saved: \(result.filename)\(durationText.map { " (\($0))" } ?? "")")
            } catch {
                self.log.error("[CameraVM] ❌ save error: \(error.localizedDescription)")
                self.showBanner("Save failed: \(error.localizedDescription)")
            }
        }
    }
}
