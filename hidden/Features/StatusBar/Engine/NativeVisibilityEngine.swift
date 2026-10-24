//
//  NativeVisibilityEngine.swift
//  Hidden Bar
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit
import os.log

// The arrow is the hiding boundary. AX frames of hidden items are stale, so
// their sections survive until an unrestricted read. New items are still live.
// The allow-list backend receives explicit, positively observed hide targets;
// the assessment backend uses the corresponding allow list.
final class NativeVisibilityEngine: MenuBarEngine {
    static let systemItemsToKeep = Array(0..<64)

    private weak var items: MenuBarItemProvider?
    private let inventory: MenuBarInventoryProviding
    private let visibility: NativeVisibilityProviding
    private let ownBundleIdentifier: String?
    private let itemFrame: (NSStatusItem) -> CGRect?
    private let isLTR: () -> Bool
    private let launchNotifications: NotificationCenter
    private let sectionOverrides: () -> [String: MenuBarSection]
    private let keepsIndicatorsWhenExpanded: () -> Bool
    private let schedule: (TimeInterval, @escaping () -> Void) -> DispatchWorkItem
    private var launchObserver: NSObjectProtocol?
    private var discovery: DispatchWorkItem?
    private var discoveryInFlight = false
    private var retriesRemaining = 5

    private(set) var state: MenuBarEngineState = .expanded
    private(set) var layout: MenuBarLayout?
    private(set) var unavailableReason: HidingUnavailableReason?
    private var assertion: NativeVisibilityAssertion?
    private var failedRestorations: [NativeVisibilityAssertion] = []
    private var assertionHidesOnlyAlwaysHidden = false
    private var activeHidden = Set<String>()
    private var activeAllowed = Set<String>()
    private var iconBundles = Set<String>()
    private var unreadableBundles = Set<String>()
    private var generation = 0
    private var pendingCollapses: [(CollapseResult) -> Void] = []
    private var alwaysHiddenEnabled = false
    private var alwaysHiddenSeparatorHidden = false
    private var cachedAlwaysHiddenPlacement = false

