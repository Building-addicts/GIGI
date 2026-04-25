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

        notifyHarnessPairingChangedIfNeeded(forKey: key)
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
        notifyHarnessPairingChangedIfNeeded(forKey: key)
    }

    // MARK: - Bool helpers

    static func loadBool(forKey key: String) -> Bool {
        return load(forKey: key) == "1"
    }

    static func saveBool(_ value: Bool, forKey key: String) {
        save(value ? "1" : "0", forKey: key)
    }

    // MARK: - Internal

    private static func notifyHarnessPairingChangedIfNeeded(forKey key: String) {
        guard key == Key.harnessBaseURL || key == Key.harnessSecret else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .gigiHarnessPairingDidChange, object: nil)
        }
    }

    // MARK: - Key constants

    enum Key {
        static let groqAPIKey         = "groq_api_key"
        static let geminiAPIKey       = "gemini_api_key"        // optional realtime voice
        static let picovoiceAccessKey = "picovoice_access_key"
        static let harnessBaseURL     = "harness_base_url"      // e.g. http://10.0.0.5:7779
        static let harnessSecret      = "harness_shared_secret"
        static let harnessDeviceID    = "harness_device_id"     // UUID persistente per device
        static let harnessApnsToken   = "harness_apns_token"    // ultimo device token ricevuto da Apple
        static let harnessApnsSyncedTo = "harness_apns_synced_to" // SHA256(baseURL|secret) cui il token è stato inviato
        // Brain Mode — Force Claude toggle
        static let forceClaude        = "brain_force_claude"    // "1" = bypass Groq, route ogni turn attraverso Claude
        static let autoFallback       = "brain_auto_fallback"   // "1" = se forceClaude on ma harness irraggiungibile, cade su Groq
    }
}
