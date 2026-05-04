import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Tone enrichment helper: rewrites a raw draft message in the user's voice
/// (warm, casual, ≤2 sentences, ≤1 emoji) before sending. Used by the
/// WhatsApp draft preview flow (#12). Sub 4/4 will replace the hardcoded
/// preferences with reads from GigiMemory.
///
/// Uses a dedicated `LanguageModelSession` (not the shared GIGI orchestrator
/// session) because the orchestrator session is configured for structured
/// intent classification — passing a free-form rewrite prompt to it produces
/// garbage `speech` field output. See bug #196.
@MainActor
final class GigiToneEnrichment {
    static let shared = GigiToneEnrichment()
    private init() {}

    enum Preferences {
        static let warmCasual = """
        You rewrite a draft message in the user's voice.
        Tone: warm, casual, friendly. No formal closings.
        Length: 1-2 sentences max. Use one emoji at most.
        Always reply in the SAME LANGUAGE as the raw draft (do not translate).
        Preserve the user's intent exactly. Do not add facts or invent details.
        Output ONLY the rewritten message itself — no labels, no quotes, no preamble.
        """
    }

    #if canImport(FoundationModels)
    @available(iOS 18.1, *)
    private static let dedicatedInstructions: String = """
    \(Preferences.warmCasual)

    The recipient name is provided per-request as "To:". Address them by that
    exact name — never substitute the example names below.

    Examples:
    To: Marco
    Raw: posso passare alle 18 oggi
    Rewritten: Ciao Marco! Posso passare alle 18 oggi? 😊

    To: Sarah
    Raw: can i come at 4 pm today
    Rewritten: Hey Sarah, can I drop by at 4pm today? 🙌

    To: Tom
    Raw: meeting tomorrow 9am ok
    Rewritten: Hey Tom, 9am tomorrow works for me 👍
    """

    @available(iOS 18.1, *)
    private static var dedicatedSession: LanguageModelSession? = {
        guard SystemLanguageModel.default.availability == .available else { return nil }
        return LanguageModelSession(instructions: dedicatedInstructions)
    }()
    #endif

    /// Returns enriched draft. Falls back to raw on empty input or LLM error.
    func enrich(rawDraft: String, contactName: String) async -> String {
        let trimmed = rawDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let userInput = "To: \(contactName)\nRaw: \(trimmed)\nRewritten:"

        // Path 1 — Apple Intelligence on-device (dedicated session, free-form output)
        #if canImport(FoundationModels)
        if #available(iOS 18.1, *), let session = Self.dedicatedSession {
            do {
                let response = try await session.respond(to: userInput)
                let cleaned = sanitize(response.content)
                if !cleaned.isEmpty { return cleaned }
            } catch {
                print("GigiToneEnrichment Apple Intelligence error: \(error)")
            }
        }
        #endif

        // Path 2 — cloud brain fallback (orchestrator engine; best-effort)
        // TODO(#196 follow-up): replace with direct Groq call when a free-form
        // text endpoint is exposed; the orchestrator engine is intent-classification
        // first and may also produce noisy output.
        let cloud = await GigiAgentEngine.shared.process(text: """
        \(Preferences.warmCasual)

        Recipient: \(contactName)
        Raw: \(trimmed)
        Rewritten:
        """)
        let cleaned = sanitize(cloud.speech)
        return cleaned.isEmpty ? trimmed : cleaned
    }

    /// Strip common system-prompt leak fragments + formatting noise.
    private func sanitize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Drop labels the model might echo
        let labelPatterns = [
            "Rewritten:", "Raw:", "Recipient:", "Output:",
            "Here is", "Here's", "Sure,", "Of course,"
        ]
        for label in labelPatterns where s.lowercased().hasPrefix(label.lowercased()) {
            s = String(s.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Drop full-prompt echoes
        let echoFragments = [
            "You rewrite", "You are rewriting", "Tone:", "Length:",
            "Always reply", "Preserve the user", "in the user's", "user's voice"
        ]
        let lower = s.lowercased()
        for frag in echoFragments where lower.contains(frag.lowercased()) {
            return ""  // forces caller fallback to raw
        }

        // Strip surrounding quotes
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        return s
    }
}
