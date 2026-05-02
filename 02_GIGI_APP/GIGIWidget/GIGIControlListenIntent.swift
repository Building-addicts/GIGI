import AppIntents
import Foundation

// AppIntent fired by the Control Center toggle. openAppWhenRun = true
// brings the host app to foreground; perform() then posts a Darwin
// notification picked up by the main app's MainTabView, which starts
// QuickTalkController.startContinuous() — same final state as a tap on
// the in-app mic, but reachable from CC without the OpenURLIntent
// quirks (which can silently no-op on custom URL schemes).
@available(iOS 18.0, *)
struct GIGIControlListenIntent: AppIntent {
    static var title: LocalizedStringResource = "Talk to GIGI"
    static var description = IntentDescription(
        "Open GIGI and start a voice conversation."
    )
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        let name = CFNotificationName("com.killsiri.GIGI.controlCenterListen" as CFString)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            name, nil, nil, true
        )
        return .result()
    }
}
