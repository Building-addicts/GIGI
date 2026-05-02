import Foundation

// MARK: - GigiFallbackEngine
//
// Produces user-facing fallback strings when agent fails or transcript is unclear.

@MainActor
final class GigiFallbackEngine {
    static let shared = GigiFallbackEngine()

    private init() {}

    func fallback(for error: QuickTalkController.QuickTalkError, lastTranscript: String) -> String {
        switch error {
        case .micPermissionDenied:
            return "I need microphone permission. Please enable it in Settings."
        case .sttFailed:
            return "I couldn't catch that. Could you try again?"
        case .networkError(let msg):
            return "Connection issue: \(msg). Please check your network."
        case .agentError:
            return "Something went wrong. Try again in a moment."
        }
    }

    func disambiguate(candidates: [String]) -> String {
        guard !candidates.isEmpty else { return "Could you be more specific?" }
        if candidates.count == 1 { return "Did you mean: \(candidates[0])?" }
        let options = candidates.prefix(3).joined(separator: ", ")
        return "Did you mean: \(options)?"
    }

    func genericFallback() -> String {
        let options = [
            "I didn't quite catch that. Could you rephrase?",
            "Not sure I understood. Try again?",
            "Could you say that differently?",
        ]
        return options.randomElement() ?? options[0]
    }

    // MARK: - Complex query fallback (Issue #63)
    //
    // Used by `GigiClaudeBridge.runFallback(...)` when the harness is
    // unreachable or fails mid-turn. Routes the question to the same Groq
    // path that `GigiCloudService.ask(_:)` already exercises, but with a
    // system prompt that tells the model it's degraded-mode and must lean
    // on its own knowledge without harness-side tools (calendar reads,
    // memory, computer-use, etc.).
    //
    // Returns `nil` only on hard failure (network down on Groq too, no
    // API key). Empty string is treated as failure as well so the bridge
    // can decide whether to surface a generic apology to the user.
    func runComplexQuery(task: String, context: String?) async -> String? {
        let baseSystem = """
        You are GIGI, a voice assistant on iPhone, currently running in offline \
        fallback mode: the cloud agent harness is unreachable, so you must rely \
        only on your own general knowledge — no calendar lookups, no memory \
        recall, no tool calls. Be honest if a question would require live data \
        you don't have. Reply in 1-3 short spoken sentences. No markdown.
        """
        let user: String = {
            guard let context, !context.trimmingCharacters(in: .whitespaces).isEmpty else {
                return task
            }
            return "Context: \(context)\nTask: \(task)"
        }()

        do {
            let answer = try await GigiCloudService.shared.askRaw(system: baseSystem, user: user)
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            GigiDebugLogger.log("GigiFallbackEngine.runComplexQuery — Groq path failed: \(error)")
            return nil
        }
    }
}
