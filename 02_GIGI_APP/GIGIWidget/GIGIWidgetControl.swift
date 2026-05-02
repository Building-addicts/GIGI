import AppIntents
import SwiftUI
import WidgetKit

struct GIGIWidgetControl: ControlWidget {
    static let kind: String = "com.killsiri.GIGI.GIGIWidgetControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: Self.kind
        ) {
            // OpenURLIntent uses iOS's native URL opening path (NOT the
            // openAppWhenRun=true AppIntent path which fails with
            // ChronoCore error 3 in this widget extension setup).
            // `gigi://listen` is handled by GIGIApp.onOpenURL → starts
            // PresenceSessionController + GigiSmartOrchestrator listening.
            ControlWidgetButton(action: OpenURLIntent(URL(string: "gigi://listen")!)) {
                Label("Talk to GIGI", systemImage: "mic.fill")
            }
        }
        .displayName("Talk to GIGI")
        .description("Quickly open GIGI and start listening.")
    }
}
