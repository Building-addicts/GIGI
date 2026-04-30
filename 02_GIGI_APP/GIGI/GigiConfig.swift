import Foundation

enum GigiConfig {

    // MARK: - Groq API key (primary brain)

    static var groqAPIKey: String {
        // Info.plist FIRST so the build-time injected key always wins over a
        // stale Keychain value left by a previous install. Reverts to legacy
        // Keychain-first lookup only if Info.plist slot is empty.
        let raw = Bundle.main.object(forInfoDictionaryKey: "GROQ_API_KEY") as? String ?? ""
        let plistKey = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !plistKey.isEmpty { return plistKey }
        if let k = GigiKeychain.load(forKey: GigiKeychain.Key.groqAPIKey), !k.isEmpty { return k }
        if let k = GigiKeychain.load(forKey: GigiKeychain.Key.geminiAPIKey), !k.isEmpty { return k }
        return ""
    }

    /// Secondary Groq key (different account) used by GigiCloudService as
    /// automatic fallback when the primary key hits HTTP 429 (rate limit).
    /// Build pipeline injects it in Info.plist as GROQ_API_KEY_2.
    /// Returns empty string when no fallback is configured.
    static var groqAPIKeyFallback: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "GROQ_API_KEY_2") as? String ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func setGroqAPIKey(_ key: String) {
        GigiKeychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines), forKey: GigiKeychain.Key.groqAPIKey)
    }

    // MARK: - Gemini API key (Realtime WebSocket engine — stored in Keychain only)

    static var geminiAPIKey: String {
        if let k = GigiKeychain.load(forKey: GigiKeychain.Key.geminiAPIKey), !k.isEmpty { return k }
        return ""
    }

    static func setGeminiAPIKey(_ key: String) {
        GigiKeychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines), forKey: GigiKeychain.Key.geminiAPIKey)
    }

}

// MARK: - Master Shortcut (Shortcuts app)
enum GigiGateway {
    static let shortcutName = "GIGI_Gateway"
    static let isInstalledUserDefaultsKey = "gigi.isGatewayInstalled"

    private static let defaultICloudShortcutURL = "https://www.icloud.com/shortcuts/682e0c7b423f4b04bd32f729a3a28590"

    static var iCloudDownloadURL: URL? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "GIGI_GATEWAY_ICLOUD_URL") as? String ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? defaultICloudShortcutURL : trimmed
        return URL(string: resolved).flatMap { $0.scheme == "https" ? $0 : nil }
    }

    static let callbackSuccessURLString = "gigi://gateway-complete"
    static let callbackCancelURLString = "gigi://gateway-cancel"
}

extension Notification.Name {
    static let gigiGatewayCallback = Notification.Name("gigi.gateway.callback")
}
