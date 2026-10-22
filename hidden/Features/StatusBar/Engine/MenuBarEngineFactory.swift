//
//  MenuBarEngineFactory.swift
//  Hidden Bar
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import Foundation

// The single place that picks a hiding mechanism for the running OS.
enum MenuBarEngineFactory {
    static func make(items: MenuBarItemProvider) -> MenuBarEngine {
        // macOS 27 ejects an inflated separator from the menu bar (#360). The
        // direct build hides natively there instead. The App Store build cannot:
        // the sandbox blocks the Accessibility reads that locate the sections.
        if usesArrowAsBoundary {
            #if HIDDENBAR_NATIVE_VISIBILITY
            return NativeVisibilityEngine(items: items,
                                          sectionOverrides: { Preferences.sectionOverrides },
                                          keepsIndicatorsWhenExpanded: { Preferences.showsSystemIndicatorsWhenExpanded })
            #endif
        }
        return LegacyLengthEngine(items: items)
    }

    // Whether the engine make() picks hides by the arrow (macOS 27 native
    // hiding) rather than by the | separator. The Settings picture follows it.
    static var usesArrowAsBoundary: Bool {
        #if HIDDENBAR_NATIVE_VISIBILITY
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
        #else
        return false
        #endif
    }
}
