//
//  SFTPClient.swift
//  SSHSwiftUIDemo
//
//  Fully async SFTPv3 client for use with NIOSSH child channels.
//  Handles INIT, VERSION, REALPATH, OPENDIR, READDIR, CLOSE, READ, WRITE, MKDIR, REMOVE, RENAME.
//  Includes timeouts and diagnostic logging.
//
//

import Foundation
import NIOCore
import NIOSSH

final class SFTPClient {
    enum SFTPError: Error {
        case badPacket
        case statusFailure(code: UInt32, message: String)
        case unexpected
        case timeout
    }

    private let channel: Channel
    private let allocator = ByteBufferAllocator()
    private var pending: [UInt32: EventLoopPromise<SFTPMessage>] = [:]
    private var requestCounter: UInt32 = 1
    private var inboundBuf = ByteBufferAllocator().buffer(capacity: 0)

    init(channel: Channel) {
        self.channel = channel
        _ = channel.pipeline.addHandler(InboundHandler(owner: self))
    }

    // MARK: - Lifecycle

    func initialize() async throws {
        print("[SFTP] INIT →")
        var inner = allocator.buffer(capacity: 5)
        inner.writeByte(SFTPType.init_.rawValue)
        inner.writeUInt32(3)
        try await sendRaw(inner)
        let msg = try await readAny()
        if case let .version(v) = msg {
            print("[SFTP] VERSION ⇦ \(v)")
        } else {
            print("[SFTP] expected VERSION, got \(msg)")
            throw SFTPError.badPacket
        }
    }

    // MARK: - Directory listing

    func list(path: String) async throws -> [SFTPName] {
        print("[SFTP][list] begin path=\(path)")
        let canonical = try await realpath(path: path)
        print("[SFTP][list] canonical=\(canonical)")
        let handle = try await opendir(path: canonical)
        defer { Task { try? await closeHandle(handle) } }

        var out: [SFTPName] = []
        while true {
            let names = try await readdir(handle: handle)
            if names.isEmpty { break }
            out.append(contentsOf: names)
        }
        print("[SFTP][list] done count=\(out.count)")
        return out
    }

    // MARK: - File ops

    func download(path: String, maxBytes: Int = 2_000_000) async throws -> Data {
        let handle = try await open(path: path, pflags: 0x0000_0001)
        defer { Task { try? await closeHandle(handle) } }

        var offset: UInt64 = 0
        var data = Data()
        while true {
            let chunk = try await read(handle: handle, offset: offset, length: 64 * 1024)
            if chunk.readableBytes == 0 { break }
            data.append(contentsOf: chunk.readableBytesView)
            offset += UInt64(chunk.readableBytes)
            if data.count >= maxBytes { break }
        }
        return data
    }

    func upload(toPath path: String, data: Data) async throws {
        var buf = allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        let pflags: UInt32 = 0x0000_0002 | 0x0000_0008 | 0x0000_0004 // create|truncate|write
        let handle = try await open(path: path, pflags: pflags)
        defer { Task { try? await closeHandle(handle) } }

        var offset: UInt64 = 0
        while buf.readableBytes > 0 {
            let chunk = buf.readSlice(length: min(buf.readableBytes, 64 * 1024))!
            try await write(handle: handle, offset: offset, data: chunk)
            offset += UInt64(chunk.readableBytes)
        }
    }

    func mkdir(path: String) async throws {
        let id = nextId()
        var p = allocator.buffer(capacity: 0)
        p.writeByte(SFTPType.mkdir.rawValue)
        p.writeUInt32(id)
        p.writeSFTPString(path)
        p.writeUInt32(0) // empty attrs
        print("[SFTP] MKDIR → \(path) id=\(id)")
        try await sendRaw(p)
        _ = try await expectStatusOK(id: id)
    }

    func remove(path: String) async throws {
        let id = nextId()
        var p = allocator.buffer(capacity: 0)
        p.writeByte(SFTPType.remove.rawValue)
        p.writeUInt32(id)
        p.writeSFTPString(path)
        print("[SFTP] REMOVE → \(path) id=\(id)")
        try await sendRaw(p)
        _ = try await expectStatusOK(id: id)
    }

    func rename(from: String, to: String) async throws {
        let id = nextId()
        var p = allocator.buffer(capacity: 0)
        p.writeByte(SFTPType.rename.rawValue)
        p.writeUInt32(id)
        p.writeSFTPString(from)
        p.writeSFTPString(to)
        print("[SFTP] RENAME → \(from) → \(to) id=\(id)")
        try await sendRaw(p)
        _ = try await expectStatusOK(id: id)
    }

