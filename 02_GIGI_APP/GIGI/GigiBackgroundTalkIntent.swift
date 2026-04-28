import AppIntents
import Foundation

// MARK: - GigiBackgroundTalkIntent
//
// Background-running AppIntent that receives a transcribed user phrase from
// an iOS Shortcut, runs it through the shared `LocalActionRouter`, falls
// back to the Mac harness for everything the router doesn't claim, and
// returns the answer (or marker) as a string the Shortcut speaks or routes.
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
//   4. The router resolves system queries on-device. Anything else falls
//      through to `GigiHarnessClient.agentRun`.
//   5. Shortcut → Speak Text on the dialog returned here, or routes the
//      `CALL:` / `SMS:` / `OPEN:` marker through its native action branches.
//
// Failure modes from the harness are mapped to user-friendly speech so the
// user always hears something even when the Mac is unreachable.

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

    // ReturnsValue only (no ProvidesDialog). Two reasons:
    //   1. ProvidesDialog made iOS double-speak the answer in the Shortcut
    //      flow — the dialog card spoke it once, then the user's Speak Text
    //      action spoke it again, and iOS sometimes interleaved an
    //      "Esci / Continuo" confirmation between the two.
    //   2. The Shortcut path is the canonical UX; the Siri-only path falls
    //      back to the foreground GigiQuickTalkIntent which has its own UI.
    //      Background AppIntent doesn't need a dialog channel.
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(value: "I didn't catch anything. Try again.")
        }

        // Local-first routing. Simple system queries that don't require
        // Claude reasoning or external integrations are answered directly
        // from the AppIntent, so the banner works even when the harness is
        // unreachable (Mac off, tunnel down, not paired). Only requests
        // that need cross-platform actions (order, book, browse) or
        // language-model reasoning fall through to the harness path.
        if let local = await LocalActionRouter.tryAnswer(for: trimmed) {
            return .result(value: local)
        }

        let result = await GigiHarnessClient.shared.agentRun(text: trimmed)
        switch result {
        case .success(let agent):
            let answer = agent.result.trimmingCharacters(in: .whitespacesAndNewlines)
            if answer.isEmpty {
                return .result(value: "GIGI didn't return anything. Try again.")
            }
            return .result(value: answer)

        case .failure(let err):
            // Map common failure modes to user-friendly speech rather than
            // surfacing raw error strings. The Shortcut speaks whatever we
            // return, so we keep it conversational.
            let message: String
            switch err {
            case .notConfigured:
                message = "I'm running without the Mac brain. Ask me about the time, the date, or say hello — that works on the phone alone. For everything else, open the GIGI app and pair it with your Mac."
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
            return .result(value: message)
        }
    }
}
