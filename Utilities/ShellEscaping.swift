//
//  ShellEscaping.swift
//  SSHSwiftUIDemo
//
//  Hardened POSIX shell escaping helpers.
//  Use when you MUST interpolate values into /bin/sh commands.
//

import Foundation
import OSLog

enum ShellEscaping {

    private static let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "ShellEscaping")

    /// POSIX-safe single-quote wrapper for sh.
    ///
    /// A literal single quote inside becomes: '"'"'
    /// Example:  abc'def  ->  'abc'"'"'def'
    static func singleQuoted(_ s: String) -> String {
        guard !s.isEmpty else {
            log.debug("[ShellEscaping] singleQuoted empty -> ''")
            return "''"
        }

        // This is the exact POSIX sequence: end quote, literal ', start quote.
        // Swift string content:  '"'"'
        let quoteEscape = "'\"'\"'"

        let escaped = s.replacingOccurrences(of: "'", with: quoteEscape)
        let out = "'" + escaped + "'"

        log.debug("[ShellEscaping] singleQuoted inBytes=\(s.utf8.count) outBytes=\(out.utf8.count)")
        return out
    }

    /// Semantic alias for quoting filesystem paths.
    static func path(_ p: String) -> String {
        let out = singleQuoted(p)
        log.debug("[ShellEscaping] path quoted inBytes=\(p.utf8.count)")
        return out
    }

    /// Builds `NAME='value'` safely for sh.
    /// Validates NAME: [A-Za-z_][A-Za-z0-9_]*
    static func shAssignment(varName: String, value: String) -> String {
        precondition(isValidShVarName(varName), "[ShellEscaping] Invalid sh var name: \(varName)")
        let out = "\(varName)=\(singleQuoted(value))"
        log.debug("[ShellEscaping] shAssignment name=\(varName, privacy: .public) valueBytes=\(value.utf8.count)")
        return out
    }

    /// Builds `export NAME='value'` safely for sh.
    static func shExport(varName: String, value: String) -> String {
        let out = "export \(shAssignment(varName: varName, value: value))"
        log.debug("[ShellEscaping] shExport name=\(varName, privacy: .public)")
        return out
    }

    /// Joins already-escaped args with spaces.
    static func joinArgs(_ alreadyEscapedArgs: [String]) -> String {
        let out = alreadyEscapedArgs.joined(separator: " ")
        log.debug("[ShellEscaping] joinArgs count=\(alreadyEscapedArgs.count) outBytes=\(out.utf8.count)")
        return out
    }

    // MARK: - Validation (ASCII deterministic)

    static func isValidShVarName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        var it = name.unicodeScalars.makeIterator()
        guard let first = it.next() else { return false }

        guard isAsciiAlpha(first) || first == "_" else { return false }

        while let u = it.next() {
            if !(isAsciiAlpha(u) || isAsciiDigit(u) || u == "_") { return false }
        }
        return true
    }

    @inline(__always)
    private static func isAsciiAlpha(_ u: UnicodeScalar) -> Bool {
        let v = u.value
        return (v >= 65 && v <= 90) || (v >= 97 && v <= 122) // A-Z or a-z
    }

    @inline(__always)
    private static func isAsciiDigit(_ u: UnicodeScalar) -> Bool {
        let v = u.value
        return (v >= 48 && v <= 57) // 0-9
    }
}
