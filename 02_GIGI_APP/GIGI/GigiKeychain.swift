import Foundation
import Security

// Thin wrapper around the iOS Keychain for storing GIGI secrets.
// Keys are stored in the app's private Keychain partition (kSecAttrAccessibleAfterFirstUnlock).
enum GigiKeychain {

    private static let service = "com.killsiri.GIGI"

    // MARK: - Write

    static func save(_ value: String, forKey key: String) {
        guard let data = value.data(using: .utf8) else { return }

        var query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrService:     service,
            kSecAttrAccount:     key,
        ]

        // Overwrite if exists
        let updateAttrs: [CFString: Any] = [
            kSecValueData:       data,
            kSecAttrAccessible:  kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)

        if status == errSecItemNotFound {
            query[kSecValueData]      = data
            query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    // MARK: - Read

    static func load(forKey key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      key,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8),
              !string.isEmpty
        else { return nil }
        return string
    }

    // MARK: - Delete

    static func delete(forKey key: String) {
        let query: [CFString: Any] = [
            kSecClass:        kSecClassGenericPassword,
            kSecAttrService:  service,
            kSecAttrAccount:  key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Key constants

    enum Key {
        static let groqAPIKey        = "groq_api_key"
        static let geminiAPIKey      = "gemini_api_key"   // kept for migration; unused after Groq switch
        static let picovoiceAccessKey = "picovoice_access_key"
    }
}
