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
}
