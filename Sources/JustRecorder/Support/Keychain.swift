import Foundation
import Security

/// Minimal generic-password wrapper for the LLM API key.
enum Keychain {

    // Stable identifier preserves existing credentials across product renames.
    private static let service = "com.riffapp.Riff.aiAPIKey"
    private static let account = "default"
    private static let fallbackKey = "aiAPIKeyFallback"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8),
              !string.isEmpty
        else { return nil }
        return string
    }

    @discardableResult
    static func write(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackKey)
            return true
        }

        guard updateStatus == errSecItemNotFound else {
            Log.warn("Keychain update failed (status \(updateStatus)); the key was not saved.")
            return false
        }
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackKey)
        } else {
            Log.warn("Keychain write failed (status \(addStatus)); the key was not saved.")
        }
        return addStatus == errSecSuccess
    }

    @discardableResult
    static func delete() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { return false }
        UserDefaults.standard.removeObject(forKey: fallbackKey)
        return true
    }

    /// Migrate legacy plain-text preferences into Keychain before using them.
    /// A failed migration leaves the legacy value intact for a later retry.
    static func readWithFallback() -> String? {
        if let value = read() {
            UserDefaults.standard.removeObject(forKey: fallbackKey)
            return value
        }
        guard let legacy = UserDefaults.standard.string(forKey: fallbackKey),
              !legacy.isEmpty, write(legacy)
        else { return nil }
        return legacy
    }

}
