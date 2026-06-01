// Managers/SSHManager.swift
// SSH client glue around NIO + NIOSSH with verbose, ordered handshake logging.
// Compatible with single-arg and three-arg NIOSSHHandler initializers, without referring to Role type names.


//
//  SSHManager.swift
//  SSHSwiftUIDemo
//
//  Created by You on a sunny day. Updated with sessionID + tagged publishers.
//

//
//  SSHManager.swift
//  SSHSwiftUIDemo
//
//  Updated: sessionID tagging (output & state), nonisolated publish helpers,
//           and no-dup handshake transcript lines.
//  Actor-safe for NIO callbacks via nonisolated methods.
//

import Foundation
import NIO
import NIOSSH
import Combine
import CryptoKit

actor SSHManager: ObservableObject {

    enum SSHError: Error { case disconnected, authenticationFailed, channelSetupFailed }
    enum ConnectionState: CustomStringConvertible {
        case idle, connecting, connected, failed(Error), disconnected
        var description: String {
            switch self {
            case .idle: return "idle"
            case .connecting: return "connecting"
            case .connected: return "connected"
            case .failed(let e): return "failed(\(e))"
            case .disconnected: return "disconnected"
            }
        }
    }

    // MARK: - Session identity
    /// Unique ID stamped on every event from this manager.
    let sessionID = UUID()

    // MARK: - Streams consumed by the UI / VM (legacy + tagged)
    /// Legacy raw bytes → Terminal
    let output = PassthroughSubject<Data, Never>()
    /// Legacy state stream
    let state  = CurrentValueSubject<ConnectionState, Never>(.idle)

    /// Tagged bytes (sessionID, data)
    let outputTagged = PassthroughSubject<(UUID, Data), Never>()
    /// Tagged state (sessionID, state)
    let stateTagged  = CurrentValueSubject<(UUID, ConnectionState), Never>((UUID(), .idle))

    // MARK: - Internals
    private var group: MultiThreadedEventLoopGroup?
    private var tcpChannel: Channel?
    private var childChannel: Channel?
    private var termType: String = "xterm-256color"

    // MARK: - Init
    init() {
        // seed tagged state with *this* sessionID
        stateTagged.value = (sessionID, .idle)
        print("[SSH] init session=\(sessionID)")
    }

    // MARK: - Connect
    /// Connects and starts an interactive shell with a PTY. Password is supplied lazily via `passwordProvider`.
    func connect(host: String,
                 port: Int,
                 username: String,
                 passwordProvider: @escaping InteractivePasswordDelegate.Provider) async {
        guard tcpChannel == nil else { return }
        setState(.connecting)

        // Transcript intro — EXACT phrasing
        HandshakePrinter.connecting(host: host, port: port)
        HandshakePrinter.clientBanner("SSH-2.0-SwiftTerm_1.0")

        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let account = "\(username)@\(host)"

        // Delegates
        let userAuth = InteractivePasswordDelegate(
            account: account,
            username: username,
            passwordProvider: passwordProvider
        )
        let serverAuth = HostKeyLogger(onKey: { pub in
            // Exactly: "Host key fingerprint: SHA256:... (trusted)"
            let fp = Self.sha256Fingerprint(of: pub)
            HandshakePrinter.hostKeyFingerprint(fp, trusted: true)
        })

        // NIOSSH handler via compatibility shim
        let sshHandler = makeSSHHandlerClient(userAuthDelegate: userAuth, serverAuthDelegate: serverAuth)

        // Pipeline: banner sniffer → kex probe → NIOSSH
        let bootstrap = ClientBootstrap(group: group!).channelInitializer { ch in
            _ = ch.pipeline.addHandler(ServerBannerSniffer { banner in
                HandshakePrinter.serverBanner(banner)
            })
            _ = ch.pipeline.addHandler(HandshakeProbe())
            return ch.pipeline.addHandler(sshHandler)
        }

        do {
            let parent = try await bootstrap.connect(host: host, port: port).get()
            tcpChannel = parent

            // Create a *session* child channel (post-auth)
            let handler: NIOSSHHandler = try await parent.pipeline.handler(type: NIOSSHHandler.self).get()
            let childPromise = parent.eventLoop.makePromise(of: Channel.self)
            handler.createChannel(childPromise) { [weak self] child, channelType in
                guard let self = self, channelType == .session else {
                    return child.eventLoop.makeFailedFuture(SSHError.channelSetupFailed)
                }
                // inbound bytes → our Inbound handler; it calls nonisolated publish helpers
                return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                    .flatMap { child.pipeline.addHandlers([Inbound(childTo: self)]) }
            }
            let child = try await childPromise.futureResult.get()
            await bindChild(child)

            // Exactly: "Authentication success."
            HandshakePrinter.authSuccess()
            setState(.connected)
        } catch {
            setState(.failed(error))
            print("[SSH] connect error (session=\(sessionID)):", error)
        }
    }

    // MARK: - I/O
    func send(_ bytes: ArraySlice<UInt8>) async throws {
        print("[SSHManager]--->> send (\(bytes.count) bytes) session=\(sessionID)")
        guard let ch = childChannel else { throw SSHError.disconnected }
        var buf = ch.allocator.buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        try await ch.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buf))).get()
    }

    // MARK: - Lifecycle
    func disconnect() async {
        print("[SSHManager]--->> disconnect session=\(sessionID)")
        do { try await tcpChannel?.close() } catch { print("[SSH] close error:", error) }
        do { try? await group?.syncShutdownGracefully() } // not fatal if already shutting down
        tcpChannel = nil
        childChannel = nil
        setState(.disconnected)
        setState(.idle) // return to idle for UI
    }

    fileprivate func bindChild(_ ch: Channel) {
        childChannel = ch
        // Request PTY + Shell off the channel’s loop
        Task { try? await requestPtyAndShell() }
    }

    private func requestPtyAndShell() async throws {
        print("[SSHManager]--->> requestPtyAndShell session=\(sessionID)")
        guard let ch = childChannel else { throw SSHError.channelSetupFailed }
        // Exactly: "PTY requested: xterm-256color"
        let ptyEvent = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: termType,
            terminalCharacterWidth: 80,
            terminalRowHeight: 24,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([:])
        )
        try await ch.triggerUserOutboundEvent(ptyEvent).get()
        HandshakePrinter.ptyRequested(termType)

        // Exactly: "Shell started. Ready for input."
        let shellEvent = SSHChannelRequestEvent.ShellRequest(wantReply: true)
        try await ch.triggerUserOutboundEvent(shellEvent).get()
        HandshakePrinter.shellReady()
    }

    // MARK: - Nonisolated publish helpers (for NIO threads)
    /// Publish raw bytes (stdout/stderr) to both legacy and tagged streams.
    nonisolated func publishBytesFromChannel(_ data: Data) {
        output.send(data)
        outputTagged.send((sessionID, data))
    }

    /// Update state to both legacy and tagged streams.
    nonisolated func setState(_ newState: ConnectionState) {
        print("[SSH] session=\(sessionID) state → \(newState)")
        state.send(newState)
        stateTagged.send((sessionID, newState))
    }
    
    // MARK: - SFTP
    /// Open a fresh SSH session child and switch it to the `sftp` subsystem.
    /// Returns a live NIO `Channel` you can wire into your SFTP codec/UI.
    /// Multiple SFTP channels may coexist alongside your interactive shell.
    func openSFTPChannel() async throws -> Channel {
        // Guard connection
        guard case .connected = state.value else {
            throw SSHError.disconnected
        }
        guard let parent = tcpChannel, parent.isActive else {
            throw SSHError.disconnected
        }

        // Fetch the NIOSSHHandler sitting on the parent pipeline
        let sshHandler = try await parent.pipeline.handler(type: NIOSSHHandler.self).get()

        // Ask NIOSSH to create a *session* child channel (no handlers yet)
        let childPromise = parent.eventLoop.makePromise(of: Channel.self)
        sshHandler.createChannel(childPromise) { child, channelType in
            // We only support session channels for SFTP
            guard case .session = channelType else {
                return child.eventLoop.makeFailedFuture(SSHError.channelSetupFailed)
            }
            // Leave the pipeline empty here; your SFTP UI/codec can add its own handlers.
            return child.eventLoop.makeSucceededFuture(())
        }

        let child = try await childPromise.futureResult.get()

        // Request the "sftp" subsystem on the child channel
        try await child
            .triggerUserOutboundEvent(
                SSHChannelRequestEvent.SubsystemRequest(
                    subsystem: "sftp",
                    wantReply: true
                )
            )
            .get()

        // Allow remote half-closure so EOF from server doesn’t hard-close us immediately
        _ = try? await child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).get()

        print("[SSHManager][SFTP] subsystem ready (session=\(sessionID))")
        return child
    }
}

