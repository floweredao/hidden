//
//  OverflowCollapseEngine.swift
//  Hidden Bar
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//
//  The overflow collapse and its length limits follow Pelmet
//  (github.com/ismatBabirli/pelmet, MIT, Copyright (c) 2026 Ismat Babirli),
//  which measured them on macOS 27.0 and 27.2.
//

import AppKit

// macOS 27 hiding that keeps macOS's own indicators. The native engine hides
// through the assessment-mode visibility restriction, and while that is held
// macOS also removes the Focus icon, the mic/camera/screen-recording capsule,
// Now Playing and Live Activities. This engine holds no restriction at all.
//
// macOS 27 discards a status item longer than a per-display limit, which is why
// the legacy engine's huge separator does nothing there. Below the limit the bar
// does not reflow around a long item: it runs out of room from the left and
// macOS moves the leftmost items into its own « menu. So collapsing makes the
// separator, plus spacers to its left, just shorter than the limit while
// together they span the status area, and everything left of the separator goes
// into «, one click away. Everything right of it stays, macOS's indicators too.
//
// The separator is the boundary, as on macOS 26: it must sit between the hidden
// icons and the arrow, and the always-hidden separator further out still. The
// always-hidden section alone is hidden the same way, by inflating its separator
// instead.
//
// The spacers are registered after the separators so that, on first sight,
// macOS 27 puts them at the left end of the bar, beyond every section. They are
// always all registered, even when fewer are used: a name first seen on a later
// launch would land left of icons already hidden and push nothing.
final class OverflowCollapseEngine: MenuBarEngine {
    static func spacerAutosaveName(_ index: Int) -> String {
        return "hiddenbar_overflow_spacer_\(index)"
    }

    private weak var items: MenuBarItemProvider?
    private let displays: () -> [OverflowCollapseGeometry.Display]
    private let makeSpacer: (String) -> NSStatusItem
    private var spacers: [NSStatusItem] = []
    // The separators' line, taken off while they are inflated.
    private let lineImage: NSImage?

    private let expandedLength: CGFloat = 20

    private(set) var state: MenuBarEngineState = .expanded

    private var alwaysHiddenEnabled = false
    private var alwaysHiddenSeparatorHidden = false

    init(items: MenuBarItemProvider,
         displays: @escaping () -> [OverflowCollapseGeometry.Display] = OverflowCollapseGeometry.currentDisplays,
         makeSpacer: @escaping (String) -> NSStatusItem = OverflowCollapseEngine.makeSystemSpacer) {
        self.items = items
        self.displays = displays
        self.makeSpacer = makeSpacer
        lineImage = items.separatorItem.button?.image
        items.separatorItem.isVisible = true
        items.separatorItem.length = expandedLength
        spacers = (0..<OverflowCollapseGeometry.spacerCount).map { makeSpacer(Self.spacerAutosaveName($0)) }
    }

    private static func makeSystemSpacer(_ name: String) -> NSStatusItem {
        let spacer = NSStatusBar.system.statusItem(withLength: 0)
        // Name first: the visibility below is saved under it. On macOS 27 a
        // hidden item keeps its slot while taking no room.
        spacer.autosaveName = name
        spacer.button?.setAccessibilityElement(false)
        spacer.isVisible = false
        return spacer
    }

    func collapse(completion: @escaping (CollapseResult) -> Void) {
        state = .collapsed
        apply()
        completion(.collapsed)
    }

    func expand() {
        state = .expanded
        apply()
    }

    func updateAlwaysHiddenSection(enabled: Bool, separatorHidden: Bool) {
        alwaysHiddenEnabled = enabled
        alwaysHiddenSeparatorHidden = separatorHidden
        apply()
    }

    var isArrangementValid: Bool {
        return MenuBarOrder.isItem(items?.separatorItem, onHiddenSideOf: items?.toggleItem)
    }

    var isAlwaysHiddenSeparatorPlaced: Bool {
        return MenuBarOrder.isItem(items?.alwaysHiddenItem, onHiddenSideOf: items?.separatorItem)
    }

    // A narrower display can put the old lengths past its limit.
    func invalidateLayout() {
        apply()
    }

