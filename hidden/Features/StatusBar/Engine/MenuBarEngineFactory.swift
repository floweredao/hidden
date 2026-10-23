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
        // overflow collapse works there in every build and keeps macOS's
        // indicators. Native hiding (direct build only: the sandbox blocks the
        // Accessibility reads that locate the sections) hides icons completely,
        // but takes the Focus icon and the mic/camera capsule with them.
        if isMacOS27OrLater && Preferences.hidesIntoSystemOverflow {
            return OverflowCollapseEngine(items: items)
        }
        if usesArrowAsBoundary {
            #if HIDDENBAR_NATIVE_VISIBILITY
            return NativeVisibilityEngine(items: items,
                                          sectionOverrides: { Preferences.sectionOverrides },
                                          keepsIndicatorsWhenExpanded: { Preferences.showsSystemIndicatorsWhenExpanded })
            #endif
        }
        return LegacyLengthEngine(items: items)
    }

    private static var isMacOS27OrLater: Bool {
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    // Whether the engine make() picks hides by the arrow (macOS 27 native
    // hiding) rather than by the | separator. The Settings picture follows it.
    static var usesArrowAsBoundary: Bool {
        #if HIDDENBAR_NATIVE_VISIBILITY
        return isMacOS27OrLater && !Preferences.hidesIntoSystemOverflow
        #else
        return false
        #endif
    }
}
