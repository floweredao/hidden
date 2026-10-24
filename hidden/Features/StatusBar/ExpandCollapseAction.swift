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
    static func shouldExpand(state: MenuBarEngineState, problem: HidingUnavailableReason?) -> Bool {
        state == .collapsed || state == .calibrating || problem == .restoreFailed
    }
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

// AppKit can deliver duplicate begin notifications. Identity, rather than a
// counter, keeps one missed or unrelated end from disabling auto-collapse.
struct OwnedMenuTracking {
    private var menus = Set<ObjectIdentifier>()

    mutating func began(_ menu: NSMenu, owned: Bool) {
        if owned { menus.insert(ObjectIdentifier(menu)) }
    }

    mutating func ended(_ menu: NSMenu) {
        menus.remove(ObjectIdentifier(menu))
    }

    var isTracking: Bool { !menus.isEmpty }
}

struct AutoCollapseDeferral {
    enum Reason: String, CaseIterable {
        case mouseInMenuBar, preferencesEditing, ownedMenuTracking, menuBarNavigation
    }

    private var softDeferralStarted: TimeInterval?
    let maximumIdleDeferral: TimeInterval = 60

    mutating func reasons(now: TimeInterval, mouseInMenuBar: Bool, preferencesEditing: Bool,
                          ownedMenuTracking: Bool, menuBarNavigation: Bool, recentKeyboardInput: Bool) -> [Reason] {
        var reasons: [Reason] = []
        if mouseInMenuBar { reasons.append(.mouseInMenuBar) }
        if preferencesEditing { reasons.append(.preferencesEditing) }
        let soft = ownedMenuTracking || menuBarNavigation
        if !soft || recentKeyboardInput || !reasons.isEmpty {
            softDeferralStarted = nil
        }
        if soft {
            let start = softDeferralStarted ?? now
            softDeferralStarted = start
            // AX focus may remain on a menu extra long after its menu closes.
            // Actual keyboard use resets this bound; stale focus does not.
            if now - start < maximumIdleDeferral {
                if ownedMenuTracking { reasons.append(.ownedMenuTracking) }
                if menuBarNavigation { reasons.append(.menuBarNavigation) }
            }
        }
        return reasons
    }
}
