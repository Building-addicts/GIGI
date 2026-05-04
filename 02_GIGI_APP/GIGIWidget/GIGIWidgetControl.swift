import AppIntents
import SwiftUI
import WidgetKit

// MARK: - GIGIControlOpenIntent (#159)
//
// `OpenURLIntent` from a Control Center button does not always reach the host
// app's onOpenURL handler when the app is suspended/terminated — iOS treats it
// as an external URL handoff and silently drops it. Using a first-party
// AppIntent with `openAppWhenRun = true` forces iOS to foreground the app
// before invoking perform(), at which point we post the same NSNotification
// the URL path used to post.

@available(iOS 18.0, *)
struct GIGIControlOpenIntent: AppIntent {
    static var title: LocalizedStringResource = "Talk to GIGI"
    static var description = IntentDescription("Open GIGI and start listening.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // Posting a darwin-wide notification is unreliable across the
        // widget extension boundary, so we use a UserDefaults handshake
        // GIGIApp picks up on launch.
        let suite = UserDefaults(suiteName: "group.com.gigi.presence") ?? .standard
        suite.set(true, forKey: "pendingControlListenRequest")
        suite.set(Date().timeIntervalSince1970, forKey: "pendingControlListenAt")
        return .result()
    }
}

struct GIGIWidgetControl: ControlWidget {
    static let kind: String = "com.killsiri.GIGI.GIGIWidgetControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: GIGIControlOpenIntent()) {
                Label("Talk to GIGI", systemImage: "mic.fill")
            }
        }
        .displayName("Talk to GIGI")
        .description("Quickly open GIGI and start listening.")
    }
}
