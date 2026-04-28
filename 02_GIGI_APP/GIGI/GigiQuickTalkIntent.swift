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
    static var description = IntentDescription("Start a Quick Talk voice session with GIGI")
    static var openAppWhenRun: Bool = true   // mic requires foreground

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            QuickTalkController.shared.start()
        }
        return .result()
    }
}

// MARK: - GigiAppShortcuts

@available(iOS 16.0, *)
struct GigiAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // Foreground intent — opens GIGI and starts the in-app voice turn.
        // Used when the user wants the full app UI (transcript, follow-up,
        // Live Activity).
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
        // Background intent — receives a transcribed phrase from a Shortcut
        // (Dictate Text → Process speech with GIGI → Speak Text) and never
        // brings the app to the foreground. The Shortcut owns the mic, GIGI
        // owns the reasoning, the Shortcut speaks the answer.
        AppShortcut(
            intent: GigiBackgroundTalkIntent(),
            phrases: [
                "Process with \(.applicationName)",
                "Send to \(.applicationName)"
            ],
            shortTitle: "Process speech with GIGI",
            systemImageName: "waveform"
        )
    }
}
