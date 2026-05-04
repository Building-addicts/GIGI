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
    @WidgetBundleBuilder
    var body: some Widget {
        GigiLiveActivityWidget()
        if #available(iOS 18.0, *) {
            GIGIWidgetControl()
        }
    }
}
