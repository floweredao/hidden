//
//  NativeVisibilityEngine.swift
//  Hidden Bar
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit

// macOS 27 hiding for the direct (non-App Store) build. Instead of inflating the
// separator, which macOS 27 ejects from the layout once it is too wide (#360),
// this reads which apps the user placed in each section and asks macOS to show
// only the allowed ones through the menu-bar visibility restriction behind
// assessment mode. macOS then hides the rest and reflows the bar itself, so the
// result does not depend on display width, the notch or the frontmost app's menus.
//
// The arrow is the boundary: apps left of it (LTR) are hidden, apps right of it
// stay visible. The regular separator is not needed and is taken out of the
// bar; even at zero width macOS keeps a gap for it. The always-hidden
// separator, when enabled, marks the third section; it shows while that section
// is shown so it can be ⌘-dragged, and drops to zero width while the section is
// hidden (collapsed, or expanded with "hide separators" on), where macOS has
// already removed everything it would separate. It keeps its slot because its
// position is what defines that section.
//
// Limits, all from what macOS 27 exposes:
// - Hiding is per app: an app with several icons hides or shows them together
//   (the most visible section wins).
// - macOS's own items (clock, Wi-Fi, Control Center...) are always kept visible:
//   Accessibility cannot tell them apart, so they cannot be mapped to sections.
// - Hidden items report stale positions, so sections are read from an
//   unrestricted bar. While only the always-hidden section is hidden, the rest
//   of the bar is still read live and only that section comes from the last
//   read. An app launched while collapsed stays hidden until the next collapse,
//   the same as a new icon landing in the hidden section under the old
//   mechanism; one launched while expanded is shown.
final class NativeVisibilityEngine: MenuBarEngine {
    // System item identifiers to keep visible. Unknown identifiers are ignored,
    // so the range covers items a given Mac does not have (0-63 checked on 27.0).
    static let systemItemsToKeep = Array(0..<64)

    private weak var items: MenuBarItemProvider?
    private let inventory: MenuBarInventoryProviding
    private let visibility: NativeVisibilityProviding
    private let ownBundleIdentifier: String?
    private let itemFrame: (NSStatusItem) -> CGRect?
    private let isLTR: () -> Bool
    private let runningBundleIdentifiers: () -> [String]
    private let launchNotifications: NotificationCenter
    // The per-app sections chosen in Settings; they win over positions.
    private let sectionOverrides: () -> [String: MenuBarSection]
    private var launchObserver: NSObjectProtocol?

    private let expandedLength: CGFloat = 20

    // .calibrating stands for "an activation is in flight".
    private(set) var state: MenuBarEngineState = .expanded
    private(set) var layout: MenuBarLayout?

    private var assertion: NativeVisibilityAssertion?
    // Whether the held restriction hides only the always-hidden section, which
    // leaves every other item live and readable.
    private var assertionHidesOnlyAlwaysHidden = false
    // Bumped whenever a pending activation must no longer win (an expand, a newer
    // activation); a late success is then invalidated straight away.
    private var generation = 0
    private var lastUnavailableReason: String?
    private(set) var unavailableReason: HidingUnavailableReason?

    private var alwaysHiddenEnabled = false
    private var alwaysHiddenSeparatorHidden = false

