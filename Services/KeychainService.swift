//
//  KeychainError.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 7/29/25.
//


// Services/KeychainService.swift
// Simple keychain wrapper for storing SSH passwords by account (e.g. "user@host").
// iOS 16+, console-verbose, with clear error propagation.

import Foundation
import Security

enum KeychainService {
    /// Look up a password for an `account` (e.g. "user@host"). Returns `nil` if not found.
    static func password(account: String) throws -> String? {
        print("[KeychainService] password")
        let query: [String: Any] = [
            kSecClass as String:             kSecClassGenericPassword,
            kSecAttrAccount as String:       account,
            kSecReturnData as String:        true,
            kSecMatchLimit as String:        kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let pw = String(data: data, encoding: .utf8) else {
                return nil
            }
            return pw

        case errSecItemNotFound:
            return nil

        default:
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    /// Back-compat shim for older call sites expecting a non-optional return.
    /// If no password exists, this throws `errSecItemNotFound`.
    static func loadPassword(account: String) throws -> String {
        print("[KeychainService] loadPassword")
        if let pw = try password(account: account) {
            return pw
        }
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecItemNotFound))
    }

    /// Save or update a password for an `account`.
    static func savePassword(account: String, password: String) throws {
        print("[KeychainService] savePassword")
        let passwordData = password.data(using: .utf8) ?? Data()

        // Try update first
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        let attrs: [String: Any] = [kSecValueData as String: passwordData]

        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess { return }

        if updateStatus == errSecItemNotFound {
            // Add instead
            var add = query
            add[kSecValueData as String] = passwordData
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
            }
        } else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
        }
    }

    /// Delete the password for an `account` if present.
    static func delete(account: String) throws {
        print("[KeychainService] delete")
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
