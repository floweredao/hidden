//
//  ExpandCollapseAction.swift
//  Hidden Bar
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit

// What a press on the expand/collapse button should do. Kept as a pure mapping
// so the decision is unit-testable without a live status item or a real NSEvent.
enum ExpandCollapseAction {
    case toggle
    case contextMenu
    case toggleSeparators
}

enum ExpandCollapseActionResolver {
    // On macOS 27 the mouse-up event a status bar button hands to its action
    // carries empty modifier flags even while a modifier is held, so the live
    // keyboard state is consulted as well.
    static func modifiers(eventFlags: NSEvent.ModifierFlags?, liveFlags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        return (eventFlags ?? []).union(liveFlags).intersection(.deviceIndependentFlagsMask)
    }

    // With the always-hidden section on, right-click shows or hides it, as the
    // in-app tutorial teaches; with it off there is nothing to toggle, so
    // right-click opens the context menu. Control-click is the Mac's
    // right-click. Option-click, left or right, always opens the context menu.
    //
    // A nil event type means there is no real NSEvent behind the press, which is
    // what assistive synthesis (VoiceOver AXPress) produces: treat it as a plain
    // left click so VoiceOver users can toggle the bar at all.
    static func action(eventType: NSEvent.EventType?, modifiers: NSEvent.ModifierFlags, alwaysHiddenSectionEnabled: Bool) -> ExpandCollapseAction {
        guard let eventType = eventType else { return .toggle }
        if modifiers.contains(.option) { return .contextMenu }
        let secondaryClick: ExpandCollapseAction = alwaysHiddenSectionEnabled ? .toggleSeparators : .contextMenu
        switch eventType {
        case .leftMouseUp:
            return modifiers.contains(.control) ? secondaryClick : .toggle
        case .rightMouseUp:
            return secondaryClick
        default:
            return .toggleSeparators
        }
    }
}
