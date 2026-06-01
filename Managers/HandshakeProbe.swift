//
//  HandshakeProbe.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 7/26/25.
//


// Managers/HandshakeProbe.swift
// Sniffs SSH_MSG_KEXINIT in both directions and prints the true negotiated
// algorithms (KEX, hostkey, enc/MAC c2s & s2c). Works with stock NIOSSH.

// Managers/HandshakeProbe.swift
// Sniffs SSH_MSG_KEXINIT in both directions and prints the true negotiated
// algorithms (KEX, hostkey, enc/MAC c2s & s2c). Works with stock NIOSSH.

import NIO

final class HandshakeProbe: ChannelDuplexHandler {
    typealias InboundIn  = ByteBuffer
    typealias OutboundIn = ByteBuffer
    
    // Captured KEXINITs
    private var clientInit: KexInit?
    private var serverInit: KexInit?
    private var printed = false
    
    // MARK: Inbound (server → client)
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        if let k = parseKexInit(from: buf) {
            serverInit = k
            maybePrintNegotiation()
        }
        // Always forward unchanged
        context.fireChannelRead(data)
    }
    
    // MARK: Outbound (client → server)
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buf = unwrapOutboundIn(data)
        if let k = parseKexInit(from: buf) {
            clientInit = k
            maybePrintNegotiation()
        }
        context.write(data, promise: promise)
    }
    
    // MARK: Compute and print once
    private func maybePrintNegotiation() {
        guard !printed, let c = clientInit, let s = serverInit else { return }
        printed = true
        
        // RFC 4253 §7: pick the first client preference that the server also lists (per direction)
        let kex     = firstMatch(c.kex,     s.kex)     ?? "(unknown)"
        let hostkey = firstMatch(c.hostkey, s.hostkey)
        
        let c2sEnc  = firstMatch(c.encC2S,  s.encC2S)  ?? "(unknown)"
        let s2cEnc  = firstMatch(c.encS2C,  s.encS2C)  ?? "(unknown)"
        let c2sMac  = firstMatch(c.macC2S,  s.macC2S)
        let s2cMac  = firstMatch(c.macS2C,  s.macS2C)
        
        // Print in the exact style you wanted
        print("Negotiated KEX: \(kex)")
        if let hk = hostkey { print("Host key algo: \(hk)") }
        
        let c2sAEAD = isAEAD(c2sEnc)
        let s2cAEAD = isAEAD(s2cEnc)
        print("Negotiated cipher: client->server: \(c2sEnc)\(c2sAEAD ? " (AEAD)" : "")")
        print("Negotiated cipher: server->client: \(s2cEnc)\(s2cAEAD ? " (AEAD)" : "")")
        
        if !c2sAEAD { print("Negotiated MAC c->s: \(c2sMac ?? "(none)")") }
        if !s2cAEAD { print("Negotiated MAC s->c: \(s2cMac ?? "(none)")") }
    }
    
    // MARK: Helpers
    
    private func firstMatch(_ clientList: [String], _ serverList: [String]) -> String? {
        for algo in clientList where serverList.contains(algo) { return algo }
        return nil
    }
    
    private func isAEAD(_ enc: String) -> Bool {
        let e = enc.lowercased()
        return e.contains("gcm@openssh.com") || e.contains("chacha20-poly1305")
    }
}

// MARK: - Minimal RFC 4253 KEXINIT parser (works on *copies* of ByteBuffer)

private struct KexInit {
    let kex:     [String]
    let hostkey: [String]
    let encC2S:  [String]
    let encS2C:  [String]
    let macC2S:  [String]
    let macS2C:  [String]
    // compression + languages omitted; not needed for printing here
}

private func parseKexInit(from buf: ByteBuffer) -> KexInit? {
    // Work on a copy so we don't advance the real readerIndex
    var b = buf
    guard b.readableBytes >= 5 else { return nil }
    
    // SSH binary packet protocol:
    // uint32 packet_length; byte padding_length; payload[packet_length - padLen - 1]; padding[padLen]
    guard let packetLen: UInt32 = b.getInteger(at: b.readerIndex) else { return nil }
    let total = 4 + Int(packetLen)
    guard b.readableBytes >= total else { return nil } // not a whole packet yet
    
    var idx = b.readerIndex
    idx += 4
    guard let padLen: UInt8 = b.getInteger(at: idx) else { return nil }
    idx += 1
    let payloadLen = Int(packetLen) - 1 - Int(padLen)
    guard payloadLen > 0, let payloadSlice = b.getSlice(at: idx, length: payloadLen) else { return nil }
    
    var p = payloadSlice
    // First byte of payload is SSH message number (20 = SSH_MSG_KEXINIT)
    guard let msg: UInt8 = p.readInteger(), msg == 20 else { return nil }
    
    // cookie (16 bytes)
    guard let _ = p.readSlice(length: 16) else { return nil }
    
    // Ten name-lists, then a boolean + reserved uint32
    guard let kex          = p.readNameList(),
          let hostkey      = p.readNameList(),
          let encC2S       = p.readNameList(),
          let encS2C       = p.readNameList(),
          let macC2S       = p.readNameList(),
          let macS2C       = p.readNameList(),
          let _compC2S     = p.readNameList(),
          let _compS2C     = p.readNameList(),
          let _langC2S     = p.readNameList(),
          let _langS2C     = p.readNameList(),
          let _firstFollows: UInt8  = p.readInteger(),
          let _reserved:    UInt32 = p.readInteger()
    else { return nil }
    
    return KexInit(kex: kex,
                   hostkey: hostkey,
                   encC2S: encC2S,
                   encS2C: encS2C,
                   macC2S: macC2S,
                   macS2C: macS2C)
}

private extension ByteBuffer {
    mutating func readSSHString() -> ByteBuffer? {
        guard let len: UInt32 = readInteger() else { return nil }
        guard len <= readableBytes else { return nil }
        return readSlice(length: Int(len))
    }
    mutating func readNameList() -> [String]? {
        guard var s = readSSHString() else { return nil }
        guard let str = s.readString(length: s.readableBytes) else { return [] }
        if str.isEmpty { return [] }
        return str.split(separator: ",").map { String($0) }
    }
}
