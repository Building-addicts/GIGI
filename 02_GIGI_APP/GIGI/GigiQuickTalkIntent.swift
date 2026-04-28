import AppIntents
import Foundation

// MARK: - GigiQuickTalkIntent
//
// AppIntent for Action Button / Shortcuts integration.
// Brings app to foreground and starts a Quick Talk voice session.
// Register via GigiAppShortcuts for automatic Shortcuts discovery.

@available(iOS 16.0, *)
struct GigiQuickTalkIntent: AppIntent {
    // Renamed from "Talk to GIGI" to avoid colliding with the user-built
    // Shortcut of the same name that powers the background path. This
    // intent always opens the app — its title makes that explicit so users
    // don't pick it expecting the dictation banner.
    static var title: LocalizedStringResource = "Open GIGI"
    static var description = IntentDescription(
        "Open the GIGI app and start a foreground conversation — the listening card slides in, you talk, GIGI answers, and the loop continues until you say stop or tap close. Use this when you want the full app UI; for a background banner-only flow, build the Talk to GIGI Shortcut from onboarding."
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
                "Open \(.applicationName)",
                "Ask \(.applicationName)"
            ],
            shortTitle: "Open GIGI",
            systemImageName: "mic.fill"
        )
    }
}
