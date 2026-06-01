//
//  PinningMode.swift
//  HLSDemo
//
//  Created by Jesse Herring on 8/5/25.
//


// NetworkClient.swift
// Hardened Alamofire Session for modern TLS + optional certificate/public-key pinning.

import Foundation
import Alamofire

/// How (if at all) to pin the server's identity.
public enum PinningMode: Hashable {
    case none
    case pinnedCertificates      // bundle one or more .cer files in the app
    case publicKeys              // pins SPKI; resilient to cert renewals using same key
}

/// Shared factory for Alamofire `Session`s configured with:
/// - TLS 1.2–1.3
/// - waitsForConnectivity
/// - sensible timeouts
/// - optional per-host certificate or public key pinning
public final class NetworkClient {

    // MARK: Shared default (no pinning)
    public static let shared = NetworkClient()
    public let session: Session

    // MARK: Per-host session cache (prevents re-creating Sessions repeatedly)
    private static var cache = [CacheKey: Session]()
    private struct CacheKey: Hashable { let host: String; let pinning: PinningMode }

    private init() {
        session = Session(configuration: NetworkClient.makeConfig(), serverTrustManager: nil)
    }

    /// Return (and cache) a `Session` for a specific host with the requested pinning mode.
    /// - Important: Pinning validates by **hostname**. Avoid raw IPs; use a real hostname (e.g., via local DNS/reverse proxy).
    public static func session(for host: String, pinning: PinningMode) -> Session {
        let key = CacheKey(host: host, pinning: pinning)
        if let s = cache[key] { return s }

        let cfg = makeConfig()

        // Configure server trust / pinning
        let stm: ServerTrustManager?
        switch pinning {
        case .none:
            stm = nil

        case .pinnedCertificates:
            // Put one or more *.cer files in your app bundle. Alamofire will pick them up automatically.
            stm = ServerTrustManager(evaluators: [
                host: PinnedCertificatesTrustEvaluator(
                    acceptSelfSignedCertificates: false,
                    performDefaultValidation: true,  // validate CA chain
                    validateHost: true               // validate hostname matches certificate
                )
            ])

        case .publicKeys:
            // Extracts public keys from bundled certs at runtime; tolerant to cert rotation with same key.
            stm = ServerTrustManager(evaluators: [
                host: PublicKeysTrustEvaluator(
                    performDefaultValidation: true,
                    validateHost: true
                )
            ])
        }

        let session = Session(configuration: cfg, serverTrustManager: stm)
        cache[key] = session
        return session
    }

    /// Clear cached per-host Sessions (rarely needed, but useful for tests).
    public static func clearCache() { cache.removeAll() }

    // MARK: URLSessionConfiguration hardened for modern TLS
    private static func makeConfig() -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        // iOS 13+: enforce modern TLS only
        if #available(iOS 13.0, *) {
            cfg.tlsMinimumSupportedProtocolVersion = .TLSv12
            cfg.tlsMaximumSupportedProtocolVersion = .TLSv13
        }
        return cfg
    }
}