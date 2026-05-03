import Foundation

/// Tone enrichment helper: rewrites a raw draft message in the user's voice
/// (warm, casual Italian, ≤2 sentences, ≤1 emoji) before sending. Used by
/// the WhatsApp draft preview flow (#12). Sub 4/4 will replace hardcoded
/// preferences with reads from GigiMemory.
@MainActor
final class GigiToneEnrichment {
    static let shared = GigiToneEnrichment()
    private init() {}

    enum Preferences {
        static let warmCasualIT = """
        You are rewriting a draft message in the user's voice.
        Tone: warm, casual, friendly Italian.
        Length: 1-2 sentences max.
        Use one emoji at most. No formal closings.
        Preserve the user's intent exactly. Do not add information.
        Output ONLY the rewritten message, no explanations or quotes.
        """
    }

    /// Returns enriched draft. Falls back to raw on empty input or LLM error.
    func enrich(rawDraft: String, contactName: String) async -> String {
        let trimmed = rawDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let prompt = """
        \(Preferences.warmCasualIT)

        Recipient: \(contactName)
        Raw draft: \(trimmed)

        Rewritten:
        """

        // Path 1 — Apple Intelligence on-device (zero latency when available)
        if GigiFoundationAgent.isSupported {
            if let response = await GigiFoundationSession.shared.respond(text: prompt, history: "") {
                let cleaned = sanitize(response.speech)
                if !cleaned.isEmpty { return cleaned }
            }
        }

        // Path 2 — cloud brain fallback
        let cloud = await GigiAgentEngine.shared.process(text: prompt)
        let cleaned = sanitize(cloud.speech)
        return cleaned.isEmpty ? trimmed : cleaned
    }

    private func sanitize(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "Rewritten:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
