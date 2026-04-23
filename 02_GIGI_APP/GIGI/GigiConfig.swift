import Foundation

enum GigiConfig {

    // MARK: - Groq API key (primary brain)

    static var groqAPIKey: String {
        if let k = GigiKeychain.load(forKey: GigiKeychain.Key.groqAPIKey), !k.isEmpty { return k }
        // Fallback: migrate existing Gemini key slot if present (one-time migration)
        if let k = GigiKeychain.load(forKey: GigiKeychain.Key.geminiAPIKey), !k.isEmpty { return k }
        let raw = Bundle.main.object(forInfoDictionaryKey: "GROQ_API_KEY") as? String ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func setGroqAPIKey(_ key: String) {
        GigiKeychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines), forKey: GigiKeychain.Key.groqAPIKey)
    }

    // MARK: - Gemini key alias (kept for GigiRealtimeEngine compile compat — returns empty)

    static var geminiAPIKey: String { "" }
    static func setGeminiAPIKey(_ key: String) {
        // Redirect old callers to Groq slot
        setGroqAPIKey(key)
    }

    // MARK: - Picovoice

    static var picovoiceAccessKey: String {
        if let k = GigiKeychain.load(forKey: GigiKeychain.Key.picovoiceAccessKey), !k.isEmpty { return k }
        let raw = Bundle.main.object(forInfoDictionaryKey: "PICOVOICE_ACCESS_KEY") as? String ?? ""
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == "$(PICOVOICE_ACCESS_KEY)" { return "" }
        return t
    }

    static func setPicovoiceAccessKey(_ key: String) {
        GigiKeychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines), forKey: GigiKeychain.Key.picovoiceAccessKey)
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
