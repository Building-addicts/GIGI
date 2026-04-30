import AppIntents
import Foundation
import os.log

// MARK: - GigiConfirmActionIntent
//
// Step N of the Action Button → DI → Orchestrator → Shortcut chain.
//
// Called by every action branch in the Shortcut after the device
// action has fired (Set Flashlight, Start Call, Send Message, Open URL,
// Speak Text, etc). Transitions the Dynamic Island to `.done` with a
// short user-facing feedback message, then auto-dismisses.
//
// `outcome` is the human-readable confirmation produced by the Shortcut
// branch — e.g. "Torch on", "Calling Marco", "Message sent". Keep it
// short (≤ 24 chars) so the DI compact view doesn't truncate.

@available(iOS 16.0, *)
struct GigiConfirmActionIntent: AppIntent {
    static var title: LocalizedStringResource = "Confirm GIGI Action"
    static var description = IntentDescription("Show a Done feedback on the Dynamic Island and dismiss it.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Outcome", default: "Done")
    var outcome: String

    @Parameter(title: "Dismiss After (seconds)", default: 3.0)
    var dismissAfter: Double

    func perform() async throws -> some IntentResult {
        let log = Logger(subsystem: "com.killsiri.GIGI", category: "confirm-action")
        let trimmed = outcome.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = trimmed.isEmpty ? "Done" : String(trimmed.prefix(24))
        log.info("confirm.show message=\(message, privacy: .public) dismiss=\(self.dismissAfter, privacy: .public)s")

        await MainActor.run {
            Task {
                await GigiLiveActivityController.shared.completeWithDone(
                    message: message,
                    dismissAfter: dismissAfter
                )
            }
        }
        return .result()
    }
}
