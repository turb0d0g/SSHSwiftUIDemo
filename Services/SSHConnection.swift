//
//  SSHConnection.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 10/29/25.
//


// Services/SSHConnection.swift
import Foundation
import NIOCore
import NIOTransportServices   // Prefer TransportServices on Apple platforms
import NIOSSH

/// Thin SSH connector that opens an SFTP subsystem child channel with
/// verbose logging. Password auth only (per requirements).
final class SSHConnection {

    // MARK: - Public API

    struct Credentials {
        let username: String
        let password: String
    }

    // Retain lifecycle for proper teardown
    private var group: NIOTSEventLoopGroup?
    private var rootChannel: Channel?
    private var sshHandler: NIOSSHHandler?
    private(set) var sftpChannel: Channel?

    init() {}

    /// Connects to `host:port`, performs SSH handshake with password auth,
    /// opens a `.session` child channel, requests the "sftp" subsystem,
    /// and returns the active SFTP child `Channel`.
    func connectAndOpenSFTP(host: String, port: Int, creds: Credentials) async throws -> Channel {
        print("[SSH] bootstrapping → \(host):\(port)")

        let g = NIOTSEventLoopGroup(loopCount: 1)
        self.group = g

        let bootstrap = NIOTSConnectionBootstrap(group: g)
            .channelInitializer { channel in
                print("[SSH][root] channelInitializer begin")

                // Add loud tracing of everything on the root channel.
                let tracer = PrintEverythingHandler(tag: "root")

                // Password-only user auth delegate (see below).
                let userAuth = PasswordOnlyUserAuthDelegate(
                    username: creds.username,
                    password: creds.password
                )

                // Host-key validation (accept-all for demo; wire in pinning later).
                let serverAuth = AcceptAllHostKeysDelegate()

                // Core SSH handler
                let sshHandler = NIOSSHHandler(
                    role: .client(.init(userAuthDelegate: userAuth,
                                        serverAuthDelegate: serverAuth)),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil
                )
                self.sshHandler = sshHandler

                print("[SSH][root] adding PrintEverythingHandler + NIOSSHHandler to pipeline")
                return channel.pipeline.addHandlers([tracer, sshHandler])
            }
            // ⚠️ Do NOT set BSD socket options (e.g., TCP_NODELAY) on NIOTS.
            // Network.framework-backed channels don't support ChannelOptions.socketOption.
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)

        // TCP connect
        let tcp = try await bootstrap.connect(host: host, port: port).get()
        self.rootChannel = tcp
        print("[SSH][root] TCP connected; waiting for SSH handshake to finish (handled by NIOSSHHandler)")

        // Grab the SSH handler on the root channel
        let sshHandler = try await tcp.pipeline.handler(type: NIOSSHHandler.self).get()
        self.sshHandler = sshHandler
        print("[SSH][root] NIOSSHHandler resolved from pipeline")

        // Create a session child channel and request the SFTP subsystem on it.
        let childPromise = tcp.eventLoop.makePromise(of: Channel.self)
        print("[SSH][root] createChannel(.session) → promise")
        sshHandler.createChannel(childPromise, channelType: .session) { child, channelType in
            guard channelType == .session else {
                print("[SSH][child] ERROR: unexpected child type \(channelType)")
                return tcp.eventLoop.makeFailedFuture(SSHError.invalidChannelType)
            }

            print("[SSH][child] session created; enabling half-closure + adding tracer")
            return child
                .setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .flatMap {
                    child.pipeline.addHandler(PrintEverythingHandler(tag: "sftp-child"))
                }
                .flatMap {
                    let req = SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true)
                    print("[SSH][child] requesting subsystem 'sftp'…")
                    return child.triggerUserOutboundEvent(req)
                }
        }

        let sftpChannel = try await childPromise.futureResult.get()
        self.sftpChannel = sftpChannel
        print("[SSH][child] SFTP subsystem ready ✅")
        return sftpChannel
    }

    /// Gracefully tears down the SFTP child channel, root channel, and event loop group.
    func close() {
        print("[SSH] Closing…")
        if let ch = sftpChannel {
            try? ch.close().wait()
            sftpChannel = nil
        }
        if let root = rootChannel {
            try? root.close().wait()
            rootChannel = nil
        }
        if let g = group {
            try? g.syncShutdownGracefully()
            group = nil
        }
        sshHandler = nil
        print("[SSH] Closed.")
    }
}

