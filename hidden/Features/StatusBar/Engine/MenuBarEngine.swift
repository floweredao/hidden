//
//  MenuBarEngine.swift
//  Hidden Bar
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit

// StatusBarController decides WHAT the user wants (collapsed or expanded, which
// sections exist); an engine decides HOW the menu bar is made to do it. Keeping
// the mechanics here lets an OS release that changes menu-bar layout (#360) get
// its own engine without version checks spreading through the controller.
protocol MenuBarEngine: AnyObject {
    var state: MenuBarEngineState { get }
    // Background reconciliation publishes after state and problem are final.
    var onStateChange: (() -> Void)? { get set }

    func collapse(completion: @escaping (CollapseResult) -> Void)
    func expand()

    func updateAlwaysHiddenSection(enabled: Bool, separatorHidden: Bool)

    // Whether the user's ⌘-drag arrangement lets the engine hide anything: its
    // hiding boundary must sit on the hidden side of the arrow. The controller
    // does not collapse otherwise.
    var isArrangementValid: Bool { get }

    // Whether the always-hidden separator sits beyond the regular hidden section.
    var isAlwaysHiddenSeparatorPlaced: Bool { get }

    // Display geometry changed. Re-applies the collapse to the live items when
    // collapsed, so a hot-plug does not leave a stale length behind (PR #354).
    func invalidateLayout()

    // Whether apps can be put in a section from Settings, without ⌘-drag.
    var supportsSectionAssignment: Bool { get }

    // The sections as read from where the items sit, before the per-app
    // choices are applied. nil when they cannot be read.
    func readSections(completion: @escaping (MenuBarLayout?) -> Void)

    // The per-app choices changed: hide again with them. Completes with false
    // when hiding failed and everything is shown.
    func reapplySections(completion: @escaping (Bool) -> Void)

    // Why the last collapse hid nothing, until one succeeds. nil when hiding works.
    var unavailableReason: HidingUnavailableReason? { get }
    func requestAccess()
}

// Why the bar could not be collapsed, shown to the user instead of only logged.
enum HidingUnavailableReason: Equatable {
    // This build or macOS has no way to hide icons.
    case notSupported
    // The Accessibility permission is needed to read where the icons are.
    case accessibilityNeeded
    // The arrow's position cannot be read yet.
    case boundaryUnreadable
    // macOS refused the request to hide.
    case activationFailed
    case fileAccessNeeded
    case restoreFailed
}

extension MenuBarEngine {
    var onStateChange: (() -> Void)? {
        get { nil }
        set {}
    }

    var supportsSectionAssignment: Bool { false }

    func readSections(completion: @escaping (MenuBarLayout?) -> Void) {
        completion(nil)
    }

    func reapplySections(completion: @escaping (Bool) -> Void) {
        completion(true)
    }

    var unavailableReason: HidingUnavailableReason? { nil }
    func requestAccess() {}
}

enum MenuBarEngineState {
    case expanded
    case calibrating
    case collapsed
    case unavailable
}

enum CollapseResult {
    case collapsed
    case unavailable
    case cancelled
}

enum MenuBarOrder {
    // True when `item` sits on the hidden side of `boundary`: to its left in a
    // left-to-right layout, to its right otherwise. False when either is not on
    // screen, since nothing can be judged then.
    static func isItem(_ item: NSStatusItem?, onHiddenSideOf boundary: NSStatusItem?) -> Bool {
        guard let itemX = item?.button?.window?.frame.origin.x,
              let boundaryX = boundary?.button?.window?.frame.origin.x else { return false }
        return Constant.isUsingLTRLanguage ? boundaryX >= itemX : boundaryX <= itemX
    }
}

// The controller owns and recreates the status items; engines only borrow them.
protocol MenuBarItemProvider: AnyObject {
    var toggleItem: NSStatusItem { get }
    var separatorItem: NSStatusItem { get }
    var alwaysHiddenItem: NSStatusItem? { get }
}
