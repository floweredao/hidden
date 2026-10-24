//
//  Assets.swift
//  Hidden Bar
//
//  Created by Peter Luo on 2021/5/28.
//  Copyright © 2021 Dwarves Foundation. All rights reserved.
//

import AppKit

struct Assets {
    // Vector template chevrons (SF Symbols), so the arrow is sharp at any scale
    // and follows the menu bar's light or dark appearance like the system's own.
    private static func chevron(pointingLeft: Bool) -> NSImage? {
        let image = NSImage(systemSymbolName: pointingLeft ? "chevron.left" : "chevron.right",
                            accessibilityDescription: nil)
        let configured = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        configured?.isTemplate = true
        return configured
    }

    // Shown while collapsed: points toward the hidden icons, which sit left of
    // the arrow in a left-to-right layout.
    static var expandImage: NSImage? {
        return chevron(pointingLeft: Constant.isUsingLTRLanguage)
    }

    // Shown while expanded: points away from them.
    static var collapseImage: NSImage? {
        return chevron(pointingLeft: !Constant.isUsingLTRLanguage)
    }
}
