import AppIntents
import Foundation

// AppIntent fired by the Control Center toggle. openAppWhenRun = true
// brings the host app to foreground. The handoff to start listening is
// via App Group UserDefaults (timestamp written here, read by main app
// on scenePhase=.active). Darwin notifications proved unreliable from
// chronod execution context (ChronoCore error code 3).
struct GIGIControlListenIntent: AppIntent {
    static var title: LocalizedStringResource = "Talk to GIGI"
    static var description = IntentDescription(
        "Open GIGI and start a voice conversation."
    )
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // Minimal perform — diagnostic step. If app opens with this empty
        // body, the issue is in the side effect (App Group write). If iOS
        // still throws CHSErrorDomain 1107, the issue is structural.
        return .result()
    }
}
