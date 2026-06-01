//
//  SFTPConnection.swift
//  SSHSwiftUIDemo
//

import Foundation
import NIOCore
import NIOTransportServices
import NIOSSH

public struct SFTPCredentials: Sendable {
    public let username: String
    public let password: String
    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public enum SFTPConnError: Error, LocalizedError {
    case disconnected
    case subsystemNotReady
    case initTimeout
    case initFailed(String)
    public var errorDescription: String? {
        switch self {
        case .disconnected: return "SFTP is not connected"
        case .subsystemNotReady: return "SFTP subsystem was not acknowledged by the server"
        case .initTimeout: return "Timed out waiting for SFTP VERSION after INIT"
        case .initFailed(let m): return "SFTP initialization failed: \(m)"
        }
    }
}

/// Owns SSH transport + SFTP child channel and a minimal SFTP v3 client.
public actor SFTPConnection {

    public struct Config: Sendable {
        public let host: String
        public let port: Int
        public let credentials: SFTPCredentials
        public init(host: String, port: Int = 22, credentials: SFTPCredentials) {
            self.host = host
            self.port = port
            self.credentials = credentials
        }
    }

    private let config: Config
    private var group: NIOTSEventLoopGroup?
    private var rootChannel: Channel?
    private var sftpChannel: Channel?
    private var sftpClient: SFTPClient?

    public init(config: Config) {
        self.config = config
    }

    // MARK: Lifecycle

    public func connect() async throws {
        if let ch = sftpChannel, ch.isActive, sftpClient != nil { return }

        print("[SFTPConnection] connect → \(config.host):\(config.port) as \(config.credentials.username)")

        let g = NIOTSEventLoopGroup(loopCount: 1)
        self.group = g

        // Root TCP (Network.framework)
        let bootstrap = NIOTSConnectionBootstrap(group: g)
            .channelInitializer { channel in
                print("[SSH][root] channelInitializer")
                let userAuth = PasswordOnlyUserAuthDelegate(
                    username: self.config.credentials.username,
                    password: self.config.credentials.password
                )
                let serverAuth = AcceptAllHostKeysDelegate()

                let sshHandler = NIOSSHHandler(
                    role: .client(.init(userAuthDelegate: userAuth, serverAuthDelegate: serverAuth)),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil
                )

                return channel.pipeline.addHandlers([
                    PrintEverythingHandler(tag: "root"),
                    sshHandler
                ])
            }
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)

        // TCP connect
        let root = try await bootstrap.connect(host: config.host, port: config.port).get()
        self.rootChannel = root
        print("[SSH][root] connected; creating .session child")

        // Create session child (no subsystem request here)
        let childPromise = root.eventLoop.makePromise(of: Channel.self)
        let sshHandler = try await root.pipeline.handler(type: NIOSSHHandler.self).get()

        sshHandler.createChannel(childPromise, channelType: .session) { child, channelType in
            guard channelType == .session else {
                return child.eventLoop.makeFailedFuture(SFTPConnError.subsystemNotReady)
            }
            // Half-closure + tracer
            return child
                .setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .flatMap {
                    child.pipeline.addHandler(PrintEverythingHandler(tag: "sftp-child"))
                }
        }

        // Child is created; now explicitly request 'sftp' and await the reply
        let child = try await childPromise.futureResult.get()
        self.sftpChannel = child
        print("[SSH][child] created; requesting 'sftp' subsystem (wantReply=true)…")

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    let req = SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true)
                    _ = try await child.triggerUserOutboundEvent(req).get()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 5_000_000_000) // 5s
                    throw SFTPConnError.subsystemNotReady
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            print("[SSH][child] subsystem request failed: \(error)")
            throw error
        }

        print("[SSH][child] subsystem acknowledged ✅ — constructing SFTP client")

        // Build client, initialize (INIT/VERSION) with timeout
        let client = SFTPClient(channel: child)

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await client.initialize() }
                group.addTask {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    throw SFTPConnError.initTimeout
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            print("[SFTPConnection] ERROR during SFTP INIT: \(error)")
            throw error
        }

        self.sftpClient = client
        print("[SFTPConnection] SFTP initialized and ready")
    }

    public func close() {
        print("[SFTPConnection] close()")
        if let ch = sftpChannel { try? ch.close().wait() }
        if let root = rootChannel { try? root.close().wait() }
        sftpChannel = nil
        rootChannel = nil
        sftpClient = nil
        if let g = group { try? g.syncShutdownGracefully() }
        group = nil
    }

    // MARK: High-level SFTP Ops (internal — SFTPName is internal to this module)

    func list(path: String) async throws -> [SFTPName] {
        try await requireClient().list(path: path)
    }

    func mkdir(path: String) async throws {
        try await requireClient().mkdir(path: path)
    }

    func remove(path: String) async throws {
        try await requireClient().remove(path: path)
    }

    func rename(from: String, to: String) async throws {
        try await requireClient().rename(from: from, to: to)
    }

    func download(path: String, maxBytes: Int) async throws -> Data {
        try await requireClient().download(path: path, maxBytes: maxBytes)
    }

    func upload(data: Data, to path: String) async throws {
        try await requireClient().upload(toPath: path, data: data)
    }

    // MARK: Helpers

    private func requireClient() throws -> SFTPClient {
        guard let c = sftpClient, sftpChannel?.isActive == true else {
            throw SFTPConnError.disconnected
        }
        return c
    }
}