    init(items: MenuBarItemProvider,
         inventory: MenuBarInventoryProviding = AccessibilityMenuBarInventory(),
         visibility: NativeVisibilityProviding = NativeVisibilityBridge(),
         ownBundleIdentifier: String? = Bundle.main.bundleIdentifier,
         itemFrame: @escaping (NSStatusItem) -> CGRect? = { $0.button?.window?.frame },
         isLTR: @escaping () -> Bool = { Constant.isUsingLTRLanguage },
         runningBundleIdentifiers: @escaping () -> [String] = { NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier) },
         launchNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         sectionOverrides: @escaping () -> [String: MenuBarSection] = { [:] }) {
        self.items = items
        self.inventory = inventory
        self.visibility = visibility
        self.ownBundleIdentifier = ownBundleIdentifier
        self.itemFrame = itemFrame
        self.isLTR = isLTR
        self.runningBundleIdentifiers = runningBundleIdentifiers
        self.launchNotifications = launchNotifications
        self.sectionOverrides = sectionOverrides
        items.separatorItem.isVisible = false
        launchObserver = launchNotifications.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applicationLaunched()
        }
    }

    deinit {
        if let launchObserver = launchObserver {
            launchNotifications.removeObserver(launchObserver)
        }
    }

    func collapse(completion: @escaping (CollapseResult) -> Void) {
        switch state {
        case .collapsed:
            return completion(.collapsed)
        case .calibrating:
            // The activation in flight answers the request that started it.
            return
        case .expanded, .unavailable:
            break
        }
        if !hidesAlwaysHiddenSection {
            setSeparatorsVisible(true)
        }

        guard visibility.isAvailable else {
            report(.notSupported, "the native menu-bar visibility API is not available in this build or on this macOS")
            state = .unavailable
            return completion(.unavailable)
        }
        guard inventory.isAuthorized else {
            // Without Accessibility the sections cannot be read, and guessing would
            // hide icons the user kept visible. Not latched: it works as soon as
            // the permission is granted.
            inventory.requestAuthorization()
            report(.accessibilityNeeded, "Accessibility permission is needed to read the menu-bar sections")
            return completion(.unavailable)
        }
        state = .calibrating
        withLayout { [weak self] layout in
            guard let self = self else { return }
            guard let layout = layout else {
                self.report(.boundaryUnreadable, "the arrow's position cannot be read yet")
                self.state = .expanded
                return completion(.unavailable)
            }
            self.activate(allowing: self.effective(layout).bundles(in: [.visible]), hidesOnlyAlwaysHidden: false) { [weak self] succeeded in
                guard let self = self else { return }
                self.state = succeeded ? .collapsed : .expanded
                if succeeded {
                    self.clearReport()
                } else {
                    self.report(.activationFailed, "macOS refused the visibility restriction")
                }
                // On failure the whole bar is shown, separator included.
                self.setSeparatorsVisible(!succeeded)
                completion(succeeded ? .collapsed : .unavailable)
            }
        }
    }

    func expand() {
        state = .expanded
        applyExpandedPresentation()
    }

    func updateAlwaysHiddenSection(enabled: Bool, separatorHidden: Bool) {
        alwaysHiddenEnabled = enabled
        alwaysHiddenSeparatorHidden = separatorHidden
        switch state {
        case .collapsed:
            // A separator created while collapsed arrives with a width.
            setSeparatorsVisible(false)
        case .expanded:
            applyExpandedPresentation()
        case .calibrating, .unavailable:
            setSeparatorsVisible(!hidesAlwaysHiddenSection)
        }
    }

    // Native hiding does not depend on display geometry, so only drop the cached
    // sections; the next read from an unrestricted bar replaces them.
    func invalidateLayout() {
        if assertion == nil {
            layout = nil
        }
    }

    // An app launched while expanded with the always-hidden section hidden is not
    // on the allow list yet; without this its icon would stay hidden.
    func applicationLaunched() {
        guard state == .expanded, assertion != nil, assertionHidesOnlyAlwaysHidden else { return }
        applyExpandedPresentation()
    }

    private var hidesAlwaysHiddenSection: Bool {
        return alwaysHiddenEnabled && alwaysHiddenSeparatorHidden
    }

    // Expanded shows the hidden section; the always-hidden section stays hidden
    // while "hide separators" is on, otherwise everything is revealed by dropping
    // the restriction altogether. Its separator comes back only if the icons
    // could not be hidden, so it never disappears on its own.
    private func applyExpandedPresentation() {
        guard hidesAlwaysHiddenSection, visibility.isAvailable, inventory.isAuthorized else {
            return revealAll()
        }
        withLayout { [weak self] layout in
            guard let self = self else { return }
            guard let layout = layout else {
                return self.revealAll()
            }
            // Running apps the sections have not seen yet (launched since the last
            // read) are not in the always-hidden section, so they are shown.
            let chosen = self.effective(layout)
            let known = Set(chosen.sections.keys)
            let unseen = Set(self.runningBundleIdentifiers()).subtracting(known).sorted()
            self.activate(allowing: chosen.bundles(in: [.visible, .hidden]) + unseen, hidesOnlyAlwaysHidden: true) { [weak self] succeeded in
                guard let self = self, self.state == .expanded else { return }
                self.setSeparatorsVisible(!succeeded)
            }
        }
    }

    private func effective(_ layout: MenuBarLayout) -> MenuBarLayout {
        return layout.applying(overrides: sectionOverrides(), alwaysHiddenEnabled: alwaysHiddenEnabled)
    }

    var supportsSectionAssignment: Bool {
        return true
    }

    // For Settings: a fresh read when the bar is unrestricted (or only the
    // always-hidden section is hidden), the last read otherwise. Unlike
    // withLayout it leaves the cached sections and any activation in flight alone.
    func readSections(completion: @escaping (MenuBarLayout?) -> Void) {
        let restricted = assertion != nil
        guard inventory.isAuthorized,
              state != .calibrating,
              !restricted || assertionHidesOnlyAlwaysHidden,
              let arrow = items?.toggleItem,
              let boundary = itemFrame(arrow) else { return completion(layout) }
        let keptAlwaysHidden = restricted ? (layout?.sections.filter { $0.value == .alwaysHidden } ?? [:]) : [:]
        let alwaysHiddenFrame = alwaysHiddenEnabled && !restricted ? items?.alwaysHiddenItem.flatMap(itemFrame) : nil
        let isLTR = self.isLTR()
        inventory.snapshot { [weak self] inventory in
            guard let self = self else { return completion(nil) }
            var read = MenuBarLayoutResolver.resolve(inventory: inventory,
                                                     separatorFrame: boundary,
                                                     alwaysHiddenSeparatorFrame: alwaysHiddenFrame,
                                                     isLTR: isLTR,
                                                     excludingBundle: self.ownBundleIdentifier)
            read.sections.merge(keptAlwaysHidden) { _, kept in kept }
            completion(read)
        }
    }

    // Collapsed: swap in a restriction built from the cached sections and the new
    // choices (new before old, so nothing flashes). Expanded: redo the expanded
    // presentation, which also uses the choices.
    func reapplySections(completion: @escaping (Bool) -> Void) {
        switch state {
        case .collapsed:
            guard let layout = layout else { return completion(true) }
            activate(allowing: effective(layout).bundles(in: [.visible]), hidesOnlyAlwaysHidden: false) { [weak self] succeeded in
                guard let self = self else { return }
                if !succeeded {
                    self.state = .expanded
                    self.setSeparatorsVisible(true)
                    self.report(.activationFailed, "macOS refused the visibility restriction")
                }
                completion(succeeded)
            }
        case .expanded:
            applyExpandedPresentation()
            completion(true)
        case .calibrating, .unavailable:
            // A collapse in flight reads the choices when it activates.
            completion(true)
        }
    }

    private func revealAll() {
        releaseAssertion()
        setSeparatorsVisible(true)
    }

    // The sections as the user arranged them. Read fresh from an unrestricted
    // bar. While only the always-hidden section is hidden, the rest is read fresh
    // and that section is kept from the last read; under any other restriction
    // the cached sections stand in. Superseded by any later expand or
    // activation, like an activation is.
    private func withLayout(_ body: @escaping (MenuBarLayout?) -> Void) {
        let keptAlwaysHidden: [String: MenuBarSection]
        if assertion != nil {
            guard assertionHidesOnlyAlwaysHidden, let cached = layout else { return body(layout) }
            keptAlwaysHidden = cached.sections.filter { $0.value == .alwaysHidden }
        } else {
            keptAlwaysHidden = [:]
        }
        let restricted = assertion != nil
        guard let arrow = items?.toggleItem,
              let boundary = itemFrame(arrow) else { return body(restricted ? layout : nil) }
        // The always-hidden separator has no width while its section is hidden,
        // so its position is only used from an unrestricted bar.
        let alwaysHiddenFrame = alwaysHiddenEnabled && !restricted ? items?.alwaysHiddenItem.flatMap(itemFrame) : nil
        let isLTR = self.isLTR()
        generation += 1
        let generation = self.generation
        inventory.snapshot { [weak self] inventory in
            guard let self = self, generation == self.generation else { return }
            var layout = MenuBarLayoutResolver.resolve(inventory: inventory,
                                                       separatorFrame: boundary,
                                                       alwaysHiddenSeparatorFrame: alwaysHiddenFrame,
                                                       isLTR: isLTR,
                                                       excludingBundle: self.ownBundleIdentifier)
            layout.sections.merge(keptAlwaysHidden) { _, kept in kept }
            NSLog("NativeVisibility: arrow at x=\(boundary.midX); visible \(layout.bundles(in: [.visible])), hidden \(layout.bundles(in: [.hidden])), always hidden \(layout.bundles(in: [.alwaysHidden]))")
            self.layout = layout
            body(layout)
        }
    }

    // Activates the new restriction before dropping the old one, so switching
    // between collapsed and expanded never flashes the whole bar visible.
    private func activate(allowing bundles: [String], hidesOnlyAlwaysHidden: Bool, completion: @escaping (Bool) -> Void) {
        generation += 1
        let generation = self.generation
        var allowed = ownBundleIdentifier.map { [$0] } ?? []
        for bundle in bundles where !allowed.contains(bundle) {
            allowed.append(bundle)
        }
        visibility.activate(allowedSystemItems: Self.systemItemsToKeep,
                            allowedBundleIdentifiers: allowed) { [weak self] result in
            guard let self = self, generation == self.generation else {
                if case .success(let stale) = result { stale.invalidate() }
                return
            }
            switch result {
            case .success(let newAssertion):
                let old = self.assertion
                self.assertion = newAssertion
                self.assertionHidesOnlyAlwaysHidden = hidesOnlyAlwaysHidden
                old?.invalidate()
                completion(true)
            case .failure(let error):
                // Fail open: never leave icons hidden after an error.
                NSLog("NativeVisibility: activation failed: \(error.localizedDescription)")
                self.releaseAssertion()
                completion(false)
            }
        }
    }

    // The always-hidden separator goes to zero width rather than isVisible =
    // false, which would make macOS forget where the user placed it.
    private func setSeparatorsVisible(_ visible: Bool) {
        items?.separatorItem.isVisible = false
        items?.alwaysHiddenItem?.length = visible && alwaysHiddenEnabled ? expandedLength : 0
    }

    // Any arrangement works: whatever sits left of the arrow is the hidden section.
    var isArrangementValid: Bool {
        return true
    }

    var isAlwaysHiddenSeparatorPlaced: Bool {
        return MenuBarOrder.isItem(items?.alwaysHiddenItem, onHiddenSideOf: items?.toggleItem)
    }

    private func releaseAssertion() {
        generation += 1
        assertion?.invalidate()
        assertion = nil
        assertionHidesOnlyAlwaysHidden = false
    }

    // Kept for the UI; logged when the reason changes, so a retried collapse
    // does not spam.
    private func report(_ reason: HidingUnavailableReason, _ detail: String) {
        unavailableReason = reason
        guard detail != lastUnavailableReason else { return }
        lastUnavailableReason = detail
        NSLog("NativeVisibility: hiding unavailable: \(detail)")
    }

    private func clearReport() {
        unavailableReason = nil
        lastUnavailableReason = nil
    }
}
