//
//  LegacyLengthEngine.swift
//  Hidden Bar
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit

// Hides icons by inflating the separator until everything to its left leaves the
// visible bar. macOS <= 26 reflows around any length, so the length only has to
// be large enough to cover the widest attached display.
final class LegacyLengthEngine: MenuBarEngine {
    private weak var items: MenuBarItemProvider?
    private var collapsed = false
    private var alwaysHiddenShown = true

    init(items: MenuBarItemProvider) { self.items = items }

    private var collapsedLength: CGFloat {
        // The menubar replicates across every attached display, so the collapse
        // length must cover the WIDEST screen, not NSScreen.main (the focused one);
        // sizing from a narrower screen leaks hidden icons on wider displays.
        // frame.width, not visibleFrame: the menubar spans the full frame width.
        let screenWidth = NSScreen.screens.map { $0.frame.width }.max() ?? 1728
        // Keep collapse length bounded to avoid pathological layout/memory behavior;
        // macOS enforces a hard 10,000pt maximum on NSStatusItem.length (PR #354).
        return max(500, min(screenWidth * 2, 10_000))
    }

    func apply(collapsed: Bool, alwaysHiddenShown: Bool) {
        self.collapsed = collapsed
        self.alwaysHiddenShown = alwaysHiddenShown
        items?.separatorItem.length = collapsed ? collapsedLength : 20
        items?.alwaysHiddenItem?.length = alwaysHiddenShown ? 20 : collapsedLength
    }

    // The separator is what widens, so it must sit between the hidden icons and
    // the arrow, and the always-hidden separator further out still.
    var isArrangementValid: Bool {
        MenuBarOrder.isItem(items?.separatorItem, onHiddenSideOf: items?.toggleItem)
    }

    var isAlwaysHiddenSeparatorPlaced: Bool {
        MenuBarOrder.isItem(items?.alwaysHiddenItem, onHiddenSideOf: items?.separatorItem)
    }

    // Each inflated item is re-sized on its own: the always-hidden one stays
    // inflated while expanded with "hide separators" on, and must cover a newly
    // attached wider display then too.
    func invalidateLayout() { apply(collapsed: collapsed, alwaysHiddenShown: alwaysHiddenShown) }
    func refreshArrangement() {}
    @discardableResult func restoreAll() -> Bool {
        apply(collapsed: false, alwaysHiddenShown: true)
        return true
    }
}
