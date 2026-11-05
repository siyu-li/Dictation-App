import Foundation
import Security
import TranscriptCore

/// Stores AI API keys in the iOS Keychain (never in the repo or in
/// UserDefaults), one per provider. Keys stay on this device only.
enum KeychainStore {
    private static let service = "Dictation.ClaudeAPIKey"
    /// The account the single Claude key used before providers existed.
    private static let legacyClaudeAccount = "default"

    private static func account(for provider: AIProvider) -> String {
        provider.rawValue
    }

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func readAPIKey(for provider: AIProvider) -> String? {
        if let key = read(account: account(for: provider)) { return key }
        return provider == .claude ? read(account: legacyClaudeAccount) : nil
    }

    @discardableResult
    static func saveAPIKey(_ key: String, for provider: AIProvider) -> Bool {
        deleteAPIKey(for: provider)
        var item = query(account: account(for: provider))
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func deleteAPIKey(for provider: AIProvider) {
        SecItemDelete(query(account: account(for: provider)) as CFDictionary)
        if provider == .claude {
            SecItemDelete(query(account: legacyClaudeAccount) as CFDictionary)
        }
    }

    private static func read(account: String) -> String? {
        var item = query(account: account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
