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
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        // DIAGNOSTIC: openAppWhenRun=false to isolate whether ChronoCore
        // error 3 is caused by the "open app from CC" path. Just write a
        // flag so we can confirm perform() ran at all.
        let defaults = UserDefaults(suiteName: "group.com.gigi.presence")
        defaults?.set(Date().timeIntervalSince1970, forKey: "gigi.cc.diag.performRanAt")
        return .result()
    }
}