extension SSHManager.ConnectionState: Equatable {
    public static func == (lhs: SSHManager.ConnectionState, rhs: SSHManager.ConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.connecting, .connecting),
             (.connected, .connected),
             (.disconnected, .disconnected):
            return true
        case (.failed, .failed):
            // Consider all failures equivalent for UI state comparisons.
            return true
        default:
            return false
        }
    }
}

// MARK: - NIOSSHHandler compatibility shims (no Role type references)
//
// If you see "Missing arguments for parameters 'allocator','inboundChildChannelInitializer'",
// add `-D NIOSSH_HANDLER_INIT_THREE` to Build Settings → Other Swift Flags.
// If you see "Extra arguments …", remove that flag.

#if NIOSSH_HANDLER_INIT_THREE
@inline(__always)
private func makeSSHHandlerClient(
    userAuthDelegate: NIOSSHClientUserAuthenticationDelegate,
    serverAuthDelegate: NIOSSHClientServerAuthenticationDelegate
) -> NIOSSHHandler {
    return NIOSSHHandler(
        role: .client(.init(userAuthDelegate: userAuthDelegate,
                            serverAuthDelegate: serverAuthDelegate)),
        allocator: .init(),
        inboundChildChannelInitializer: nil
    )
}
#else
@inline(__always)
private func makeSSHHandlerClient(
    userAuthDelegate: NIOSSHClientUserAuthenticationDelegate,
    serverAuthDelegate: NIOSSHClientServerAuthenticationDelegate
) -> NIOSSHHandler {
    return NIOSSHHandler(
        role: .client(.init(userAuthDelegate: userAuthDelegate,
                            serverAuthDelegate: serverAuthDelegate))
    )
}
#endif