// MARK: - SSH Delegates

private struct PasswordOnlyUserAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let password: String

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        print("[SSH][auth] server allows: \(availableMethods)")
        guard availableMethods.contains(.password) else {
            nextChallengePromise.succeed(nil); return
        }
        let offer = NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "ssh-connection",
            offer: .password(.init(password: password))
        )
        print("[SSH][auth] offering password for '\(username)'")
        nextChallengePromise.succeed(offer)
    }
}

private final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = String(openSSHPublicKey: hostKey)
        print("[SSH][hostkey] received: \(key)")
        validationCompletePromise.succeed(())
    }
}

// MARK: - Loud tracing

private final class PrintEverythingHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    let tag: String
    init(tag: String) { self.tag = tag }

    func channelRegistered(context: ChannelHandlerContext) { print("[SSH][\(tag)] channelRegistered"); context.fireChannelRegistered() }
    func channelUnregistered(context: ChannelHandlerContext) { print("[SSH][\(tag)] channelUnregistered"); context.fireChannelUnregistered() }
    func channelActive(context: ChannelHandlerContext) { print("[SSH][\(tag)] channelActive"); context.fireChannelActive() }
    func channelInactive(context: ChannelHandlerContext) { print("[SSH][\(tag)] channelInactive"); context.fireChannelInactive() }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) { print("[SSH][\(tag)] userInboundEventTriggered → \(event)"); context.fireUserInboundEventTriggered(event) }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { print("[SSH][\(tag)] channelRead(\(data))"); context.fireChannelRead(data) }
    func channelReadComplete(context: ChannelHandlerContext) { print("[SSH][\(tag)] channelReadComplete"); context.fireChannelReadComplete() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { print("[SSH][\(tag)] errorCaught → \(error)"); context.fireErrorCaught(error) }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) { print("[SSH][\(tag)] write(\(data))"); context.write(data, promise: promise) }
    func flush(context: ChannelHandlerContext) { print("[SSH][\(tag)] flush()"); context.flush() }
    func read(context: ChannelHandlerContext) { print("[SSH][\(tag)] read()"); context.read() }
    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) { print("[SSH][\(tag)] close(mode: \(mode))"); context.close(mode: mode, promise: promise) }
    func bind(context: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) { print("[SSH][\(tag)] bind(to: \(address))"); context.bind(to: address, promise: promise) }
    func connect(context: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) { print("[SSH][\(tag)] connect(to: \(address))"); context.connect(to: address, promise: promise) }
    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) { print("[SSH][\(tag)] triggerUserOutboundEvent → \(event)"); context.triggerUserOutboundEvent(event, promise: promise) }
}
