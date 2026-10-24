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
        case .otherMouseUp:
            return .toggleSeparators
        default:
            // A key press on the focused arrow (keyboard or VoiceOver
            // navigation) is a plain activation, so it toggles.
            return .toggle
        }
    }
}

// Pure rules the controller relies on, kept here so they are testable without
// a live status item.
enum MenuBarBand {
    // The visible frame stops below the bar, unless the bar auto-hides: then it
    // reaches the top of the screen and the band must come from the bar's height.
    static func minY(frame: CGRect, visibleFrame: CGRect, thickness: CGFloat) -> CGFloat {
        if visibleFrame.maxY >= frame.maxY { return frame.maxY - thickness }
        return visibleFrame.maxY
    }
}

// Set while a collapse is outstanding. A second collapse that starts meanwhile
// (the auto-collapse timer or the hotkey firing under the access prompt) would
// otherwise consume the first one's completion.
struct CollapseGate {
    private(set) var isCollapsing = false

    mutating func begin() -> Bool {
        if isCollapsing { return false }
        isCollapsing = true
        return true
    }

    mutating func end() {
        isCollapsing = false
    }
}

enum EngineStatePresentation {
    // The arrow shows the collapsed glyph while icons are hidden, and also while
    // a failed restore leaves some hidden so a press retries the expansion.
    static func showsCollapsedGlyph(state: MenuBarEngineState, problem: HidingUnavailableReason?) -> Bool {
        return state == .collapsed || problem == .restoreFailed
    }
}

enum InitialCollapsePolicy {
    // Collapsing on top of a recovery that failed would hide icons again before
    // the owner can see the restore problem.
    static func shouldCollapse(launchRecovered: Bool) -> Bool {
        return launchRecovered
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
