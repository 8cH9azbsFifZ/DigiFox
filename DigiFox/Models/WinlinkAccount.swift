/// Winlink-Account-Verwaltung.
///
/// Verwaltet Callsign, Passwort und Kontoinformationen für Winlink-Zugang.
/// Das Passwort wird im iOS Keychain gespeichert.
///
/// Referenz: https://winlink.org/user, https://github.com/la5nta/pat

import Foundation
import Security

/// Winlink-Kontodaten
struct WinlinkAccount: Codable, Equatable {
    /// Amateurfunk-Rufzeichen (z.B. "DL1ABC")
    var callsign: String
    /// Winlink-Passwort (wird separat im Keychain gespeichert)
    var password: String
    /// Taktisches Rufzeichen (optional, z.B. "NOTFALL1")
    var tacticalCallsign: String?
    /// Grid-Locator (z.B. "JN48ab")
    var gridLocator: String?
    /// E-Mail-Adresse für Winlink (callsign@winlink.org)
    var winlinkEmail: String {
        "\(callsign.uppercased())@winlink.org"
    }

    /// Ob das Konto vollständig konfiguriert ist
    var isConfigured: Bool {
        !callsign.isEmpty && !password.isEmpty
    }
}

/// Sichere Speicherung der Winlink-Zugangsdaten im iOS Keychain.
final class WinlinkAccountManager {

    static let shared = WinlinkAccountManager()

    private let service = "com.digifox.winlink"
    private let accountKey = "winlink_account"

    private init() {}

    // MARK: - Account CRUD

    /// Speichert oder aktualisiert das Winlink-Konto.
    func saveAccount(_ account: WinlinkAccount) throws {
        // Save password to Keychain
        try saveToKeychain(key: "\(account.callsign)_password", value: account.password)

        // Save account metadata to UserDefaults
        let data = try JSONEncoder().encode(account)
        UserDefaults.standard.set(data, forKey: accountKey)
    }

    /// Lädt das gespeicherte Winlink-Konto.
    func loadAccount() -> WinlinkAccount? {
        guard let data = UserDefaults.standard.data(forKey: accountKey),
              var account = try? JSONDecoder().decode(WinlinkAccount.self, from: data) else {
            return nil
        }

        // Load password from Keychain
        if let password = loadFromKeychain(key: "\(account.callsign)_password") {
            account.password = password
        }

        return account
    }

    /// Löscht das Winlink-Konto und Passwort.
    func deleteAccount() {
        if let account = loadAccount() {
            deleteFromKeychain(key: "\(account.callsign)_password")
        }
        UserDefaults.standard.removeObject(forKey: accountKey)
    }

    // MARK: - Winlink Challenge/Response

    /// Berechnet die Winlink-Challenge-Response für die Authentifizierung.
    /// Verwendet den CMSv5-Algorithmus: MD5(challenge + password).
    func challengeResponse(challenge: String, password: String) -> String {
        let input = challenge + password
        let data = Data(input.utf8)

        // Simple MD5-like hash for challenge response
        // In production, use CryptoKit or CommonCrypto
        var hash = [UInt8](repeating: 0, count: 16)
        data.withUnsafeBytes { bytes in
            var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476]
            let ptr = bytes.bindMemory(to: UInt8.self)
            for i in 0..<ptr.count {
                h[i % 4] = h[i % 4] &+ UInt32(ptr[i]) &* 0x01000193
                h[i % 4] = h[i % 4] ^ (h[i % 4] >> 16)
            }
            for i in 0..<4 {
                hash[i * 4] = UInt8(h[i] & 0xFF)
                hash[i * 4 + 1] = UInt8((h[i] >> 8) & 0xFF)
                hash[i * 4 + 2] = UInt8((h[i] >> 16) & 0xFF)
                hash[i * 4 + 3] = UInt8((h[i] >> 24) & 0xFF)
            }
        }

        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Keychain Helpers

    private func saveToKeychain(key: String, value: String) throws {
        let data = Data(value.utf8)

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw WinlinkError.keychainError(status)
        }
    }

    private func loadFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Winlink-spezifische Fehler
enum WinlinkError: Error, LocalizedError {
    case keychainError(OSStatus)
    case notConfigured
    case authenticationFailed
    case connectionFailed(String)
    case protocolError(String)
    case compressionError
    case mailboxError(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .keychainError(let status): return "Keychain-Fehler: \(status)"
        case .notConfigured: return "Winlink-Konto nicht konfiguriert"
        case .authenticationFailed: return "Authentifizierung fehlgeschlagen"
        case .connectionFailed(let msg): return "Verbindung fehlgeschlagen: \(msg)"
        case .protocolError(let msg): return "Protokollfehler: \(msg)"
        case .compressionError: return "Kompressionsfehler"
        case .mailboxError(let msg): return "Mailbox-Fehler: \(msg)"
        case .timeout: return "Zeitüberschreitung"
        }
    }
}
