import AppIntents
import Foundation

// MARK: - GigiBackgroundTalkIntent
//
// Legacy-compatible background AppIntent that receives a transcribed user
// phrase from an iOS Shortcut, routes it through the shared GIGI orchestrator,
// and returns a marker or spoken answer that the Shortcut can route.
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
//      `GigiOrchestratorClient` resolves local system markers first, then uses
//      harness/cloud brain fallback for open-ended requests.
//   5. Shortcut → execute marker or Speak Text on the returned answer.
//
// Failure modes are spoken back through the same dialog channel so the user
// always hears something even if the harness is offline or unpaired.


// Local deterministic routing lives in `GigiShortcutOrchestrator`; this file stays
// as the AppIntent adapter that turns Shortcut input into a return value.

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

        let result = await GigiOrchestratorClient.resolve(text: trimmed)
        return .result(value: result.shortcutValue)
    }
}
