import AppIntents
import SwiftUI
import WidgetKit

struct GIGIWidgetControl: ControlWidget {
    static let kind: String = "com.killsiri.GIGI.GIGIWidgetControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: Self.kind
        ) {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "gigi://listen")!)) {
                Label("Talk to GIGI", systemImage: "mic.fill")
            }
        }
        .displayName("Talk to GIGI")
        .description("Quickly open GIGI and start listening.")
    }
}
