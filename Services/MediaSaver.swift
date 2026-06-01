//
//  MediaSaver.swift
//  SSHSwiftUIDemo
//

import Foundation
import Photos
import OSLog
import UniformTypeIdentifiers
import AVFoundation

enum MediaSaverError: Error, LocalizedError {
    case authorizationDenied
    case writeFailed(String)
    case fileMissing(URL)
    case fileTooSmall(URL, Int64)
    case notAMovie(URL)
    case movieNotPlayable(String)
    case photosChangeFailed(Error)
    case placeholderMissing
    case unknown

    var errorDescription: String? {
        switch self {
        case .authorizationDenied: return "Photos authorization denied."
        case .writeFailed(let m): return "Write failed: \(m)"
        case .fileMissing(let url): return "File missing: \(url.path)"
        case .fileTooSmall(let url, let sz): return "File too small (\(sz) bytes): \(url.lastPathComponent)"
        case .notAMovie(let url): return "Unsupported type (not a movie): \(url.lastPathComponent)"
        case .movieNotPlayable(let why): return "Movie not playable: \(why)"
        case .photosChangeFailed(let e): return "Photos change failed: \(e.localizedDescription)"
        case .placeholderMissing: return "Photos placeholder missing."
        case .unknown: return "Unknown media error."
        }
    }
}

/// Centralized file naming + persistence (Documents + Photos).
struct MediaSaver {
    static let log = Logger(subsystem: "SSHSwiftUIDemo", category: "MediaSaver")

    // MARK: - Paths / Names

