//
//  SnapshotResponse.swift
//  HLSDemo
//
//  Created by Jesse Herring on 7/30/25.
//


import Foundation
import UIKit

private struct SnapshotResponse: Decodable {
    let ok: Bool
    let url: String?       // most servers use this
    let path: String?      // some use "path" instead
    let error: String?
    let timestamp: Int?

    var imagePath: String? { url ?? path }
}

enum SnapshotError: LocalizedError {
    case badStatus(Int)
    case emptyBody
    case decodeFailed(String)
    case server(String)
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "HTTP \(code)"
        case .emptyBody: return "Empty response body"
        case .decodeFailed(let m): return "Decode failed: \(m)"
        case .server(let m): return "Server: \(m)"
        case .invalidURL(let u): return "Invalid URL: \(u)"
        }
    }
}

final class SnapshotService {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Calls /cgi-bin/snapshot.py which returns JSON with the snapshot URL.
    @discardableResult
    func captureSnapshotJSON() async throws -> URL {
        let endpoint = baseURL.appendingPathComponent("/cgi-bin/snapshot.cgi")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData

        print("[Snapshot] ➡️ GET \(endpoint.absoluteString)")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SnapshotError.badStatus(-1) }
        print("[Snapshot] ⬅️ status=\(http.statusCode) content-type=\(http.value(forHTTPHeaderField: "Content-Type") ?? "n/a") length=\(data.count)")

        guard 200..<300 ~= http.statusCode else {
            throw SnapshotError.badStatus(http.statusCode)
        }
        guard !data.isEmpty else {
            throw SnapshotError.emptyBody
        }

        do {
            let dto = try JSONDecoder().decode(SnapshotResponse.self, from: data)
            print("[Snapshot] parsed ok=\(dto.ok) url=\(dto.url ?? "nil") ts=\(dto.timestamp ?? -1)")
            if dto.ok, let path = dto.url {
                // Handle absolute or relative URL
                if let absolute = URL(string: path), absolute.scheme != nil {
                    return absolute
                } else {
                    var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
                    comps.path = path
                    guard let final = comps.url else { throw SnapshotError.invalidURL(path) }
                    return final
                }
            } else {
                throw SnapshotError.server(dto.error ?? "Unknown error")
            }
        } catch {
            print("[Snapshot] ❌ decode error: \(error)")
            throw SnapshotError.decodeFailed(error.localizedDescription)
        }
    }

    /// Convenience: fetches the actual JPEG data once you have the cache-busted URL.
    func fetchImageData(from url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw SnapshotError.badStatus(code)
        }
        print("[Snapshot] 📸 image bytes=\(data.count)")
        return data
    }
    
    
}
