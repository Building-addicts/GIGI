import AppIntents
import Foundation

// MARK: - GigiQuickTalkIntent
//
// AppIntent for Action Button / Shortcuts integration.
// Brings app to foreground and starts a Quick Talk voice session.
// Register via GigiAppShortcuts for automatic Shortcuts discovery.

@available(iOS 16.0, *)
struct GigiQuickTalkIntent: AppIntent {
    static var title: LocalizedStringResource = "Talk to GIGI"
    static var description = IntentDescription(
        "Open GIGI in conversation mode — the listening card slides in, you talk, GIGI answers, and the loop continues until you say stop or tap close."
    )
    static var openAppWhenRun: Bool = true   // mic requires foreground

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            // Continuous mode keeps the conversation alive for multi-turn
            // exchanges instead of one-shot. Stop button or spoken "stop"
            // ends the session (see QuickTalkController.isExitPhrase).
            QuickTalkController.shared.startContinuous()
        }
        return .result()
    }
}

// MARK: - GigiAppShortcuts

@available(iOS 16.0, *)
struct GigiAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // Only the foreground intent is registered as an App Shortcut so it
        // appears in Spotlight, Siri suggestions, and the Action Button
        // picker — those surfaces want a one-tap user-runnable action.
        // GigiBackgroundTalkIntent is intentionally NOT registered here:
        // it requires a `text` parameter that only makes sense when piped
        // from Dictate Text inside a user Shortcut. iOS still surfaces it
        // in the Shortcuts editor (action search) so the walkthrough can
        // wire it up; it just won't appear as a stand-alone bindable
        // shortcut, which would otherwise leave the user staring at a
        // keyboard prompt for the required text.
        AppShortcut(
            intent: GigiQuickTalkIntent(),
            phrases: [
                "Hey \(.applicationName)",
                "Talk to \(.applicationName)",
                "Ask \(.applicationName)",
                "Open \(.applicationName)"
            ],
            shortTitle: "Talk to GIGI",
            systemImageName: "mic.fill"
        )
    }
}