    // Which separator is inflated, if any: the regular one while collapsed (it
    // hides both sections), the always-hidden one while expanded with
    // "hide separators" on.
    private var inflatedSeparator: NSStatusItem? {
        switch state {
        case .collapsed:
            return items?.separatorItem
        case .expanded, .calibrating, .unavailable:
            guard alwaysHiddenEnabled && alwaysHiddenSeparatorHidden else { return nil }
            return items?.alwaysHiddenItem
        }
    }

    private func apply() {
        guard let items = items else { return }
        let inflated = inflatedSeparator
        let plan = OverflowCollapseGeometry.plan(displays: displays())

        items.separatorItem.length = inflated === items.separatorItem ? plan.unitLength : expandedLength
        // An inflated separator is an empty gap; its line would float in the middle.
        items.separatorItem.button?.image = inflated === items.separatorItem ? nil : lineImage

        if let alwaysHidden = items.alwaysHiddenItem {
            if inflated === alwaysHidden {
                alwaysHidden.length = plan.unitLength
                alwaysHidden.button?.image = nil
            } else {
                alwaysHidden.length = alwaysHiddenEnabled ? expandedLength : 0
                alwaysHidden.button?.image = lineImage
            }
        }

        for (index, spacer) in spacers.enumerated() {
            let isActive = inflated != nil && index < plan.activeSpacers
            spacer.length = isActive ? plan.unitLength : 0
            spacer.isVisible = isActive
        }
    }
}

// Collapse lengths for macOS 27's single-window menu bar.
//
// One item longer than a per-display limit is discarded and the bar is left as
// it was. Below the limit the bar overflows from the left. So the separator and
// each spacer stay under the narrowest display's limit, while together they
// span the widest display's status area (one length applies to every display's
// copy of the bar).
//
// Limits, measured by Pelmet and MenubarHide: half the width on a display
// without a notch; on a notched display about 0.79 of the area right of the
// notch.
enum OverflowCollapseGeometry {
    struct Display: Equatable {
        // Full width of the display.
        let width: CGFloat
        // Width available to status items: right of the notch when there is
        // one, the full width otherwise.
        let statusWidth: CGFloat

        init(width: CGFloat, statusWidth: CGFloat? = nil) {
            self.width = width
            self.statusWidth = min(statusWidth ?? width, width)
        }

        var hasNotch: Bool { statusWidth < width }
    }

    struct Plan: Equatable {
        // Length of the inflated separator and of every active spacer.
        let unitLength: CGFloat
        // How many spacers are inflated alongside it.
        let activeSpacers: Int
    }

    // Fixed, so every launch registers the same names (see the engine). Sixteen
    // covers a 6016 pt display beside a 1280 pt one.
    static let spacerCount = 16

    // Kept under a limit: absorbs the measurements' imprecision and the 16 pt
    // AppKit adds around each item's length.
    static let limitMargin: CGFloat = 64
    // Stays under the measured ~0.79 of the area right of the notch.
    static let notchedLimitFactor: CGFloat = 0.75
    static let fallbackUnit: CGFloat = 200

    // The longest one item can be on this display before macOS discards it.
    static func limit(of display: Display) -> CGFloat {
        return display.hasNotch
            ? display.statusWidth * notchedLimitFactor
            : display.width / 2
    }

    static func plan(displays: [Display]) -> Plan {
        guard let lowestLimit = displays.map(limit(of:)).min(),
              let widestStatus = displays.map(\.statusWidth).max()
        else { return Plan(unitLength: fallbackUnit, activeSpacers: 0) }

        let unit = max(1, (lowestLimit - limitMargin).rounded(.down))
        // The separator is one unit and each spacer another; more than it takes
        // to cover the widest status area would only overflow themselves.
        let needed = Int((widestStatus / unit).rounded(.up)) - 1
        return Plan(unitLength: unit, activeSpacers: min(max(needed, 0), spacerCount))
    }

    static func currentDisplays() -> [Display] {
        return NSScreen.screens.map { screen in
            let statusWidth: CGFloat?
            if #available(macOS 12.0, *) {
                statusWidth = screen.auxiliaryTopRightArea?.width
            } else {
                statusWidth = nil
            }
            return Display(width: screen.frame.width, statusWidth: statusWidth)
        }
    }
}
