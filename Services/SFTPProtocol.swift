//
//  SFTPType.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 10/29/25.
//


//
//  SFTPType.swift
//  SFTPDemo
//
//  Created by Jesse Herring on 10/20/25.
//


// Services/SFTPProtocol.swift
import Foundation
import NIOCore

// SFTP v3 constants & simple packet model.
// Packet = [uint32 length][byte type][uint32 requestId?][payload…]
// See draft-ietf-secsh-filexfer and de-facto v3 implementations.

enum SFTPType: UInt8 {
    case init_   = 1   // client->server, no requestId
    case version = 2   // server->client
    case open    = 3
    case close   = 4
    case read    = 5
    case write   = 6
    case lstat   = 7
    case fstat   = 8
    case setstat = 9
    case fsetstat = 10
    case opendir = 11
    case readdir = 12
    case remove  = 13
    case mkdir   = 14
    case rmdir   = 15
    case realpath = 16
    case stat    = 17
    case rename  = 18
    case readlink = 19
    case symlink = 20
    case status  = 101
    case handle  = 102
    case data    = 103
    case name    = 104
    case attrs   = 105
}

enum SFTPStatusCode: UInt32 {
    case ok = 0
    case eof = 1
    case noSuchFile = 2
    case permissionDenied = 3
    case failure = 4
}

struct SFTPName {
    var filename: String
    var longname: String
    var attrs: SFTPAttrs
}

struct SFTPAttrs {
    var size: UInt64?
    var permissions: UInt32?
    var mtime: UInt32?
}

enum SFTPMessage {
    case version(UInt32)
    case status(id: UInt32, code: UInt32, message: String)
    case handle(id: UInt32, data: ByteBuffer)
    case data(id: UInt32, payload: ByteBuffer)
    case name(id: UInt32, entries: [SFTPName])
    case attrs(id: UInt32, attrs: SFTPAttrs)
}

// MARK: - ByteBuffer IO helpers
extension ByteBuffer {
    mutating func readUInt32() -> UInt32? {
        readInteger(endianness: .big, as: UInt32.self)
    }
    mutating func readUInt64() -> UInt64? {
        readInteger(endianness: .big, as: UInt64.self)
    }
    mutating func readByte() -> UInt8? {
        readInteger(endianness: .big, as: UInt8.self)
    }
    mutating func readSFTPString() -> String? {
        guard let len = readUInt32(), readableBytes >= Int(len),
              let bytes = readBytes(length: Int(len)) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
    mutating func readSFTPBuffer() -> ByteBuffer? {
        guard let len = readUInt32(), readableBytes >= Int(len) else { return nil }
        return readSlice(length: Int(len))
    }

    mutating func writeUInt32(_ v: UInt32) {
        writeInteger(v, endianness: .big)
    }
    mutating func writeUInt64(_ v: UInt64) {
        writeInteger(v, endianness: .big)
    }
    mutating func writeByte(_ v: UInt8) {
        writeInteger(v, endianness: .big)
    }
    mutating func writeSFTPString(_ s: String) {
        let d = Array(s.utf8)
        writeUInt32(UInt32(d.count))
        writeBytes(d)
    }
    mutating func writeSFTPData(_ data: ByteBuffer) {
        writeUInt32(UInt32(data.readableBytes))
        var copy = data
        writeBuffer(&copy)
    }
}