// MARK: - Delegates

/// Password-only user-auth delegate (single attempt).
private struct PasswordOnlyUserAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let password: String

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        print("[SSH][auth] server allows: \(availableMethods)")
        guard availableMethods.contains(.password) else {
            print("[SSH][auth] password not permitted by server; giving up")
            nextChallengePromise.succeed(nil) // no more attempts
            return
        }

        let offer = NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "ssh-connection",
            offer: .password(.init(password: password))
        )
        print("[SSH][auth] offering password for user '\(username)'")
        nextChallengePromise.succeed(offer)
    }
}

/// Demo host-key validator: logs and accepts everything (do NOT ship like this).
/// Replace with a real validator that pins OpenSSH-formatted keys via Keychain.
private final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let openSSH = String(openSSHPublicKey: hostKey) // "algo base64"
        print("[SSH][hostkey] received: \(openSSH)")
        // TODO: compare `openSSH` against your pinned value from Keychain (persisted once).
        validationCompletePromise.succeed(())
    }
}

// MARK: - Loud tracing handler

/// Ultra-verbose logger that prints everything notable happening on a channel.
private final class PrintEverythingHandler: ChannelDuplexHandler {
    typealias InboundIn   = NIOAny
    typealias OutboundIn  = NIOAny
    typealias OutboundOut = NIOAny

    let tag: String
    init(tag: String) { self.tag = tag }

    // Inbound path
    func channelRegistered(context: ChannelHandlerContext) { print("[SSH][\(tag)] channelRegistered"); context.fireChannelRegistered() }
    func channelUnregistered(context: ChannelHandlerContext) { print("[SSH][\(tag)] channelUnregistered"); context.fireChannelUnregistered() }
    func channelActive(context: ChannelHandlerContext) { print("[SSH][\(tag)] channelActive"); context.fireChannelActive() }
    func channelInactive(context: ChannelHandlerContext) { print("[SSH][\(tag)] channelInactive"); context.fireChannelInactive() }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        print("[SSH][\(tag)] userInboundEventTriggered → \(event)")
        context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        print("[SSH][\(tag)] channelRead(\(data))")
        context.fireChannelRead(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        print("[SSH][\(tag)] channelReadComplete")
        context.fireChannelReadComplete()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("[SSH][\(tag)] errorCaught → \(error)")
        context.fireErrorCaught(error)
    }

    // Outbound path
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        print("[SSH][\(tag)] write(\(data))")
        context.write(data, promise: promise)
    }

    func flush(context: ChannelHandlerContext) {
        print("[SSH][\(tag)] flush()")
        context.flush()
    }

    func read(context: ChannelHandlerContext) {
        print("[SSH][\(tag)] read()")
        context.read()
    }

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        print("[SSH][\(tag)] close(mode: \(mode))")
        context.close(mode: mode, promise: promise)
    }

    func bind(context: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        print("[SSH][\(tag)] bind(to: \(address))")
        context.bind(to: address, promise: promise)
    }

    func connect(context: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        print("[SSH][\(tag)] connect(to: \(address))")
        context.connect(to: address, promise: promise)
    }

    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        print("[SSH][\(tag)] triggerUserOutboundEvent → \(event)")
        context.triggerUserOutboundEvent(event, promise: promise)
    }
}

// MARK: - Local errors

private enum SSHError: Error {
    case invalidChannelType
}
