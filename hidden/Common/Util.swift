//
//  Util.swift
//  vanillaClone
//
//  Created by Thanh Nguyen on 1/29/19.
//  Copyright © 2019 Dwarves Foundation. All rights reserved.
//

import AppKit
import Foundation


class Util {
    
    @discardableResult
    static func setUpAutoStart(isAutoStart: Bool) -> Bool {
        // SMAppService (macOS 13+) registers the main app itself as a login item;
        // no helper app, no distributed-notification kill dance.
        return AutoStart.apply(enabled: isAutoStart)
    }
    
    static func showPrefWindow() {
        let prefWindow = PreferencesWindowController.shared.window
        prefWindow?.bringToFront()
    }

    // System Settings > Privacy & Security > Accessibility.
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
   
}
