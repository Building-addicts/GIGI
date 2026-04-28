import AppIntents
import Foundation

// MARK: - GigiQuickTalkIntent
//
// AppIntent that opens GIGI and starts a one-shot voice turn. This is the
// primary entry point for hardware triggers — Action Button on iPhone 15 Pro+,
// Back Tap on iPhone 14 (Settings → Accessibility → Touch → Back Tap), and the
// Siri phrases declared in GigiAppShortcuts below. When MVP wake word is
// disabled (#102), this is the canonical "wake-from-anywhere" path.

@available(iOS 16.0, *)
struct GigiQuickTalkIntent: AppIntent {
    static var title: LocalizedStringResource = "Talk to GIGI"
    static var description = IntentDescription("Open GIGI and start a voice turn — the same as a double-tap on the back of your iPhone or pressing the Action Button.")
    // Mic capture requires foreground; iOS will unlock the device first if locked.
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            QuickTalkController.shared.start()
        }
        return .result()
    }
}

// MARK: - GigiAppShortcuts
//
// Declaring AppShortcuts makes "Talk to GIGI" discoverable system-wide:
//   • Siri picks up the phrases below — no setup required from the user.
//   • Shortcuts app lists the intent under "GIGI" automatically.
//   • Settings → Action Button → Shortcut → App Shortcuts → GIGI.
//   • Settings → Accessibility → Touch → Back Tap → Double Tap → GIGI.
//   • Spotlight search returns the intent when typing "talk to gigi".
//
// Apple requires every phrase to contain \(.applicationName); the substitution
// resolves to "GIGI", so "Hey \(.applicationName)" reads as "Hey GIGI" — the
// natural wake phrase, but routed through Siri rather than a continuous mic.

@available(iOS 16.0, *)
struct GigiAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
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