    /// Ensures `Documents/Media/` exists. Returns directory URL.
    static func ensureMediaDirectory() throws -> URL {
        let dir = try FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Media", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            log.debug("[Media] Created directory: \(dir.path, privacy: .public)")
        }
        return dir
    }

    /// `IMG_YYYYMMDD_HHMMSS_SSS.jpg`
    static func uniqueImageFilename(date: Date = Date()) -> String {
        "IMG_\(stamp(date)).jpg"
    }

    /// `VID_YYYYMMDD_HHMMSS_SSS.mp4`
    static func uniqueVideoFilename(date: Date = Date()) -> String {
        "VID_\(stamp(date)).mp4"
    }

    // MARK: - Photos Auth

    /// Requests Photos authorization if needed (add-only).
    static func ensurePhotoAccess() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return
        case .notDetermined:
            let s = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard s == .authorized || s == .limited else { throw MediaSaverError.authorizationDenied }
        default:
            throw MediaSaverError.authorizationDenied
        }
    }

    // MARK: - Save Photo

    /// Save JPEG `data` to Documents/Media and to Photos with a specific filename.
    static func saveJPEGToDocumentsAndPhotos(_ data: Data,
                                             filename: String) async throws -> (documentsURL: URL, localIdentifier: String) {
        let dir = try ensureMediaDirectory()
        let fileURL = dir.appendingPathComponent(filename)

        try await Task.detached(priority: .utility) {
            do {
                try data.write(to: fileURL, options: [.atomic])
            } catch {
                throw MediaSaverError.writeFailed("write(\(fileURL.lastPathComponent)) failed: \(error)")
            }
        }.value
        log.info("[Media] Wrote JPEG to app docs: \(fileURL.path, privacy: .public) bytes=\(data.count)")

        try await ensurePhotoAccess()

        let localIdentifier: String = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            var placeholderID = ""
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                let opts = PHAssetResourceCreationOptions()
                opts.originalFilename = filename
                req.addResource(with: .photo, data: data, options: opts)
                placeholderID = req.placeholderForCreatedAsset?.localIdentifier ?? ""
            }, completionHandler: { ok, err in
                if let err = err {
                    cont.resume(throwing: MediaSaverError.photosChangeFailed(err))
                } else if ok, !placeholderID.isEmpty {
                    log.info("[Media] Saved JPEG to Photos: \(placeholderID, privacy: .public)")
                    cont.resume(returning: placeholderID)
                } else {
                    cont.resume(throwing: MediaSaverError.placeholderMissing)
                }
            })
        }

        return (fileURL, localIdentifier)
    }

    // MARK: - Save Video

    /// Move a temp movie file into Documents/Media and into Photos with `filename`.
    /// Validates the MP4 before import to avoid "phantom success".
    static func saveVideoFileToDocumentsAndPhotos(from tempURL: URL,
                                                  filename: String) async throws -> (documentsURL: URL, localIdentifier: String) {
        print("[mediasaver][saveVideoFileToDocumentsAndPhotos] \(tempURL.path)")
        
        // Preflight: file exists and has non-trivial size
        guard FileManager.default.fileExists(atPath: tempURL.path) else {
            throw MediaSaverError.fileMissing(tempURL)
        }
        let tempSize = try fileSize(at: tempURL)
        guard tempSize > 1024 else {
            throw MediaSaverError.fileTooSmall(tempURL, tempSize)
        }

        // Preflight: UTType.movie
        if let type = UTType(filenameExtension: tempURL.pathExtension.lowercased()) {
            guard type.conforms(to: .movie) else { throw MediaSaverError.notAMovie(tempURL) }
        }

        // Validate media is actually playable (tracks present, duration > 0)
        try await validateMoviePlayable(at: tempURL)

        // Move into Documents/Media
        let dir = try ensureMediaDirectory()
        let dst = dir.appendingPathComponent(filename)
        try await Task.detached(priority: .utility) {
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            do {
                try FileManager.default.moveItem(at: tempURL, to: dst)
            } catch {
                throw MediaSaverError.writeFailed("move(\(tempURL.lastPathComponent)→\(dst.lastPathComponent)) failed: \(error)")
            }
        }.value

        // Precompute size outside of the log interpolation (can't throw in autoclosure)
        let dstSize = (try? fileSize(at: dst)) ?? -1
        log.info("[Media] Moved video to app docs: \(dst.path, privacy: .public) size=\(dstSize, privacy: .public)")
        print("MediaSaver: Moved video to app docs: \(dst.path)")

        // Photos auth
        try await ensurePhotoAccess()

        // Import into Photos (do NOT move our Documents copy)
        let localIdentifier: String = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            var placeholderID = ""
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                let opts = PHAssetResourceCreationOptions()
                opts.shouldMoveFile = false
                opts.originalFilename = filename
                req.addResource(with: .video, fileURL: dst, options: opts)
                placeholderID = req.placeholderForCreatedAsset?.localIdentifier ?? ""
            }, completionHandler: { ok, err in
                if let err = err {
                    cont.resume(throwing: MediaSaverError.photosChangeFailed(err))
                } else if ok, !placeholderID.isEmpty {
                    log.info("[Media] Saved video to Photos: \(placeholderID, privacy: .public)")
                    cont.resume(returning: placeholderID)
                } else {
                    cont.resume(throwing: MediaSaverError.placeholderMissing)
                }
            })
        }

        return (dst, localIdentifier)
    }

    // MARK: - Private

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return f.string(from: date)
    }

    private static func fileSize(at url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Ensures the movie has at least one video track and is reported playable by AVFoundation.
    private static func validateMoviePlayable(at url: URL) async throws {
        let asset = AVURLAsset(url: url)
        do {
            let playable = try await asset.load(.isPlayable)
            if !playable {
                throw MediaSaverError.movieNotPlayable("AVURLAsset.isPlayable = false")
            }

            // Check tracks and nominal duration
            async let vTracks = asset.load(.tracks)
            async let dur = asset.load(.duration)

            let tracks = try await vTracks
            let duration = try await dur

            let videoTrackCount = tracks.filter { $0.mediaType == .video }.count
            if videoTrackCount == 0 {
                throw MediaSaverError.movieNotPlayable("no video tracks")
            }
            if duration == .indefinite || duration.seconds <= 0.0 {
                throw MediaSaverError.movieNotPlayable("non-positive duration")
            }
        } catch {
            throw MediaSaverError.movieNotPlayable("\(error)")
        }
    }
}
