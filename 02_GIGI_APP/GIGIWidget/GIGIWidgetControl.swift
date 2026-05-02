import AppIntents
import SwiftUI
import WidgetKit

struct GIGIWidgetControl: ControlWidget {
    static let kind: String = "com.killsiri.GIGI.GIGIWidgetControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: Self.kind
        ) {
            // Use a dedicated AppIntent (openAppWhenRun = true) instead of
            // OpenURLIntent. Control Center fires AppIntents reliably;
            // OpenURLIntent for custom schemes can silently no-op on first
            // invocation without a user permission round-trip.
            ControlWidgetButton(action: GIGIControlListenIntent()) {
                Label("Talk to GIGI", systemImage: "mic.fill")
            }
        }
        .displayName("Talk to GIGI")
        .description("Quickly open GIGI and start listening.")
    }
}