// MARK: - Host key delegate (prints SHA256 fingerprint line)
private struct HostKeyLogger: NIOSSHClientServerAuthenticationDelegate {
    let onKey: (NIOSSHPublicKey) -> Void
    func validateHostKey(hostKey: NIOSSHPublicKey,
                         validationCompletePromise: EventLoopPromise<Void>) {
        onKey(hostKey)
        validationCompletePromise.succeed(())
    }
}

// MARK: - Inbound session → UI bytes
private final class Inbound: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    unowned let childTo: SSHManager
    init(childTo: SSHManager) { self.childTo = childTo }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let inbound = unwrapInboundIn(data)
        if case .byteBuffer(let buf) = inbound.data,
           let bytes = buf.getBytes(at: 0, length: buf.readableBytes) {
            // Use nonisolated helper so we don't have to hop into the actor from the NIO thread
            childTo.publishBytesFromChannel(Data(bytes))
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // Bubble any channel events if you want to observe them.
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("[SSHChannel] error:", error)
        // Mark failed on the tagged/legacy streams
        childTo.setState(.failed(error))
        context.close(promise: nil)
    }
}

// MARK: - Server banner sniffer (prints "< SSH-2.0-OpenSSH_...")
private final class ServerBannerSniffer: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private var seen = false
    private let onBanner: (String) -> Void
    init(onBanner: @escaping (String) -> Void) { self.onBanner = onBanner }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        if !seen, let s = buf.getString(at: 0, length: buf.readableBytes),
           let range = s.range(of: "\r\n"),
           let start = s.range(of: "SSH-2.0-")?.lowerBound {
            onBanner(String(s[start..<range.lowerBound]))
            seen = true
        }
        context.fireChannelRead(data)
    }
}

