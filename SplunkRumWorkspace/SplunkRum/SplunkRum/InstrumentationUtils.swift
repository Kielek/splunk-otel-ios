//
//  InstrumentationUtils.swift
//  SplunkRum
//
//  Created by jbley on 2/22/21.
//

import Foundation
import UIKit
import OpenTelemetryApi
import OpenTelemetrySdk

private func addUIFields(span: ReadableSpan) {
    // FIXME threading - SplunkRum initialization and AppStart can happen before UI is initialized
    let wins = UIApplication.shared.windows
    if !wins.isEmpty {
        // windows are arranged in z-order, with topmost (e.g. popover) being the last in array
        let vc = wins[wins.count-1].rootViewController
        if vc != nil {
            // FIXME demangle swift names
            span.setAttribute(key: "screen.name", value: String(describing: type(of: vc)))
            // FIXME SwiftUI UIHostingController vc when cast has a "rootView" var which does
            // not appear to be accessible generically
        }
    }
    // FIXME others?
}

func addPreSpanFields(span: ReadableSpan) {
    addUIFields(span: span)
}