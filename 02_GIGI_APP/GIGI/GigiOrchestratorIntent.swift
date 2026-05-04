import AppIntents
import Foundation

// MARK: - GigiOrchestratorIntent
//
// Advanced Shortcut brain step. The generated Shortcut passes dictated speech
// here; this intent calls the shared GIGI orchestrator and returns a marker or
// spoken answer. Shortcuts executes the marker, but GIGI owns interpretation.

@available(iOS 16.0, *)
struct GigiOrchestratorIntent: AppIntent {
    static var title: LocalizedStringResource = "Orchestrate with GIGI"
    static var description = IntentDescription(
        "Ask GIGI to interpret a phrase and return the native action marker for the Shortcut to execute."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "What you said", description: "The transcribed phrase to orchestrate.")
    var text: String

    @Parameter(title: "Session ID", description: "The GIGI session token from Begin GIGI session.")
    var sessionID: String?

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = await GigiOrchestratorClient.resolve(text: text, sessionID: sessionID)
        return .result(value: result.shortcutValue)
    }
}