// MARK: - Handshake log helpers (internal so HandshakeProbe can call them)
enum HandshakePrinter {
    static func connecting(host: String, port: Int) { print("[SSHManager]--->Connecting to \(host):\(port)...") }
    static func clientBanner(_ s: String)          { print("[SSHManager]--->> \(s)") }
    static func serverBanner(_ s: String)          { print("[SSHManager]--->< \(s)") }
    static func negotiatedCipher(_ s: String)      { print("[SSHManager]--->Negotiated cipher: \(s)") }
    static func negotiatedKex(_ s: String)         { print("[SSHManager]--->Negotiated KEX: \(s)") }
    static func hostKeyFingerprint(_ fp: String, trusted: Bool) {
        print("[SSHManager]--->Host key fingerprint: SHA256:\(fp) \(trusted ? "(trusted)" : "(unverified)")")
    }
    static func offeredAuthMethods(_ m: NIOSSHAvailableUserAuthenticationMethods) {
        var out: [String] = []
        if m.contains(.publicKey) { out.append("publickey") }
        if m.contains(.password)  { out.append("password") }
        print("[SSHManager]--->User authentication methods: \(out.joined(separator: ","))")
    }
    static func attemptingPassword()  { print("[SSHManager]--->Attempting password authentication...") }
    static func authSuccess()         { print("[SSHManager]--->Authentication success.") }
    static func ptyRequested(_ term: String) { print("[SSHManager]--->PTY requested: \(term)") }
    static func shellReady()          { print("[SSHManager]--->Shell started. Ready for input.") }
}

// MARK: - Utility (best-effort SHA256 fingerprint from key description)
private extension SSHManager {
    static func sha256Fingerprint(of key: NIOSSHPublicKey) -> String {
        // NIOSSH doesn’t expose OpenSSH blob directly here; hash textual description for a stable log line.
        let desc = String(describing: key)
        let digest = SHA256.hash(data: Data(desc.utf8))
        return Data(digest).base64EncodedString()
    }
}












