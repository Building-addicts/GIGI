import Foundation

enum GigiBrainDiagnostics {
    static func log() {
        let apiKey = GigiConfig.groqAPIKey
        let keyStatus: String
        if apiKey.isEmpty {
            keyStatus = "❌ MISSING — add your Groq key in Settings"
        } else {
            let preview = String(apiKey.prefix(8)) + "..."
            keyStatus = "✓ set (\(preview), \(apiKey.count) chars)"
        }

        var foundationStatus = "not available"
        if #available(iOS 18.1, *) {
            foundationStatus = GigiFoundationAgent.isSupported
                ? "✓ Apple Intelligence ready"
                : "⚠ Apple Intelligence not enabled/downloaded"
        }

        print("""
        ┌─ GIGI Brain Status ────────────────────────────────────
        │  Groq API key   : \(keyStatus)
        │  Model          : llama-3.3-70b-versatile
        │  Foundation AI  : \(foundationStatus)
        │  Fallback NLU   : ✓ always available (offline)
        └────────────────────────────────────────────────────────
        """)
    }
}