    // MARK: - Low-level operations

    private func realpath(path: String) async throws -> String {
        let id = nextId()
        var p = allocator.buffer(capacity: 0)
        p.writeByte(SFTPType.realpath.rawValue)
        p.writeUInt32(id)
        p.writeSFTPString(path)
        print("[SFTP] REALPATH → \(path) id=\(id)")
        try await sendRaw(p)

        let msg = try await waitMsg(id: id)
        switch msg {
        case .name(_, let entries):
            if let first = entries.first {
                print("[SFTP] REALPATH ⇦ \(first.filename)")
                return first.filename
            }
            fallthrough
        default:
            throw SFTPError.badPacket
        }
    }

    private func opendir(path: String) async throws -> ByteBuffer {
        let id = nextId()
        var p = allocator.buffer(capacity: 0)
        p.writeByte(SFTPType.opendir.rawValue)
        p.writeUInt32(id)
        p.writeSFTPString(path)
        print("[SFTP] OPENDIR → \(path) id=\(id)")
        try await sendRaw(p)
        let msg = try await waitMsg(id: id, timeoutSeconds: 10)
        switch msg {
        case .handle(_, let data): return data
        case .status(_, let code, let message):
            throw SFTPError.statusFailure(code: code, message: message)
        default: throw SFTPError.badPacket
        }
    }

    private func readdir(handle: ByteBuffer) async throws -> [SFTPName] {
        let id = nextId()
        var p = allocator.buffer(capacity: 0)
        p.writeByte(SFTPType.readdir.rawValue)
        p.writeUInt32(id)
        p.writeSFTPData(handle)
        print("[SFTP] READDIR → id=\(id)")
        try await sendRaw(p)
        let msg = try await waitMsg(id: id, timeoutSeconds: 10)
        switch msg {
        case .name(_, let list):
            print("[SFTP] READDIR ⇦ \(list.count) entries")
            return list
        case .status(_, let code, _):
            if code == SFTPStatusCode.eof.rawValue { return [] }
            throw SFTPError.statusFailure(code: code, message: "READDIR failed")
        default: throw SFTPError.badPacket
        }
    }

    private func closeHandle(_ handle: ByteBuffer) async throws {
        let id = nextId()
        var p = allocator.buffer(capacity: 0)
        p.writeByte(SFTPType.close.rawValue)
        p.writeUInt32(id)
        p.writeSFTPData(handle)
        print("[SFTP] CLOSE → id=\(id)")
        try await sendRaw(p)
        _ = try await expectStatusOK(id: id)
    }

    private func open(path: String, pflags: UInt32) async throws -> ByteBuffer {
        let id = nextId()
        var p = allocator.buffer(capacity: 0)
        p.writeByte(SFTPType.open.rawValue)
        p.writeUInt32(id)
        p.writeSFTPString(path)
        p.writeUInt32(pflags)
        p.writeUInt32(0) // empty attrs
        print("[SFTP] OPEN → \(path) flags=\(String(format:"0x%X", pflags)) id=\(id)")
        try await sendRaw(p)
        let msg = try await waitMsg(id: id, timeoutSeconds: 10)
        switch msg {
        case .handle(_, let data): return data
        case .status(_, let code, let message):
            throw SFTPError.statusFailure(code: code, message: message)
        default: throw SFTPError.badPacket
        }
    }

    private func read(handle: ByteBuffer, offset: UInt64, length: Int) async throws -> ByteBuffer {
        let id = nextId()
        var p = allocator.buffer(capacity: 0)
        p.writeByte(SFTPType.read.rawValue)
        p.writeUInt32(id)
        p.writeSFTPData(handle)
        p.writeUInt64(offset)
        p.writeUInt32(UInt32(length))
        try await sendRaw(p)
        let msg = try await waitMsg(id: id, timeoutSeconds: 10)
        switch msg {
        case .data(_, let data): return data
        case .status(_, let code, _):
            if code == SFTPStatusCode.eof.rawValue { return allocator.buffer(capacity: 0) }
            throw SFTPError.statusFailure(code: code, message: "READ failed")
        default: throw SFTPError.badPacket
        }
    }

    private func write(handle: ByteBuffer, offset: UInt64, data: ByteBuffer) async throws {
        let id = nextId()
        var p = allocator.buffer(capacity: 0)
        p.writeByte(SFTPType.write.rawValue)
        p.writeUInt32(id)
        p.writeSFTPData(handle)
        p.writeUInt64(offset)
        p.writeSFTPData(data)
        try await sendRaw(p)
        _ = try await expectStatusOK(id: id)
    }