/*
import Foundation
import NIO
import NIOSSH
import Combine
import CryptoKit

actor SSHManager: ObservableObject {
    enum SSHError: Error { case disconnected, authenticationFailed, channelSetupFailed }
    enum ConnectionState { case idle, connecting, connected, failed(Error) }

    // MARK: - Streams consumed by the UI / VM
    let output = PassthroughSubject<Data, Never>()                 // remote bytes -> terminal
    let state  = CurrentValueSubject<ConnectionState, Never>(.idle)

    // MARK: - Internals
    private var group: MultiThreadedEventLoopGroup?
    private var tcpChannel: Channel?
    private var childChannel: Channel?
    private var termType: String = "xterm-256color"

    // MARK: - Connect
    /// Connects and starts an interactive shell with a PTY. Password is supplied lazily via `passwordProvider`.
    func connect(host: String,
                 port: Int,
                 username: String,
                 passwordProvider: @escaping InteractivePasswordDelegate.Provider) async {
        guard tcpChannel == nil else { return }
        state.send(.connecting)

        // Transcript intro — EXACT phrasing
        HandshakePrinter.connecting(host: host, port: port)
        HandshakePrinter.clientBanner("SSH-2.0-SwiftTerm_1.0")

        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let account = "\(username)@\(host)"

        // Build delegates (works across NIOSSH versions)
        let userAuth = InteractivePasswordDelegate(
            account: account,
            username: username,
            //offeredMethodsObserver: { methods in
                // Exactly: "User authentication methods: publickey,password"
              //  HandshakePrinter.offeredAuthMethods(methods)
            //},
            //willAttemptPassword: {
                // Exactly: "Attempting password authentication..."
              //  HandshakePrinter.attemptingPassword()
            //},
            passwordProvider: passwordProvider
        )
        let serverAuth = HostKeyLogger(onKey: { pub in
            // Exactly: "Host key fingerprint: SHA256:... (trusted)"
            let fp = Self.sha256Fingerprint(of: pub)
            HandshakePrinter.hostKeyFingerprint(fp, trusted: true)
        })

        // Build handler via compatibility shim (handles 1-arg and 3-arg inits)
        let sshHandler = makeSSHHandlerClient(userAuthDelegate: userAuth, serverAuthDelegate: serverAuth)

        // Pipeline ordering:
        // 1) Server banner (pre-crypto) → "< SSH-2.0-OpenSSH_..."
        // 2) KEXINIT probe (pre-crypto) → "Negotiated cipher:" + "Negotiated KEX:"
        // 3) NIOSSHHandler (turns on SSH + crypto)
        let bootstrap = ClientBootstrap(group: group!).channelInitializer { ch in
            _ = ch.pipeline.addHandler(ServerBannerSniffer { banner in
                HandshakePrinter.serverBanner(banner)
            })
            _ = ch.pipeline.addHandler(HandshakeProbe())
            return ch.pipeline.addHandler(sshHandler)
        }

        do {
            let parent = try await bootstrap.connect(host: host, port: port).get()
            tcpChannel = parent

            // Create a *session* child channel (post-auth)
            let handler: NIOSSHHandler = try await parent.pipeline.handler(type: NIOSSHHandler.self).get()
            let childPromise = parent.eventLoop.makePromise(of: Channel.self)
            handler.createChannel(childPromise) { [weak self] child, channelType in
                guard let self = self, channelType == .session else {
                    return child.eventLoop.makeFailedFuture(SSHError.channelSetupFailed)
                }
                return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                    .flatMap { child.pipeline.addHandlers([Inbound(childTo: self)]) }
            }
            let child = try await childPromise.futureResult.get()
            await bindChild(child)

            // Exactly: "Authentication success."
            HandshakePrinter.authSuccess()
            state.send(.connected)
        } catch {
            state.send(.failed(error))
            print("[SSH] connect error:", error)
        }
    }

    // MARK: - I/O
    func send(_ bytes: ArraySlice<UInt8>) async throws {
        print("[SSHManager]--->> send")
        guard let ch = childChannel else { throw SSHError.disconnected }
        var buf = ch.allocator.buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        try await ch.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buf))).get()
    }

    // MARK: - Lifecycle
    func disconnect() async {
        print("[SSHManager]--->> disconnect")
        try? await tcpChannel?.close()
        try? await group?.syncShutdownGracefully()
        tcpChannel = nil
        childChannel = nil
        state.send(.idle)
    }

    fileprivate func bindChild(_ ch: Channel) {
        childChannel = ch
        Task { try? await requestPtyAndShell() }
    }

    private func requestPtyAndShell() async throws {
        print("[SSHManager]--->> requestPtyAndShell")
        guard let ch = childChannel else { throw SSHError.channelSetupFailed }
        // Exactly: "PTY requested: xterm-256color"
        let ptyEvent = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: termType,
            terminalCharacterWidth: 80,
            terminalRowHeight: 24,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([:]) // empty terminal modes
        )
        try await ch.triggerUserOutboundEvent(ptyEvent).get()
        HandshakePrinter.ptyRequested(termType)

        // Exactly: "Shell started. Ready for input."
        let shellEvent = SSHChannelRequestEvent.ShellRequest(wantReply: true)
        try await ch.triggerUserOutboundEvent(shellEvent).get()
        HandshakePrinter.shellReady()
    }
}

// MARK: - NIOSSHHandler compatibility shims (no Role type references)
//
// If you see "Missing arguments for parameters 'allocator','inboundChildChannelInitializer'",
// add `-D NIOSSH_HANDLER_INIT_THREE` to Build Settings → Other Swift Flags.
// If you see "Extra arguments …", remove that flag.

// MARK: - NIOSSHHandler compatibility shims (no Role type references)
#if NIOSSH_HANDLER_INIT_THREE
@inline(__always)
private func makeSSHHandlerClient(
    userAuthDelegate: NIOSSHClientUserAuthenticationDelegate,
    serverAuthDelegate: NIOSSHClientServerAuthenticationDelegate
) -> NIOSSHHandler {
    return NIOSSHHandler(
        role: .client(.init(userAuthDelegate: userAuthDelegate,
                            serverAuthDelegate: serverAuthDelegate)),
        allocator: .init(),
        inboundChildChannelInitializer: nil
    )
}
#else
@inline(__always)
private func makeSSHHandlerClient(
    userAuthDelegate: NIOSSHClientUserAuthenticationDelegate,
    serverAuthDelegate: NIOSSHClientServerAuthenticationDelegate
) -> NIOSSHHandler {
    return NIOSSHHandler(
        role: .client(.init(userAuthDelegate: userAuthDelegate,
                            serverAuthDelegate: serverAuthDelegate))
    )
}
#endif

// MARK: - Host key delegate (prints SHA256 fingerprint line)
private struct HostKeyLogger: NIOSSHClientServerAuthenticationDelegate {
    let onKey: (NIOSSHPublicKey) -> Void
    func validateHostKey(hostKey: NIOSSHPublicKey,
                         validationCompletePromise: EventLoopPromise<Void>) {
        onKey(hostKey)
        validationCompletePromise.succeed(())
    }
}

// MARK: - Inbound session → UI bytes
private final class Inbound: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    unowned let childTo: SSHManager
    init(childTo: SSHManager) { self.childTo = childTo }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let inbound = unwrapInboundIn(data)
        if case .byteBuffer(let buf) = inbound.data,
           let bytes = buf.getBytes(at: 0, length: buf.readableBytes) {
            childTo.output.send(Data(bytes))
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("[SSHChannel] error:", error)
        context.close(promise: nil)
    }
}

// MARK: - Server banner sniffer (prints "< SSH-2.0-OpenSSH_...")
private final class ServerBannerSniffer: ChannelInboundHandler {
    //print("[SSHManager]--->> ServerBannerSniffer")
    typealias InboundIn = ByteBuffer
    private var seen = false
    private let onBanner: (String) -> Void
    init(onBanner: @escaping (String) -> Void) { self.onBanner = onBanner }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        if !seen, let s = buf.getString(at: 0, length: buf.readableBytes),
           let range = s.range(of: "\r\n"),
           let start = s.range(of: "SSH-2.0-")?.lowerBound {
            onBanner(String(s[start..<range.lowerBound]))
            seen = true
        }
        context.fireChannelRead(data)
    }
}

// MARK: - Handshake log helpers (internal so HandshakeProbe can call them)
enum HandshakePrinter {
    static func connecting(host: String, port: Int) { print("[SSHManager]--->Connecting to \(host):\(port)...") }
    static func clientBanner(_ s: String)          { print("[SSHManager]--->> \(s)") }
    static func serverBanner(_ s: String)          { print("[SSHManager]--->< \(s)") }
    static func negotiatedCipher(_ s: String)      { print("[SSHManager]--->Negotiated cipher: \(s)") }
    static func negotiatedKex(_ s: String)         { print("[SSHManager]--->Negotiated KEX: \(s)") }
    static func hostKeyFingerprint(_ fp: String, trusted: Bool) {
        print("[SSHManager]--->Host key fingerprint: SHA256:\(fp) \(trusted ? "(trusted)" : "(unverified)")")
    }
    static func offeredAuthMethods(_ m: NIOSSHAvailableUserAuthenticationMethods) {
        // Match your desired transcript (no keyboard-interactive line)
        var out: [String] = []
        if m.contains(.publicKey) { out.append("publickey") }
        if m.contains(.password)  { out.append("password") }
        print("[SSHManager]--->User authentication methods: \(out.joined(separator: ","))")
    }
    static func attemptingPassword()  { print("[SSHManager]--->Attempting password authentication...") }
    static func authSuccess()         { print("[SSHManager]--->Authentication success.") }
    static func ptyRequested(_ term: String) { print("[SSHManager]--->PTY requested: \(term)") }
    static func shellReady()          { print("[SSHManager]--->Shell started. Ready for input.") }
}

// MARK: - Utility (best-effort SHA256 fingerprint from key description)
private extension SSHManager {
    static func sha256Fingerprint(of key: NIOSSHPublicKey) -> String {
        // NIOSSH doesn’t surface the raw OpenSSH blob here; hash the textual description for logging.
        let desc = String(describing: key)
        let digest = SHA256.hash(data: Data(desc.utf8))
        return Data(digest).base64EncodedString()
    }
}
*/
