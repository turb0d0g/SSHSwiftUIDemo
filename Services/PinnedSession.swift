//
//  PinnedSession.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 10/28/25.
//


import Foundation
import Security
import OSLog

public enum PinnedSession {
    public static func make(pinnedSPKIBase64: String?) -> URLSession {
        guard let pinned = pinnedSPKIBase64 else {
            return URLSession(configuration: .ephemeral)
        }
        let delegate = PinDelegate(spkiBase64: pinned)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    private final class PinDelegate: NSObject, URLSessionDelegate {
        private let spki: Data
        private let log = Logger(subsystem: "SSHSwiftUIDemo", category: "PinnedSession")

        init(spkiBase64: String) {
            self.spki = Data(base64Encoded: spkiBase64) ?? Data()
        }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust
            else { return completionHandler(.performDefaultHandling, nil) }

            if SecTrustEvaluateWithError(trust, nil) {
                if let serverSPKI = Self.extractSPKI(from: trust), serverSPKI == spki {
                    log.debug("[PinnedSession] SPKI match ✅")
                    return completionHandler(.useCredential, URLCredential(trust: trust))
                } else {
                    log.error("[PinnedSession] SPKI mismatch ❌ — rejecting")
                    return completionHandler(.cancelAuthenticationChallenge, nil)
                }
            } else {
                log.error("[PinnedSession] SecTrustEvaluateWithError failed")
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }

        private static func extractSPKI(from trust: SecTrust) -> Data? {
            guard let cert = SecTrustGetCertificateAtIndex(trust, 0) else { return nil }
            let key = SecCertificateCopyKey(cert)
            var error: Unmanaged<CFError>?
            guard let spki = SecKeyCopyExternalRepresentation(key!, &error) else { return nil }
            return spki as Data
        }
    }
}