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
        AppShortcut(
            intent: GigiQuickTalkIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Hey GIGI via \(.applicationName)",
                "Ask \(.applicationName)",
                "Open \(.applicationName)"
            ],
            shortTitle: "Talk to GIGI",
            systemImageName: "mic.fill"
        )
    }
}
