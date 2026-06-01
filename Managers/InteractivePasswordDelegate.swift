//
//  InteractivePasswordDelegate.swift
//  SSHSwiftUIDemo
//

//
//  InteractivePasswordDelegate.swift
//  SSHSwiftUIDemo
//
//  EventLoop-safe NIOSSH password delegate.
//  - Completes promises on the promise's EventLoop.
//  - Loads from Keychain first.
//  - Falls back to a @MainActor passwordProvider (safe for presenting sheets/alerts).
//

import Foundation
import NIO
import NIOSSH

final class InteractivePasswordDelegate: NIOSSHClientUserAuthenticationDelegate {

    // Provider is MainActor-isolated so UI prompting is always safe.
    typealias Provider = @MainActor @Sendable () async -> String?

    private let account: String
    private let username: String
    private let provider: Provider

    init(account: String, username: String, passwordProvider: @escaping Provider) {
        self.account = account
        self.username = username
        self.provider = passwordProvider
    }

    func nextAuthenticationType(
        availableMethods available: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        // Older NIO: promise doesn't expose eventLoop; use its future.
        let el = nextChallengePromise.futureResult.eventLoop

        print("[AuthDelegate] nextAuthenticationType account=\(account) available=\(available)")

        guard available.contains(.password) else {
            print("[AuthDelegate] Server did not offer password auth → returning nil offer")
            el.execute { nextChallengePromise.succeed(nil) }
            return
        }

        Task {
            // 1) Keychain first
            if let cached = try? KeychainService.loadPassword(account: account), !cached.isEmpty {
                print("[AuthDelegate] Using cached password for \(account)")
                let offer = NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "ssh-connection",
                    offer: .password(.init(password: cached))
                )
                el.execute { nextChallengePromise.succeed(offer) }
                return
            }

            // 2) UI provider (will hop to MainActor automatically)
            let pwd = await provider()

            guard let pwd, !pwd.isEmpty else {
                print("[AuthDelegate] Password provider returned nil/empty for \(account) → returning nil offer")
                el.execute { nextChallengePromise.succeed(nil) }
                return
            }

            // 3) Save (best-effort)
            do {
                try KeychainService.savePassword(account: account, password: pwd)
                print("[AuthDelegate] Cached password for \(account)")
            } catch {
                print("[AuthDelegate] Keychain save failed for \(account): \(error)")
            }

            let offer = NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .password(.init(password: pwd))
            )

            // 4) Complete on EventLoop
            el.execute { nextChallengePromise.succeed(offer) }
        }
    }
}
/*
import Foundation
import OSLog
import NIOCore           // EventLoopPromise / EventLoopFuture
import NIOSSH

/// Legacy NIOSSH auth delegate (promise-based) that supports PASSWORD auth only.
/// Accepts an async password provider and fulfills the NIO promise when ready.
public final class InteractivePasswordDelegate: NIOSSHClientUserAuthenticationDelegate {

    /// Async provider (Keychain/FaceID/UI).
    public typealias Provider = @Sendable () async -> String?

    // MARK: Stored
    private let logger = Logger(subsystem: "com.SSHSwiftUIDemo", category: "AuthDelegate")

    private let account: String          // e.g., "user@host"
    private let username: String
    private let passwordProvider: Provider
    private let maxAttempts: Int
    private var attempts: Int = 0

    // MARK: Init
    public init(account: String,
                username: String,
                maxAttempts: Int = 2,
                passwordProvider: @escaping Provider) {
        self.account = account
        self.username = username
        self.maxAttempts = maxAttempts
        self.passwordProvider = passwordProvider
    }

    // MARK: Required (very old NIOSSH API)
    public func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        attempts += 1
        logger.log("[AuthDelegate] nextAuthenticationType attempt=\(self.attempts) account=\(self.account, privacy: .public) available=\(String(describing: availableMethods), privacy: .public)")

        guard attempts <= maxAttempts else {
            logger.error("[AuthDelegate] Exhausted attempts for \(self.account, privacy: .public)")
            nextChallengePromise.succeed(nil)
            return
        }

        // Only password is supported in this legacy delegate.
        guard availableMethods.contains(.password) else {
            logger.error("[AuthDelegate] Server did NOT offer password; cannot proceed for \(self.account, privacy: .public)")
            nextChallengePromise.succeed(nil)
            return
        }

        // Use the event loop from the future (older NIO doesn't expose promise.eventLoop)
        let el = nextChallengePromise.futureResult.eventLoop

        // Fetch password asynchronously, then fulfill on the event loop.
        Task { [passwordProvider, username, account = self.account] in
            let pw = await passwordProvider()
            guard let pw, !pw.isEmpty else {
                self.logger.error("[AuthDelegate] Password provider returned nil/empty for \(account, privacy: .public)")
                el.execute { nextChallengePromise.succeed(nil) }
                return
            }

            self.logger.log("[AuthDelegate] Offering password auth for \(account, privacy: .public)")
            let offer = NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .password(.init(password: pw))
            )
            el.execute { nextChallengePromise.succeed(offer) }
        }
    }
}
*/