    init(items: MenuBarItemProvider,
         inventory: MenuBarInventoryProviding = AccessibilityMenuBarInventory(),
         visibility: NativeVisibilityProviding = NativeVisibilityBridge(),
         ownBundleIdentifier: String? = Bundle.main.bundleIdentifier,
         itemFrame: @escaping (NSStatusItem) -> CGRect? = { $0.button?.window?.frame },
         isLTR: @escaping () -> Bool = { Constant.isUsingLTRLanguage },
         launchNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         sectionOverrides: @escaping () -> [String: MenuBarSection] = { [:] },
         keepsIndicatorsWhenExpanded: @escaping () -> Bool = { false },
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> DispatchWorkItem = { delay, body in
             let work = DispatchWorkItem(block: body)
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
             return work
         }) {
        self.items = items
        self.inventory = inventory
        self.visibility = visibility
        self.ownBundleIdentifier = ownBundleIdentifier
        self.itemFrame = itemFrame
        self.isLTR = isLTR
        self.launchNotifications = launchNotifications
        self.sectionOverrides = sectionOverrides
        self.keepsIndicatorsWhenExpanded = keepsIndicatorsWhenExpanded
        self.schedule = schedule
        items.separatorItem.isVisible = false
        launchObserver = launchNotifications.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.applicationLaunched()
        }
    }

    deinit {
        discovery?.cancel()
        if let observer = launchObserver { launchNotifications.removeObserver(observer) }
    }

    func collapse(completion: @escaping (CollapseResult) -> Void) {
        if state == .collapsed {
            applicationLaunched()
            return completion(.collapsed)
        }
        pendingCollapses.append(completion)
        guard state != .calibrating else { return }
        if unavailableReason == .restoreFailed {
            revealAll()
            return finishCollapses(.unavailable)
        }
        guard visibility.isAvailable else {
            report(visibility.unavailableReason)
            state = .unavailable
            return finishCollapses(.unavailable)
        }
        guard inventory.isAuthorized else {
            inventory.requestAuthorization()
            report(.accessibilityNeeded)
            return finishCollapses(.unavailable)
        }
        generation += 1
        discovery?.cancel()
        discoveryInFlight = false
        let version = generation
        state = .calibrating
        readLayout { [weak self] read, icons, unreadable in
            guard let self = self, self.generation == version else { return }
            guard let read = read else {
                self.state = .expanded
                self.report(.boundaryUnreadable)
                return self.finishCollapses(.unavailable)
            }
            self.remember(read, icons: icons, unreadable: unreadable)
            self.activate(hidesOnlyAlwaysHidden: false, version: version) { succeeded in
                guard self.generation == version else { return }
                self.state = succeeded ? .collapsed : (self.unavailableReason == .restoreFailed ? .unavailable : .expanded)
                self.setSeparatorsVisible(!succeeded && self.unavailableReason != .restoreFailed)
                self.finishCollapses(succeeded ? .collapsed : .unavailable)
            }
        }
    }

    func expand() {
        cancelPending()
        // A failed restore is always retried before applying another restriction.
        if unavailableReason == .restoreFailed {
            return revealAll()
        }
        state = .expanded
        applyExpandedPresentation()
    }

    func requestAccess() {
        visibility.requestAccess()
    }

    func updateAlwaysHiddenSection(enabled: Bool, separatorHidden: Bool) {
        alwaysHiddenEnabled = enabled
        alwaysHiddenSeparatorHidden = separatorHidden
        if state == .collapsed {
            setSeparatorsVisible(false)
        } else if state == .expanded {
            cancelPending()
            applyExpandedPresentation()
        }
    }

    func invalidateLayout() {
        if assertion == nil && state != .calibrating { layout = nil }
    }

    func applicationLaunched() {
        retriesRemaining = 5
        reconcile()
    }

    private var hidesAlwaysHiddenSectionWhenExpanded: Bool {
        alwaysHiddenEnabled && alwaysHiddenSeparatorHidden && !keepsIndicatorsWhenExpanded()
    }

    private func effective(_ layout: MenuBarLayout) -> MenuBarLayout {
        layout.applying(overrides: sectionOverrides(), alwaysHiddenEnabled: alwaysHiddenEnabled)
    }

    private func applyExpandedPresentation(completion: @escaping (Bool) -> Void = { _ in }) {
        guard hidesAlwaysHiddenSectionWhenExpanded, visibility.isAvailable, inventory.isAuthorized else {
            revealAll()
            return completion(unavailableReason != .restoreFailed)
        }
        let version = generation
        readLayout { [weak self] read, icons, unreadable in
            guard let self = self, self.generation == version else { return completion(false) }
            guard let read = read else {
                self.revealAll()
                return completion(false)
            }
            self.remember(read, icons: icons, unreadable: unreadable)
            self.activate(hidesOnlyAlwaysHidden: true, version: version) { succeeded in
                guard self.generation == version else { return completion(false) }
                if !succeeded && self.unavailableReason == .restoreFailed { self.state = .unavailable }
                self.setSeparatorsVisible(!succeeded && self.unavailableReason != .restoreFailed)
                completion(succeeded)
            }
        }
    }

    var supportsSectionAssignment: Bool { true }

    func readSections(completion: @escaping (MenuBarLayout?) -> Void) {
        readLayout { read, _, _ in completion(read) }
    }

    func reapplySections(completion: @escaping (Bool) -> Void) {
        switch state {
        case .collapsed:
            generation += 1
            discovery?.cancel()
            discoveryInFlight = false
            let version = generation
            readLayout { [weak self] read, icons, unreadable in
                guard let self = self, version == self.generation else { return completion(false) }
                guard let read = read else { return completion(false) }
                self.remember(read, icons: icons, unreadable: unreadable)
                self.activate(hidesOnlyAlwaysHidden: false, version: version) { succeeded in
                    guard version == self.generation else { return completion(false) }
                    if !succeeded {
                        self.state = self.unavailableReason == .restoreFailed ? .unavailable : .expanded
                        self.setSeparatorsVisible(self.unavailableReason != .restoreFailed)
                    }
                    completion(succeeded)
                }
            }
        case .expanded:
            cancelPending()
            applyExpandedPresentation(completion: completion)
        case .calibrating:
            // The pending collapse reads overrides at activation time.
            completion(true)
        case .unavailable:
            completion(false)
        }
    }

    private func remember(_ read: MenuBarLayout, icons: Set<String>, unreadable: Set<String>) {
        layout = read
        iconBundles = icons
        unreadableBundles = unreadable
    }

    // Cached hidden sections never cross coordinate epochs. A new app is
    // classified from its live frame; unreadable apps retain their old section
    // for the sheet but are excluded from new hide requests.
    private func readLayout(_ completion: @escaping (MenuBarLayout?, Set<String>, Set<String>) -> Void) {
        let cached = layout
        let restricted = assertion != nil
        guard inventory.isAuthorized, let arrow = items?.toggleItem,
              let boundary = itemFrame(arrow) else {
            var read = cached
            read?.isCached = true
            return completion(read, [], [])
        }
        let alwaysFrame = alwaysHiddenEnabled && !restricted ? items?.alwaysHiddenItem.flatMap(itemFrame) : nil
        let ltr = isLTR()
        if let frame = alwaysFrame {
            cachedAlwaysHiddenPlacement = ltr ? frame.midX <= boundary.midX : frame.midX >= boundary.midX
        }
        let held = activeHidden.subtracting(assertion?.unmatchedHiddenBundleIdentifiers ?? [])
        let partial = assertionHidesOnlyAlwaysHidden
        inventory.snapshot { [weak self] snapshot in
            guard let self = self else { return completion(nil, [], []) }
            var sectionBoundary = alwaysFrame
            if restricted && partial && self.alwaysHiddenEnabled, let cached = cached {
                // With the separator absent, the leading edge of the live hidden
                // section is its boundary. If that section is empty it is the arrow.
                let hiddenFrames = snapshot.items.filter {
                    $0.bundleIdentifier.flatMap { self.effective(cached).sections[$0] } == .hidden
                }.map(\.frame)
                if let edge = ltr ? hiddenFrames.map(\.minX).min() : hiddenFrames.map(\.maxX).max() {
                    sectionBoundary = CGRect(x: edge, y: 0, width: 0, height: 1)
                } else if !self.effective(cached).sections.values.contains(.hidden) {
                    sectionBoundary = boundary
                }
            }
            var read = MenuBarLayoutResolver.resolve(inventory: snapshot.items,
                                                     separatorFrame: boundary,
                                                     alwaysHiddenSeparatorFrame: sectionBoundary,
                                                     isLTR: ltr, excludingBundle: self.ownBundleIdentifier)
            if restricted {
                for (bundle, section) in cached?.sections ?? [:] {
                    if !snapshot.noIconBundles.contains(bundle) || held.contains(bundle) {
                        // Even a previously visible app fails open if a width
                        // change moved the live arrow across its old coordinates.
                        read.sections[bundle] = section
                    }
                }
            }
            for bundle in snapshot.unreadableBundles {
                read.sections[bundle] = cached?.sections[bundle] ?? .visible
            }
            read.isCached = restricted || !snapshot.unreadableBundles.isEmpty
            let icons = snapshot.iconBundles.union(restricted ? held : []).subtracting(snapshot.unreadableBundles)
            completion(read, icons, snapshot.unreadableBundles)
        }
    }

    private func targets(onlyAlwaysHidden: Bool) -> (hidden: Set<String>, allowed: Set<String>) {
        let chosen = effective(layout ?? MenuBarLayout(sections: [:]))
        let sections: Set<MenuBarSection> = onlyAlwaysHidden ? [.alwaysHidden] : [.hidden, .alwaysHidden]
        let hidden = Set(chosen.bundles(in: sections)).intersection(iconBundles)
        // Iconless parents must not protect a shared entry that represents a
        // hidden helper. An unreadable app, however, must fail open.
        var allowed = iconBundles.subtracting(hidden).union(unreadableBundles)
        if let own = ownBundleIdentifier { allowed.insert(own) }
        allowed.formUnion(MenuBarLayoutResolver.systemItemOwners.intersection(iconBundles))
        return (hidden, allowed)
    }

    private func activate(hidesOnlyAlwaysHidden: Bool, version: Int, completion: @escaping (Bool) -> Void) {
        let requested = targets(onlyAlwaysHidden: hidesOnlyAlwaysHidden)
        let allowed = ownBundleIdentifier.map { [$0] } ?? []
        let sorted = allowed + requested.allowed.subtracting(allowed).sorted()
        // An absent item keeps its saved trailing distance. Zero width still
        // participates in MenuBarAgent's persistence while its neighbours are off.
        setSeparatorsVisible(false)
        visibility.activate(allowedSystemItems: Self.systemItemsToKeep,
                            allowedBundleIdentifiers: sorted,
                            hiddenBundleIdentifiers: requested.hidden) { [weak self] result in
            guard let self = self else {
                if case .success(let handle) = result { handle.invalidate() }
                return completion(false)
            }
            guard self.generation == version else {
                if case .success(let handle) = result, !handle.invalidate() {
                    self.failedRestorations.append(handle)
                    self.state = .unavailable
                    self.report(.restoreFailed)
                }
                return completion(false)
            }
            switch result {
            case .success(let handle):
                if let old = self.assertion, !old.invalidate() {
                    self.failedRestorations.append(old)
                }
                self.assertion = handle
                self.assertionHidesOnlyAlwaysHidden = hidesOnlyAlwaysHidden
                self.activeHidden = requested.hidden
                self.activeAllowed = requested.allowed
                if self.failedRestorations.isEmpty {
                    self.unavailableReason = nil
                } else {
                    self.report(.restoreFailed)
                }
                self.scheduleDiscovery()
                completion(self.failedRestorations.isEmpty)
            case .failure:
                let restored = self.releaseAssertion()
                if restored { self.report(.activationFailed) }
                completion(false)
            }
        }
    }

    private func reconcile() {
        guard assertion != nil, state != .calibrating, unavailableReason != .restoreFailed,
              !discoveryInFlight else { return }
        discovery?.cancel()
        discoveryInFlight = true
        let version = generation
        let partial = assertionHidesOnlyAlwaysHidden
        readLayout { [weak self] read, icons, unreadable in
            guard let self = self else { return }
            guard version == self.generation else { return }
            self.discoveryInFlight = false
            guard let read = read else { return self.scheduleDiscovery() }
            self.remember(read, icons: icons, unreadable: unreadable)
            let next = self.targets(onlyAlwaysHidden: partial)
            let changed = next.hidden != self.activeHidden || next.allowed != self.activeAllowed
            let unmatched = !(self.assertion?.unmatchedHiddenBundleIdentifiers.isEmpty ?? true)
            if changed { self.retriesRemaining = 5 }
            guard changed || (unmatched && self.retriesRemaining > 0) else {
                return self.scheduleDiscovery()
            }
            if unmatched { self.retriesRemaining -= 1 }
            self.discoveryInFlight = true
            self.activate(hidesOnlyAlwaysHidden: partial, version: version) { succeeded in
                guard version == self.generation else { return }
                self.discoveryInFlight = false
                if !succeeded {
                    self.state = self.unavailableReason == .restoreFailed ? .unavailable : .expanded
                    self.setSeparatorsVisible(self.unavailableReason != .restoreFailed)
                }
            }
        }
    }

    private func scheduleDiscovery() {
        discovery?.cancel()
        // Polling also detects items created by an already running app. Only
        // unmatched targets are retried, at most five times per launch/change.
        discovery = schedule(1) { [weak self] in self?.reconcile() }
    }

    private func cancelPending() {
        generation += 1
        discovery?.cancel()
        discoveryInFlight = false
        finishCollapses(.cancelled)
    }

    private func finishCollapses(_ result: CollapseResult) {
        let callbacks = pendingCollapses
        pendingCollapses = []
        callbacks.forEach { $0(result) }
    }

    private func revealAll() {
        let restored = releaseAssertion()
        state = restored ? .expanded : .unavailable
        if restored { unavailableReason = nil }
        setSeparatorsVisible(restored)
    }

    @discardableResult private func releaseAssertion() -> Bool {
        discovery?.cancel()
        discoveryInFlight = false
        failedRestorations = failedRestorations.filter { !$0.invalidate() }
        let restored = assertion?.invalidate() ?? visibility.restoreAll()
        guard restored && failedRestorations.isEmpty else {
            report(.restoreFailed)
            return false
        }
        assertion = nil
        assertionHidesOnlyAlwaysHidden = false
        activeHidden = []
        activeAllowed = []
        return true
    }

    private func setSeparatorsVisible(_ visible: Bool) {
        items?.separatorItem.isVisible = false
        guard let separator = items?.alwaysHiddenItem else { return }
        separator.isVisible = visible && alwaysHiddenEnabled
        separator.length = alwaysHiddenEnabled ? 20 : 0
    }

    var isArrangementValid: Bool { true }
    var isAlwaysHiddenSeparatorPlaced: Bool {
        if items?.alwaysHiddenItem?.isVisible == false { return cachedAlwaysHiddenPlacement }
        return MenuBarOrder.isItem(items?.alwaysHiddenItem, onHiddenSideOf: items?.toggleItem)
    }

    private func report(_ reason: HidingUnavailableReason) {
        guard unavailableReason != reason else { return }
        unavailableReason = reason
        os_log("Hiding unavailable: %{public}@", log: OSLog(subsystem: "com.dwarvesv.minimalbar", category: "NativeVisibility"), type: .error, String(describing: reason))
    }
}
