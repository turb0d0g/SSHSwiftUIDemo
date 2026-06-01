//
//  PhotoLibraryService.swift
//  SSHSwiftUIDemo
//
//  Updated: 2025-10-24 — returns filename + hardened video save path
//

import Foundation
import Photos
import OSLog

@MainActor
public final class PhotoLibraryService {

    // MARK: - Types

    public struct SaveResult: Sendable {
        public let filename: String
        public init(filename: String) { self.filename = filename }
    }

    // MARK: - Errors

    public enum PLSError: LocalizedError {
        case unauthorized(PHAuthorizationStatus)
        case creationFailed(String)
        case invalidImageData
        case fileStageFailed(String)
        case fileMissing(String)

        public var errorDescription: String? {
            switch self {
            case .unauthorized(let st):    return "Photos authorization denied: \(st.rawValue)"
            case .creationFailed(let msg): return "Photos creation failed: \(msg)"
            case .invalidImageData:        return "Data is not a valid image."
            case .fileStageFailed(let m):  return "Failed to stage file: \(m)"
            case .fileMissing(let p):      return "Recorded file missing at \(p)"
            }
        }
    }

    // MARK: - Logger

    private let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "PhotoLibrary")

    // MARK: - Public API

    /// Save raw image bytes to Photos. Returns the printable filename used.
    public func saveImage(data: Data, filename: String? = nil) async throws -> SaveResult {
        log.debug("[PLS] Saving photo…")
        _ = try await ensureAuthorization()

        guard !data.isEmpty else { throw PLSError.invalidImageData }
        let safeName = filename ?? Self.timestampedFilename(prefix: "photo", ext: "jpg")

        let result: SaveResult = try await withCheckedThrowingContinuation { cont in
            PHPhotoLibrary.shared().performChanges({
                let req  = PHAssetCreationRequest.forAsset()
                let opts = PHAssetResourceCreationOptions()
                req.addResource(with: .photo, data: data, options: opts)
            }, completionHandler: { ok, err in
                if ok {
                    self.log.info("[PLS] 📸 Photo saved → \(safeName)")
                    print("[PLS] 📸 Photo saved → \(safeName)")
                    cont.resume(returning: SaveResult(filename: safeName))
                } else {
                    let msg = (err as NSError?)?.localizedDescription ?? "unknown error"
                    self.log.error("[PLS] Photo save failed: \(msg)")
                    cont.resume(throwing: PLSError.creationFailed(msg))
                }
            })
        }
        return result
    }

    /// Save a recorded movie file to Photos. Returns the printable filename used.
    public func saveVideo(from sourceURL: URL, filename: String? = nil) async throws -> SaveResult {
        _ = try await ensureAuthorization()

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw PLSError.fileMissing(sourceURL.path)
        }

        let stagedURL = try stageIntoTemp(
            sourceURL: sourceURL,
            preferredName: filename ?? sourceURL.lastPathComponent,
            defaultExt: "mov"
        )
        let safeName = stagedURL.lastPathComponent

        log.debug("[PLS] Saving video (staged=\(safeName))")
        print("[PLS] Saving video (staged=\(safeName))")

        let result: SaveResult = try await withCheckedThrowingContinuation { cont in
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: stagedURL)
            }, completionHandler: { ok, err in
                if ok {
                    self.log.info("[PLS] 🎞️ Video saved → \(safeName)")
                    print("[PLS] 🎞️ Video saved → \(safeName)")
                    cont.resume(returning: SaveResult(filename: safeName))
                } else {
                    let msg = (err as NSError?)?.localizedDescription ?? "unknown error"
                    self.log.error("[PLS] Video save failed: \(msg)")
                    cont.resume(throwing: PLSError.creationFailed(msg))
                }
            })
        }

        // Cleanup only after success
        do {
            try FileManager.default.removeItem(at: stagedURL)
            log.debug("[PLS] Temp video removed")
        } catch {
            log.error("[PLS] Temp cleanup failed: \(error.localizedDescription)")
        }

        return SaveResult(filename: safeName)
    }

    // MARK: - Authorization

    @discardableResult
    private func ensureAuthorization() async throws -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch current {
        case .authorized, .limited:
            return current
        case .notDetermined:
            let status = await withCheckedContinuation { cont in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { s in cont.resume(returning: s) }
            }
            log.debug("[PLS] Photos auth result=\(status.rawValue)")
            if status == .authorized || status == .limited { return status }
            throw PLSError.unauthorized(status)
        default:
            throw PLSError.unauthorized(current)
        }
    }

    // MARK: - Staging

    private func stageIntoTemp(sourceURL: URL, preferredName: String, defaultExt: String) throws -> URL {
        let fm = FileManager.default
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let clean  = Self.sanitizedFilename(preferredName, defaultExt: defaultExt)
        let staged = tmpDir.appendingPathComponent("\(UUID().uuidString)-\(clean)")

        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        do {
            if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
            try fm.copyItem(at: sourceURL, to: staged)
            return staged
        } catch {
            throw PLSError.fileStageFailed(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private static func sanitizedFilename(_ raw: String, defaultExt: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "asset.\(defaultExt)" }
        if trimmed.contains(".") { return trimmed }
        return "\(trimmed).\(defaultExt)"
    }

    private static func timestampedFilename(prefix: String, ext: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        fmt.locale = .init(identifier: "en_US_POSIX")
        return "\(prefix)_\(fmt.string(from: .now)).\(ext)"
    }
}
