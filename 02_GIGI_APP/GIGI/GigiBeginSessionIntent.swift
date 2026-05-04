import AppIntents
import Foundation

// MARK: - GigiBeginSessionIntent
//
// First step of the advanced generated Shortcut chain. It gives the Shortcut a
// stable session token before dictation/orchestration starts. The Shortcut owns
// system dictation for now; this intent keeps GIGI as the named orchestrator
// boundary instead of making the Shortcut feel like the brain.

@available(iOS 16.0, *)
struct GigiBeginSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Begin GIGI session"
    static var description = IntentDescription(
        "Start a background GIGI orchestration session for the Talk to GIGI Shortcut."
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let sessionID = await GigiOrchestratorSessionStore.shared.begin()
        return .result(value: sessionID)
    }
}
