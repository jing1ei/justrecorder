import Foundation
import Security

/// Minimal generic-password wrapper for the LLM API key.
enum Keychain {

    private static let service = "com.jing1ei.JustRecorder.aiAPIKey"
    /// Service used by the pre-rename build; consulted once so an existing key survives.
    private static let legacyService = "com.riffapp.Riff.aiAPIKey"
    private static let account = "default"
    private static let fallbackKey = "aiAPIKeyFallback"
    private static let didClearLegacyKey = "didClearLegacyAIKey"

    private static func baseQuery(for serviceName: String = service) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
    }

    private static var baseQuery: [String: Any] { baseQuery() }

    private static func read(service serviceName: String) -> String? {
        var query = baseQuery(for: serviceName)
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
        // An older Keychain item may still exist if migration could not delete it.
        UserDefaults.standard.set(true, forKey: didClearLegacyKey)
        return true
    }

    /// Migrates credentials left behind by older builds (first the pre-rename
    /// Keychain service, then the even older plain-text preference) before using them.
    /// A failed migration leaves the original value intact for a later retry.
    static func readWithFallback() -> String? {
        if let value = read(service: service) {
            UserDefaults.standard.removeObject(forKey: fallbackKey)
            return value
        }
        if !UserDefaults.standard.bool(forKey: didClearLegacyKey),
           let migrated = read(service: legacyService) {
            if write(migrated) { SecItemDelete(baseQuery(for: legacyService) as CFDictionary) }
            return migrated
        }
        guard let legacy = UserDefaults.standard.string(forKey: fallbackKey),
              !legacy.isEmpty, write(legacy)
        else { return nil }
        return legacy
    }

}
