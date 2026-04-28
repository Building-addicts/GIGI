//
//  GIGIWidgetBundle.swift
//  GIGIWidget
//
//  Created by Corte leonardo  on 17/04/26.
//

import WidgetKit
import SwiftUI

@main
struct GIGIWidgetBundle: WidgetBundle {
    var body: some Widget {
        GigiLiveActivityWidget()
        // Control Center toggle — Shazam-style quick listen entry. Tapping
        // the button deep-links into the app via `gigi://listen`, which
        // `GIGIApp.onOpenURL` handles by starting a Presence session and
        // opening the mic. Without this in the bundle, the control never
        // appears in Control Center even though the type compiles. Min
        // deployment target for the widget extension is iOS 26.2, so the
        // ControlWidget API (iOS 18+) is unconditionally available.
        GIGIWidgetControl()
    }
}
