import Foundation
import Security

// MARK: - KeychainHelper
//
// Minimal read/write/delete wrapper for iOS Keychain Services.
// All operations are synchronous and should be called from any non-UI thread
// (they are fast enough not to warrant async wrappers at this scale).
//
// Credential keys follow the reverse-DNS bundle pattern so they are unique per app
// and readable by name when debugging with the Security framework.

enum KeychainHelper {

    // MARK: - Credential key constants

    /// OpenAI API key — used by LocalAIService (OSS target).
    static let openAIKeyName      = "com.maxai.openai_api_key"

    /// Google Gemini API key — used when Gemini provider is selected.
    static let geminiKeyName      = "com.maxai.gemini_api_key"

    /// Serper.dev API key — used by SerperService.
    static let serperKeyName      = "com.maxai.serper_api_key"

    /// Subscription bearer token — used by ProxyAIService (Paid target).
    /// Set after a successful in-app purchase receipt validation on your server.
    static let proxyBearerKeyName = "com.maxai.proxy_bearer_token"

    /// Base URL of the proxy server, e.g. "https://api.maxai.studio/v1".
    /// Stored in Keychain so it is not visible in plain-text plists or user defaults.
    static let proxyURLKeyName    = "com.maxai.proxy_base_url"

    // MARK: - Read

    /// Returns the stored string for `key`, or `nil` if not found or empty.
    static func read(key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key as CFString,
            kSecReturnData:  kCFBooleanTrue as Any,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data   = result as? Data,
              let string = String(data: data, encoding: .utf8),
              !string.isEmpty
        else { return nil }
        return string
    }

    // MARK: - Write

    /// Stores `value` for `key`. Returns `true` on success.
    /// Silently updates the existing item if one already exists.
    @discardableResult
    static func write(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Attempt an in-place update first (item already exists)
        let updateQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key as CFString
        ]
        let updateAttrs: [CFString: Any] = [kSecValueData: data]
        if SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary) == errSecSuccess {
            return true
        }

        // Item not found — insert new
        let addQuery: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrAccount:     key as CFString,
            kSecValueData:       data,
            // Accessible when device is unlocked; not backed up to iCloud.
            kSecAttrAccessible:  kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - Delete

    /// Removes the Keychain item for `key`. Returns `true` on success or if item did not exist.
    @discardableResult
    static func delete(key: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key as CFString
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Migrate from UserDefaults

    /// One-time migration helper: moves a value from UserDefaults into Keychain,
    /// then removes the plaintext entry from UserDefaults.
    ///
    /// Call this once in `AppDelegate` / `App.init` for each credential key that
    /// was previously stored as `@AppStorage`.
    ///
    ///     KeychainHelper.migrateFromUserDefaults(
    ///         udKey:       "openai_api_key",
    ///         keychainKey: KeychainHelper.openAIKeyName
    ///     )
    static func migrateFromUserDefaults(udKey: String, keychainKey: String) {
        guard read(key: keychainKey) == nil,                          // not already in Keychain
              let value = UserDefaults.standard.string(forKey: udKey),
              !value.isEmpty
        else { return }
        if write(key: keychainKey, value: value) {
            UserDefaults.standard.removeObject(forKey: udKey)
            print("[KeychainHelper] Migrated '\(udKey)' from UserDefaults to Keychain ✅")
        }
    }
}
