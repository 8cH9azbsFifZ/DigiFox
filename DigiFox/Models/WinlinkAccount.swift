/// Winlink account management.
///
/// Manages callsign, password and account information for Winlink access.
/// The password is stored in the iOS Keychain.
///
/// Referenz: https://winlink.org/user, https://github.com/la5nta/pat

import Foundation
import Security
import CryptoKit

/// Winlink account data
struct WinlinkAccount: Codable, Equatable {
    /// Amateur radio callsign (e.g. "DL1ABC")
    var callsign: String
    /// Winlink password (stored separately in the Keychain)
    var password: String
    /// Tactical callsign (optional, e.g. "EMERG1")
    var tacticalCallsign: String?
    /// Grid locator (e.g. "JN48ab")
    var gridLocator: String?
    /// Email address for Winlink (callsign@winlink.org)
    var winlinkEmail: String {
        "\(callsign.uppercased())@winlink.org"
    }

    /// Whether the account is fully configured
    var isConfigured: Bool {
        !callsign.isEmpty && !password.isEmpty
    }
}

/// Secure storage of Winlink credentials in the iOS Keychain.
final class WinlinkAccountManager {

    static let shared = WinlinkAccountManager()

    private let service = "com.digifox.winlink"
    private let accountKey = "winlink_account"

    private init() {}

    // MARK: - Account CRUD

    /// Saves or updates the Winlink account.
    func saveAccount(_ account: WinlinkAccount) throws {
        // Save password to Keychain
        try saveToKeychain(key: "\(account.callsign)_password", value: account.password)

        // Save account metadata to UserDefaults
        let data = try JSONEncoder().encode(account)
        UserDefaults.standard.set(data, forKey: accountKey)
    }

    /// Loads the saved Winlink account.
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

    /// Deletes the Winlink account and password.
    func deleteAccount() {
        if let account = loadAccount() {
            deleteFromKeychain(key: "\(account.callsign)_password")
        }
        UserDefaults.standard.removeObject(forKey: accountKey)
    }

    // MARK: - Winlink Challenge/Response

    /// Computes the Winlink challenge-response for authentication.
    /// Uses MD5(challenge + password) — as in Pat/wl2k-go.
    func challengeResponse(challenge: String, password: String) -> String {
        let input = challenge + password
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        let result = digest.map { String(format: "%02x", $0) }.joined()
        Log.d("WinlinkAuth", "challengeResponse: hash computed for challenge '\(challenge.prefix(8))...'")
        return result
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

/// Winlink-specific errors
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
