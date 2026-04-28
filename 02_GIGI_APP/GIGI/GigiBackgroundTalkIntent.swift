import AppIntents
import Foundation

// MARK: - GigiBackgroundTalkIntent
//
// Background-running AppIntent that receives a transcribed user phrase from
// an iOS Shortcut, sends it to the GIGI harness for processing, and returns
// the answer as a spoken dialog the Shortcut can route through Speak Text.
// The app is never brought to the foreground (`openAppWhenRun: false`) — iOS
// wakes the process briefly to run `perform()` and lets it return.
//
// The expected Shortcut flow:
//
//   1. Hardware trigger (Back Tap / Action Button) runs the Shortcut.
//   2. Shortcut → Dictate Text. iOS shows its own dictation overlay; the
//      microphone is owned by the Shortcuts app, not by GIGI. No app
//      foregrounding.
//   3. Shortcut → Run "Process speech with GIGI" with the dictated text.
//      iOS calls into this intent in the background.
//   4. We forward the text through `GigiHarnessClient.agentRun(text:)`. The
//      harness performs whatever system-action routing or Claude reasoning
//      it already does for the foreground app — same endpoint, same auth,
//      same pairing. Nothing duplicated client-side.
//   5. Shortcut → Speak Text on the dialog returned here.
//
// Failure modes are spoken back through the same dialog channel so the user
// always hears something even if the harness is offline or unpaired.

// MARK: - LocalAnswer
//
// Pattern-based router that handles a small set of system queries entirely
// on-device, without going through the harness. The point of this layer is
// twofold:
//   1. The banner stays useful when the Mac harness is unreachable (Mac
//      off, tunnel down, not paired) for any request that doesn't need
//      Claude or an external integration.
//   2. We don't burn a Claude turn on questions whose answer is in the
//      device clock or the current locale.
//
// Anything not matched here falls through to `agentRun`, which is where
// reasoning, memory, and cross-platform actions (order pizza, book Uber,
// search Amazon — the things that genuinely need the harness) are handled.
//
// Phrases are matched on lowercased / whitespace-trimmed text. We accept
// English and Italian forms because the demo speaker mixes them. This is
// deliberately a thin keyword router rather than the full GigiNLUEngine,
// because the engine has UI dependencies that don't make sense in a
// background AppIntent context.

private enum LocalAnswer {
    static func tryAnswer(for raw: String) -> String? {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return nil }

        if matchesAny(lower, prefixes: ["hello", "hi gigi", "hey gigi", "ciao", "ciao gigi"]) {
            return "Hi! What can I help with?"
        }

        if containsAny(lower, phrases: ["what time", "what's the time", "che ore sono", "che ora è", "ora è"]) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return "It's \(formatter.string(from: Date()))."
        }

        if containsAny(lower, phrases: ["what day", "what's the date", "today's date", "che giorno è", "che data è"]) {
            let formatter = DateFormatter()
            formatter.dateStyle = .full
            formatter.timeStyle = .none
            return "Today is \(formatter.string(from: Date()))."
        }

        if containsAny(lower, phrases: ["thank you", "thanks", "grazie"]) {
            return "You're welcome."
        }

        // Self-test phrase the demo can use to confirm the banner is wired
        // up before turning the harness on. Useful during stage prep.
        if containsAny(lower, phrases: ["are you there", "ping", "test"]) {
            return "I'm here. The banner works."
        }

        return nil
    }

    private static func matchesAny(_ text: String, prefixes: [String]) -> Bool {
        prefixes.contains { text == $0 || text.hasPrefix($0 + " ") || text.hasPrefix($0 + ",") }
    }

    private static func containsAny(_ text: String, phrases: [String]) -> Bool {
        phrases.contains { text.contains($0) }
    }
}

@available(iOS 16.0, *)
struct GigiBackgroundTalkIntent: AppIntent {
    static var title: LocalizedStringResource = "Process speech with GIGI"
    static var description = IntentDescription(
        "Send a phrase to GIGI in the background — the app stays closed, GIGI's harness handles the request, and the answer is spoken back through the Shortcut."
    )
    // Stay in the background: iOS only spins the app process up briefly.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "What you said", description: "The transcribed phrase to send to GIGI.")
    var text: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(value: "I didn't catch anything. Try again.",
                           dialog: IntentDialog("I didn't catch anything. Try again."))
        }

        // Local-first routing. Simple system queries that don't require
        // Claude reasoning or external integrations are answered directly
        // from the AppIntent, so the banner works even when the harness is
        // unreachable (Mac off, tunnel down, not paired). Only requests
        // that need cross-platform actions (order, book, browse) or
        // language-model reasoning fall through to the harness path.
        if let local = LocalAnswer.tryAnswer(for: trimmed) {
            return .result(value: local, dialog: IntentDialog(stringLiteral: local))
        }

        let result = await GigiHarnessClient.shared.agentRun(text: trimmed)
        switch result {
        case .success(let agent):
            let answer = agent.result.trimmingCharacters(in: .whitespacesAndNewlines)
            if answer.isEmpty {
                return .result(value: "GIGI didn't return anything. Try again.",
                               dialog: IntentDialog("GIGI didn't return anything. Try again."))
            }
            return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))

        case .failure(let err):
            // Map common failure modes to user-friendly speech rather than
            // surfacing raw error strings. The Shortcut speaks whatever we
            // return, so we keep it conversational.
            let message: String
            switch err {
            case .notConfigured:
                message = "GIGI isn't paired yet. Open the app, finish setup, then try again."
            case .transport:
                message = "I couldn't reach GIGI. Check the connection and try again."
            case .badResponse(let status, _):
                if status == 401 || status == 403 {
                    message = "GIGI needs to be re-paired. Open the app to refresh the connection."
                } else if status == 429 {
                    message = "GIGI is rate limited right now. Try again in a moment."
                } else {
                    message = "GIGI returned an error. Try again later."
                }
            case .apiError(let code, _):
                if code == "RATE_LIMITED" {
                    message = "GIGI is rate limited right now. Try again in a moment."
                } else if code == "UNAUTHORIZED" {
                    message = "GIGI needs to be re-paired. Open the app to refresh the connection."
                } else {
                    message = "Something went wrong on GIGI's side. Try again later."
                }
            case .decodeFailed:
                message = "GIGI's reply was unreadable. Try again."
            }
            return .result(value: message, dialog: IntentDialog(stringLiteral: message))
        }
    }
}