    // MARK: - Transport helpers

    private func nextId() -> UInt32 { defer { requestCounter &+= 1 }; return requestCounter }

    private func sendRaw(_ inner: ByteBuffer) async throws {
        // Frame: [length][payload]
        var msg = allocator.buffer(capacity: 4 + inner.readableBytes)
        msg.writeUInt32(UInt32(inner.readableBytes))
        var copy = inner
        msg.writeBuffer(&copy)
        try await channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(msg))).get()
    }

    private func waitMsg(id: UInt32, timeoutSeconds: Double = 5.0) async throws -> SFTPMessage {
        let p = channel.eventLoop.makePromise(of: SFTPMessage.self)
        pending[id] = p
        return try await withThrowingTaskGroup(of: SFTPMessage.self) { group in
            group.addTask { try await p.futureResult.get() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw SFTPError.timeout
            }
            let msg = try await group.next()!
            group.cancelAll()
            return msg
        }
    }

    private func expectStatusOK(id: UInt32) async throws {
        let msg = try await waitMsg(id: id, timeoutSeconds: 10)
        switch msg {
        case .status(_, let code, let message):
            if code == SFTPStatusCode.ok.rawValue { return }
            throw SFTPError.statusFailure(code: code, message: message)
        default: throw SFTPError.badPacket
        }
    }

    private func readAny(timeoutSeconds: Double = 5.0) async throws -> SFTPMessage {
        let p = channel.eventLoop.makePromise(of: SFTPMessage.self)
        pending[0] = p
        return try await withThrowingTaskGroup(of: SFTPMessage.self) { group in
            group.addTask { try await p.futureResult.get() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw SFTPError.timeout
            }
            let msg = try await group.next()!
            group.cancelAll()
            return msg
        }
    }

    // MARK: - Inbound decoder

    fileprivate func onInboundPacket(_ packet: SFTPMessage) {
        let id: UInt32 = {
            switch packet {
            case .version: return 0
            case .status(let i, _, _),
                 .handle(let i, _),
                 .data(let i, _),
                 .name(let i, _),
                 .attrs(let i, _): return i
            }
        }()
        if let p = pending.removeValue(forKey: id) {
            p.succeed(packet)
        } else {
            print("[SFTP][warn] no waiter for id=\(id)")
        }
    }

    // MARK: - ATTRS skipping

    /// Consume SFTP v3 ATTRS according to flags so the frame is fully drained.
    private static func skipAttrs(_ b: inout ByteBuffer) {
        guard let flags: UInt32 = b.readInteger(endianness: .big) else { return }
        if (flags & 0x0000_0001) != 0 { _ = b.readInteger(endianness: .big, as: UInt64.self) } // SIZE
        if (flags & 0x0000_0002) != 0 { _ = b.readInteger(endianness: .big, as: UInt32.self); _ = b.readInteger(endianness: .big, as: UInt32.self) } // UID,GID
        if (flags & 0x0000_0004) != 0 { _ = b.readInteger(endianness: .big, as: UInt32.self) } // PERMISSIONS
        if (flags & 0x0000_0008) != 0 { _ = b.readInteger(endianness: .big, as: UInt32.self); _ = b.readInteger(endianness: .big, as: UInt32.self) } // ATIME,MTIME
        if (flags & 0x8000_0000) != 0 {
            // EXTENDED: count + N × (type:string, data:string)
            guard let count: UInt32 = b.readInteger(endianness: .big) else { return }
            for _ in 0..<count {
                _ = b.readSFTPString()
                _ = b.readSFTPString()
            }
        }
    }

    private final class InboundHandler: ChannelInboundHandler {
        typealias InboundIn = SSHChannelData
        unowned let owner: SFTPClient
        init(owner: SFTPClient) { self.owner = owner }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let d = unwrapInboundIn(data)
            guard case .byteBuffer(var buf) = d.data else { return }
            owner.inboundBuf.writeBuffer(&buf)
            parseFrames()
        }

        private func parseFrames() {
            var b = owner.inboundBuf
            while true {
                // Need full [len][payload]
                guard let length: UInt32 = b.getInteger(at: b.readerIndex, endianness: .big),
                      b.readableBytes >= 4 + Int(length) else { break }

                _ = b.readInteger(endianness: .big, as: UInt32.self) // consume length
                guard var payload = b.readSlice(length: Int(length)) else { break }

                // Each payload begins with packet type
                guard let typeByte: UInt8 = payload.readInteger(),
                      let type = SFTPType(rawValue: typeByte) else { continue }

                switch type {
                case .version:
                    if let v: UInt32 = payload.readInteger(endianness: .big) {
                        owner.onInboundPacket(.version(v))
                    }

                case .status:
                    guard let id: UInt32 = payload.readInteger(endianness: .big),
                          let code: UInt32 = payload.readInteger(endianness: .big),
                          let msg = payload.readSFTPString(),
                          let _ = payload.readSFTPString() else { break } // language tag
                    owner.onInboundPacket(.status(id: id, code: code, message: msg))

                case .handle:
                    guard let id: UInt32 = payload.readInteger(endianness: .big),
                          let data = payload.readSFTPBuffer() else { break }
                    owner.onInboundPacket(.handle(id: id, data: data))

                case .data:
                    guard let id: UInt32 = payload.readInteger(endianness: .big),
                          let data = payload.readSFTPBuffer() else { break }
                    owner.onInboundPacket(.data(id: id, payload: data))

                    // inside switch(type) { ... case .name: ... }
                    case .name:
                        guard let id: UInt32 = payload.readInteger(endianness: .big),
                              let count: UInt32 = payload.readInteger(endianness: .big) else { break }

                        var entries: [SFTPName] = []
                        entries.reserveCapacity(Int(count))

                        for _ in 0..<count {
                            guard let filename = payload.readSFTPString(),
                                  var longname = payload.readSFTPString()
                            else { break }

                            // === NEW: parse ATTRS flags and mode so we know file type ===
                            let (modeOpt, _) = SFTPClient.readAttrs(&payload) // drains ATTRS correctly

                            // If server gave us empty/placeholder longname, synthesize one
                            if longname.isEmpty || longname == "_" {
                                if let mode = modeOpt {
                                    // POSIX file type bits: S_IFMT 0170000; S_IFDIR 0040000; S_IFLNK 0120000
                                    let fileType = mode & 0o170000
                                    let firstChar: Character
                                    switch fileType {
                                    case 0o040000: firstChar = "d" // directory
                                    case 0o120000: firstChar = "l" // symlink (we treat as dir-ish in UI)
                                    default:       firstChar = "-" // regular/other
                                    }
                                    // Synthesize minimal ls-like longname so your UI logic keeps working.
                                    // We don’t try to reconstruct permissions string—just the leading type.
                                    longname = String(firstChar)
                                } else {
                                    // Last resort: dot entries look like dirs
                                    longname = (filename == "." || filename == "..") ? "d" : "-"
                                }
                            }

                            entries.append(SFTPName(filename: filename, longname: longname, attrs: SFTPAttrs()))
                        }
                        owner.onInboundPacket(.name(id: id, entries: entries))

                case .attrs:
                    guard let id: UInt32 = payload.readInteger(endianness: .big) else { break }
                    // Drain the ATTRS body so frame ends exactly here
                    SFTPClient.skipAttrs(&payload)
                    owner.onInboundPacket(.attrs(id: id, attrs: SFTPAttrs()))

                default:
                    // Drain unknown packet (payload slice ensures safe discard)
                    print("[SFTP][decode] unhandled type=\(type)")
                }
                // Any unread bytes in `payload` are safely discarded here because it's a slice of the frame.
            }
            owner.inboundBuf = b
        }
    }
    
    /// Read SFTP v3 ATTRS and return (permissionsMode, extendedCount). Fully drains the structure so framing stays aligned.
    private static func readAttrs(_ b: inout ByteBuffer) -> (permissions: UInt32?, extendedCount: UInt32) {
        guard let flags: UInt32 = b.readInteger(endianness: .big) else { return (nil, 0) }
        var mode: UInt32? = nil

        if (flags & 0x0000_0001) != 0 { _ = b.readInteger(endianness: .big, as: UInt64.self) } // SIZE
        if (flags & 0x0000_0002) != 0 { _ = b.readInteger(endianness: .big, as: UInt32.self); _ = b.readInteger(endianness: .big, as: UInt32.self) } // UID,GID
        if (flags & 0x0000_0004) != 0 { mode = b.readInteger(endianness: .big, as: UInt32.self) } // PERMISSIONS
        if (flags & 0x0000_0008) != 0 { _ = b.readInteger(endianness: .big, as: UInt32.self); _ = b.readInteger(endianness: .big, as: UInt32.self) } // ATIME,MTIME

        var extCount: UInt32 = 0
        if (flags & 0x8000_0000) != 0 {
            extCount = b.readInteger(endianness: .big, as: UInt32.self) ?? 0
            for _ in 0..<extCount {
                _ = b.readSFTPString() // type
                _ = b.readSFTPString() // data
            }
        }
        return (mode, extCount)
    }
}
