//
//  MenuBarEngineTests.swift
//  HiddenBarTests
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit
import XCTest

// The engine sources are compiled straight into this bundle (no host app), so
// the tests never put items in the real menu bar, never need Accessibility, and
// never touch the private visibility API.

// MARK: - Fakes

private final class FakeItems: MenuBarItemProvider {
    private let bar = NSStatusBar()
    let toggleItem: NSStatusItem
    let separatorItem: NSStatusItem
    var alwaysHiddenItem: NSStatusItem?

    init() {
        toggleItem = bar.statusItem(withLength: NSStatusItem.variableLength)
        separatorItem = bar.statusItem(withLength: 1)
        alwaysHiddenItem = bar.statusItem(withLength: 20)
    }
}

private final class FakeInventory: MenuBarInventoryProviding {
    var isAuthorized = true
    var items: [MenuBarInventoryItem] = []
    var authorizationRequests = 0
    var snapshots = 0
    var unreadableBundles = Set<String>()
    var noIconBundles = Set<String>()
    var deferred = false
    var pending: [(MenuBarInventorySnapshot) -> Void] = []

    func requestAuthorization() {
        authorizationRequests += 1
    }

    func snapshot(completion: @escaping (MenuBarInventorySnapshot) -> Void) {
        snapshots += 1
        if deferred {
            pending.append(completion)
        } else {
            completion(.init(items: items, unreadableBundles: unreadableBundles, noIconBundles: noIconBundles))
        }
    }

    func deliver() {
        pending.removeFirst()(.init(items: items, unreadableBundles: unreadableBundles, noIconBundles: noIconBundles))
    }
}

private final class FakeAssertion: NativeVisibilityAssertion {
    let allowed: [String]
    private(set) var isInvalidated = false
    var onInvalidate: (() -> Void)?
    var restoresSuccessfully = true
    var unmatchedHiddenBundleIdentifiers = Set<String>()
    var invalidations = 0

    init(allowed: [String]) {
        self.allowed = allowed
    }

    @discardableResult func invalidate() -> Bool {
        invalidations += 1
        isInvalidated = restoresSuccessfully
        onInvalidate?()
        return restoresSuccessfully
    }
}

// Hands every activation to the test, which decides when and how it completes.
private final class FakeVisibility: NativeVisibilityProviding {
    struct Request {
        let systemItems: [Int]
        let bundles: [String]
        let hidden: Set<String>
        let completion: (Result<NativeVisibilityAssertion, Error>) -> Void
    }

    var isAvailable = true
    var requests: [Request] = []
    var unavailableReason: HidingUnavailableReason = .notSupported
    var accessRequests = 0
    var restoresSuccessfully = true
    var restores = 0

    func requestAccess() { accessRequests += 1 }
    func restoreAll() -> Bool {
        restores += 1
        return restoresSuccessfully
    }

    func activate(allowedSystemItems: [Int],
                  allowedBundleIdentifiers: [String],
                  completion: @escaping (Result<NativeVisibilityAssertion, Error>) -> Void) {
        activate(allowedSystemItems: allowedSystemItems, allowedBundleIdentifiers: allowedBundleIdentifiers,
                 hiddenBundleIdentifiers: [], completion: completion)
    }

    func activate(allowedSystemItems: [Int], allowedBundleIdentifiers: [String],
                  hiddenBundleIdentifiers: Set<String>,
                  completion: @escaping (Result<NativeVisibilityAssertion, Error>) -> Void) {
        requests.append(Request(systemItems: allowedSystemItems, bundles: allowedBundleIdentifiers,
                                hidden: hiddenBundleIdentifiers, completion: completion))
    }

    @discardableResult
    func succeed(_ index: Int, unmatched: Set<String> = []) -> FakeAssertion {
        let assertion = FakeAssertion(allowed: requests[index].bundles)
        assertion.unmatchedHiddenBundleIdentifiers = unmatched
        requests[index].completion(.success(assertion))
        return assertion
    }

    func fail(_ index: Int) {
        requests[index].completion(.failure(NSError(domain: "test", code: 1)))
    }
}

private final class ManualScheduler {
    var pending: [DispatchWorkItem] = []

    func schedule(_ delay: TimeInterval, _ body: @escaping () -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem(block: body)
        pending.append(work)
        return work
    }

    func fire() {
        while !pending.isEmpty {
            let work = pending.removeFirst()
            if !work.isCancelled {
                work.perform()
                return
            }
        }
        XCTFail("No scheduled discovery")
    }
}

private func item(_ bundle: String?, x: CGFloat, width: CGFloat = 24) -> MenuBarInventoryItem {
    return MenuBarInventoryItem(bundleIdentifier: bundle, frame: CGRect(x: x, y: 0, width: width, height: 24))
}

// LTR bar used throughout: always-hidden separator at 1000, the boundary at 1300
// (the separator for the resolver, the arrow for the native engine).
private let alwaysHiddenSeparator = CGRect(x: 1000, y: 0, width: 20, height: 24)
private let separator = CGRect(x: 1300, y: 0, width: 20, height: 24)

private func isolatedDefaults(_ test: XCTestCase) -> UserDefaults {
    let suite = "HiddenBarTests.sections.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    test.addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    return defaults
}

// MARK: - Layout resolver

final class MenuBarLayoutResolverTests: XCTestCase {
    func testLTRSectionsFollowSeparators() {
        let layout = MenuBarLayoutResolver.resolve(
            inventory: [item("com.always", x: 900), item("com.hidden", x: 1100), item("com.visible", x: 1400)],
            separatorFrame: separator, alwaysHiddenSeparatorFrame: alwaysHiddenSeparator,
            isLTR: true, excludingBundle: nil)
        XCTAssertEqual(layout.sections, ["com.always": .alwaysHidden, "com.hidden": .hidden, "com.visible": .visible])
    }

    func testRTLSectionsAreMirrored() {
        // RTL: arrow on the left, separator just right of it, hidden further right.
        let rtlSeparator = CGRect(x: 300, y: 0, width: 20, height: 24)
        let rtlAlwaysHidden = CGRect(x: 600, y: 0, width: 20, height: 24)
        let layout = MenuBarLayoutResolver.resolve(
            inventory: [item("com.visible", x: 200), item("com.hidden", x: 450), item("com.always", x: 700)],
            separatorFrame: rtlSeparator, alwaysHiddenSeparatorFrame: rtlAlwaysHidden,
            isLTR: false, excludingBundle: nil)
        XCTAssertEqual(layout.sections, ["com.always": .alwaysHidden, "com.hidden": .hidden, "com.visible": .visible])
    }

    func testWithoutAlwaysHiddenSeparatorEverythingLeftIsHidden() {
        let layout = MenuBarLayoutResolver.resolve(
            inventory: [item("com.far", x: 100), item("com.near", x: 1200)],
            separatorFrame: separator, alwaysHiddenSeparatorFrame: nil,
            isLTR: true, excludingBundle: nil)
        XCTAssertEqual(layout.sections, ["com.far": .hidden, "com.near": .hidden])
    }

    func testMostVisibleItemWinsForABundle() {
        let layout = MenuBarLayoutResolver.resolve(
            inventory: [item("com.split", x: 1100), item("com.split", x: 1400),
                        item("com.pair", x: 900), item("com.pair", x: 1100)],
            separatorFrame: separator, alwaysHiddenSeparatorFrame: alwaysHiddenSeparator,
            isLTR: true, excludingBundle: nil)
        XCTAssertEqual(layout.sections["com.split"], .visible)
        XCTAssertEqual(layout.sections["com.pair"], .hidden)
    }

    // SystemUIServer's legacy extras (Time Machine...) have no system item
    // identifier, so they must follow the arrow like any app.
    func testSystemUIServerExtrasFollowTheArrow() {
        let layout = MenuBarLayoutResolver.resolve(
            inventory: [item("com.apple.systemuiserver", x: 1400), item("com.apple.controlcenter", x: 1100)],
            separatorFrame: separator, alwaysHiddenSeparatorFrame: nil,
            isLTR: true, excludingBundle: nil)
        XCTAssertEqual(layout.sections, ["com.apple.systemuiserver": .visible])
    }

    func testSkipsOwnSystemAndUnidentifiedItems() {
        let layout = MenuBarLayoutResolver.resolve(
            inventory: [item("com.dwarvesv.minimalbar", x: 1100), item("com.apple.MenuBarAgent", x: 1100),
                        item(nil, x: 1100), item("com.app", x: 1100)],
            separatorFrame: separator, alwaysHiddenSeparatorFrame: nil,
            isLTR: true, excludingBundle: "com.dwarvesv.minimalbar")
        XCTAssertEqual(layout.sections, ["com.app": .hidden])
    }

    func testBundlesAreFilteredAndSorted() {
        let layout = MenuBarLayout(sections: ["b": .visible, "a": .visible, "c": .hidden, "d": .alwaysHidden])
        XCTAssertEqual(layout.bundles(in: [.visible]), ["a", "b"])
        XCTAssertEqual(layout.bundles(in: [.visible, .hidden]), ["a", "b", "c"])
    }
}

// MARK: - Native engine

final class NativeVisibilityEngineTests: XCTestCase {
    private var items: FakeItems!
    private var inventory: FakeInventory!
    private var visibility: FakeVisibility!
    private let launches = NotificationCenter()
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        items = FakeItems()
        inventory = FakeInventory()
        inventory.items = [item("com.always", x: 900), item("com.hidden", x: 1100), item("com.visible", x: 1400)]
        visibility = FakeVisibility()
        defaults = isolatedDefaults(self)
    }

    private func makeEngine(keepsIndicatorsWhenExpanded: @escaping () -> Bool = { false },
                            schedule: @escaping (TimeInterval, @escaping () -> Void) -> DispatchWorkItem = { _, body in DispatchWorkItem(block: body) }) -> NativeVisibilityEngine {
        let items = self.items!
        return NativeVisibilityEngine(items: items, inventory: inventory, visibility: visibility,
                                      ownBundleIdentifier: "com.dwarvesv.minimalbar",
                                      itemFrame: { $0 === items.toggleItem ? separator : alwaysHiddenSeparator },
                                      isLTR: { true },
                                      launchNotifications: launches,
                                      defaults: defaults,
                                      keepsIndicatorsWhenExpanded: keepsIndicatorsWhenExpanded,
                                      schedule: schedule)
    }

    func testRelaunchKeepsRememberedAlwaysHiddenDespiteSeparatorDrift() {
        defaults.set(["com.always": MenuBarSection.alwaysHidden.rawValue], forKey: "rememberedSections")
        inventory.items = [item("com.always", x: 1100)]
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: false)
        engine.readSections { XCTAssertEqual($0?.sections["com.always"], .alwaysHidden) }
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: true)
        XCTAssertEqual(visibility.requests.last?.hidden, ["com.always"])
    }

    func testRelaunchHidesRememberedHiddenAppRightOfArrow() {
        defaults.set(["com.hidden": MenuBarSection.hidden.rawValue], forKey: "rememberedSections")
        inventory.items = [item("com.hidden", x: 1400), item("com.visible", x: 1500)]
        let engine = makeEngine()
        engine.collapse { _ in }
        XCTAssertEqual(visibility.requests.last?.hidden, ["com.hidden"])
        XCTAssertEqual(visibility.requests.last?.bundles, ["com.dwarvesv.minimalbar", "com.visible"])
        let handle = visibility.succeed(0)
        engine.expand()
        XCTAssertTrue(handle.isInvalidated)
        XCTAssertEqual(visibility.requests.count, 1, "full expansion releases every restriction")
    }

    func testDeliberateMoveBetweenUnrestrictedReadsIsPersisted() {
        defaults.set(["com.always": MenuBarSection.alwaysHidden.rawValue], forKey: "rememberedSections")
        inventory.items = [item("com.always", x: 1100)]
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: false)
        engine.readSections { _ in }
        inventory.items = [item("com.always", x: 1400)]
        engine.readSections { XCTAssertEqual($0?.sections["com.always"], .visible) }
        XCTAssertEqual(defaults.dictionary(forKey: "rememberedSections") as? [String: Int],
                       ["com.always": MenuBarSection.visible.rawValue])
    }

    func testLaunchDriftIsNotAdoptedByIdenticalLaterReads() {
        defaults.set(["com.always": MenuBarSection.alwaysHidden.rawValue], forKey: "rememberedSections")
        inventory.items = [item("com.always", x: 1100)]
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: false)
        engine.readSections { _ in }
        engine.invalidateLayout()
        engine.readSections { XCTAssertEqual($0?.sections["com.always"], .alwaysHidden) }
        engine.collapse { _ in }
        visibility.succeed(0)
        engine.expand()
        engine.readSections { XCTAssertEqual($0?.sections["com.always"], .alwaysHidden) }
        XCTAssertEqual(defaults.dictionary(forKey: "rememberedSections") as? [String: Int],
                       ["com.always": MenuBarSection.alwaysHidden.rawValue])
    }

    func testNewAppGetsLiveSectionWithoutReplacingRememberedApps() {
        defaults.set(["com.always": MenuBarSection.alwaysHidden.rawValue], forKey: "rememberedSections")
        inventory.items = [item("com.always", x: 1100)]
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: false)
        engine.readSections { _ in }
        inventory.items.append(item("com.new", x: 1200))
        engine.readSections { XCTAssertEqual($0?.sections["com.new"], .hidden) }
        XCTAssertEqual(defaults.dictionary(forKey: "rememberedSections") as? [String: Int],
                       ["com.always": MenuBarSection.alwaysHidden.rawValue,
                        "com.new": MenuBarSection.hidden.rawValue])
    }

    func testEmptyMembershipMigratesFirstLiveArrangement() {
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: false)
        engine.readSections { _ in }
        XCTAssertEqual(defaults.dictionary(forKey: "rememberedSections") as? [String: Int],
                       ["com.always": MenuBarSection.alwaysHidden.rawValue,
                        "com.hidden": MenuBarSection.hidden.rawValue,
                        "com.visible": MenuBarSection.visible.rawValue])
    }

    func testMembershipSurvivesNewEngineAndDefaultsInstance() {
        let suite = "HiddenBarTests.relaunch.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) }
        var first: NativeVisibilityEngine? = makeEngine()
        first?.updateAlwaysHiddenSection(enabled: true, separatorHidden: false)
        first?.readSections { _ in }
        first = nil
        defaults = UserDefaults(suiteName: suite)!
        inventory.items = [item("com.always", x: 1100), item("com.hidden", x: 1400)]
        let relaunched = makeEngine()
        relaunched.updateAlwaysHiddenSection(enabled: true, separatorHidden: false)
        relaunched.readSections {
            XCTAssertEqual($0?.sections["com.always"], .alwaysHidden)
            XCTAssertEqual($0?.sections["com.hidden"], .hidden)
        }
    }

    // macOS hides its indicators (Focus, the mic/camera capsule) while any
    // restriction is held, so keeping them means expanded holds none, even with
    // the always-hidden section hidden; collapsing still hides as before.
    func testKeepingIndicatorsExpandedHoldsNoRestriction() {
        var keepsIndicators = true
        let engine = makeEngine(keepsIndicatorsWhenExpanded: { keepsIndicators })
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: true)
        XCTAssertTrue(visibility.requests.isEmpty)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 20, "its section shows, so its separator does")

        engine.collapse { _ in }
        XCTAssertEqual(visibility.requests.last?.bundles, ["com.dwarvesv.minimalbar", "com.visible"])
        let collapsed = visibility.succeed(visibility.requests.count - 1)
        XCTAssertEqual(items.alwaysHiddenItem?.isVisible, false)

        engine.expand()
        XCTAssertTrue(collapsed.isInvalidated)
        XCTAssertEqual(visibility.requests.count, 1)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 20)

        // Turned off while expanded: the always-hidden section is hidden again.
        keepsIndicators = false
        engine.reapplySections { _ in }
        XCTAssertEqual(visibility.requests.last?.bundles, ["com.dwarvesv.minimalbar", "com.hidden", "com.visible"])
    }

    func testCollapseKeepsOnlyVisibleAppsAndSystemItems() {
        let engine = makeEngine()
        var results: [CollapseResult] = []
        engine.collapse { results.append($0) }

        XCTAssertEqual(engine.state, .calibrating)
        XCTAssertEqual(visibility.requests.first?.bundles, ["com.dwarvesv.minimalbar", "com.visible"])
        XCTAssertEqual(visibility.requests.first?.systemItems, NativeVisibilityEngine.systemItemsToKeep)
        XCTAssertFalse(items.separatorItem.isVisible, "the arrow is the boundary; no separator needed")

        visibility.succeed(0)
        XCTAssertEqual(engine.state, .collapsed)
        XCTAssertEqual(results, [.collapsed])

        engine.expand()
        XCTAssertFalse(items.separatorItem.isVisible)
    }

    func testAlwaysHiddenSeparatorFollowsTheSectionSetting() {
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: false, separatorHidden: false)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 0)

        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: false)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 20)

        engine.collapse { _ in }
        visibility.succeed(visibility.requests.count - 1)
        XCTAssertEqual(items.alwaysHiddenItem?.isVisible, false)

        engine.expand()
        XCTAssertEqual(items.alwaysHiddenItem?.length, 20)
    }

    func testUnavailableAPIFailsOpen() {
        visibility.isAvailable = false
        let engine = makeEngine()
        var result: CollapseResult?
        engine.collapse { result = $0 }

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(engine.state, .unavailable)
        XCTAssertTrue(visibility.requests.isEmpty)
    }

    func testMissingAccessibilityAsksAndRetriesLater() {
        inventory.isAuthorized = false
        let engine = makeEngine()
        var results: [CollapseResult] = []
        engine.collapse { results.append($0) }

        XCTAssertEqual(results, [.unavailable])
        XCTAssertEqual(inventory.authorizationRequests, 1)
        XCTAssertTrue(visibility.requests.isEmpty, "never guess which icons to hide")

        inventory.isAuthorized = true
        engine.collapse { results.append($0) }
        XCTAssertEqual(visibility.requests.count, 1, "works once the permission is granted")
    }

    func testActivationFailureReportsUnavailable() {
        let engine = makeEngine()
        var result: CollapseResult?
        engine.collapse { result = $0 }
        visibility.fail(0)

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(engine.state, .expanded)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 0, "the always-hidden separator only shows when enabled")
    }

    func testExpandDropsTheRestriction() {
        let engine = makeEngine()
        engine.collapse { _ in }
        let collapsed = visibility.succeed(0)

        engine.expand()
        XCTAssertTrue(collapsed.isInvalidated)
        XCTAssertEqual(engine.state, .expanded)
        XCTAssertEqual(visibility.requests.count, 1)
    }

    func testExpandKeepsAlwaysHiddenSectionHiddenAndSwapsWithoutFlashing() {
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: true)
        // Expanded with separators hidden: everything but always-hidden is shown.
        XCTAssertEqual(visibility.requests.last?.bundles, ["com.dwarvesv.minimalbar", "com.hidden", "com.visible"])
        visibility.succeed(visibility.requests.count - 1)

        engine.collapse { _ in }
        let collapseIndex = visibility.requests.count - 1
        XCTAssertEqual(visibility.requests[collapseIndex].bundles, ["com.dwarvesv.minimalbar", "com.visible"])
        let collapsed = visibility.succeed(collapseIndex)

        var newIsActiveWhenOldDropped = false
        collapsed.onInvalidate = { newIsActiveWhenOldDropped = true }
        engine.expand()
        let expandIndex = visibility.requests.count - 1
        XCTAssertEqual(visibility.requests[expandIndex].bundles, ["com.dwarvesv.minimalbar", "com.hidden", "com.visible"])
        XCTAssertFalse(collapsed.isInvalidated, "the old restriction stays until the new one is active")
        visibility.succeed(expandIndex)
        XCTAssertTrue(newIsActiveWhenOldDropped)
    }

    func testRestrictedReadPreservesCachedSections() {
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: true)
        visibility.succeed(visibility.requests.count - 1)
        engine.collapse { _ in }
        visibility.succeed(visibility.requests.count - 1)
        let snapshotsBefore = inventory.snapshots

        // Hidden items would report stale positions now; the cached layout is used.
        inventory.items = [item("com.visible", x: 100)]
        engine.expand()
        XCTAssertEqual(inventory.snapshots, snapshotsBefore + 1)
        XCTAssertEqual(visibility.requests.last?.bundles, ["com.dwarvesv.minimalbar", "com.hidden", "com.visible"])
    }

    // Hidden and always-hidden sections cannot be compared with a newer arrow.
    func testPartialRestrictionKeepsHiddenSectionsAcrossCoordinateChanges() {
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: true)
        visibility.succeed(visibility.requests.count - 1)

        inventory.items = [item("com.always", x: 1400), item("com.hidden", x: 1400), item("com.visible", x: 1100)]
        engine.collapse { _ in }
        XCTAssertEqual(visibility.requests.last?.bundles, ["com.dwarvesv.minimalbar", "com.visible"])
        XCTAssertEqual(visibility.requests.last?.hidden, ["com.always", "com.hidden"])
    }

    // Hiding the always-hidden section takes its separator with it, as it did
    // before macOS 27; it only goes once the icons are actually hidden, and does
    // not flash back while collapsing or expanding.
    func testAlwaysHiddenSeparatorHidesWithItsSection() {
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: false)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 20)

        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: true)
        XCTAssertEqual(items.alwaysHiddenItem?.isVisible, false, "remove it before its neighbours are switched off")
        visibility.succeed(visibility.requests.count - 1)
        XCTAssertEqual(items.alwaysHiddenItem?.isVisible, false)

        engine.collapse { _ in }
        XCTAssertEqual(items.alwaysHiddenItem?.isVisible, false)
        visibility.succeed(visibility.requests.count - 1)

        engine.expand()
        XCTAssertEqual(items.alwaysHiddenItem?.isVisible, false)
        visibility.succeed(visibility.requests.count - 1)
        XCTAssertEqual(items.alwaysHiddenItem?.isVisible, false)

        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: false)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 20)
    }

    func testAlwaysHiddenSeparatorStaysWhenItsSectionCannotBeHidden() {
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: true)
        visibility.fail(visibility.requests.count - 1)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 20)
    }

    func testAlwaysHiddenSeparatorEnabledWhileCollapsedIsAbsent() {
        let engine = makeEngine()
        engine.collapse { _ in }
        visibility.succeed(visibility.requests.count - 1)

        items.alwaysHiddenItem?.length = 20
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: false)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 20)
        XCTAssertEqual(items.alwaysHiddenItem?.isVisible, false)
    }

    func testDisablingTheSectionRevealsItsApps() {
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: true)
        let hidingAlwaysHidden = visibility.succeed(visibility.requests.count - 1)

        engine.updateAlwaysHiddenSection(enabled: false, separatorHidden: true)
        XCTAssertTrue(hidingAlwaysHidden.isInvalidated)
    }

    func testIconlessRunningParentsAreNotKeptAndNewVisibleIconsAreKept() {
        inventory.noIconBundles = ["com.early"]
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: true)
        XCTAssertEqual(visibility.requests.last?.bundles, ["com.dwarvesv.minimalbar", "com.hidden", "com.visible"])
        visibility.succeed(visibility.requests.count - 1)

        inventory.items.append(item("com.late", x: 1500))
        let before = visibility.requests.count
        launches.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        XCTAssertEqual(visibility.requests.count, before + 1)
        XCTAssertEqual(visibility.requests.last?.bundles, ["com.dwarvesv.minimalbar", "com.hidden", "com.late", "com.visible"])
    }

    func testLaunchWithoutAnIconDoesNotChangeTargets() {
        let engine = makeEngine()
        engine.collapse { _ in }
        visibility.succeed(visibility.requests.count - 1)
        let before = visibility.requests.count
        launches.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        XCTAssertEqual(visibility.requests.count, before)
        XCTAssertEqual(engine.state, .collapsed)
    }

    func testExpandDuringActivationDropsTheLateResult() {
        let engine = makeEngine()
        var results: [CollapseResult] = []
        engine.collapse { results.append($0) }

        engine.expand()
        let late = visibility.succeed(0)

        XCTAssertTrue(late.isInvalidated, "a restriction nobody wants any more is released")
        XCTAssertEqual(engine.state, .expanded)
        XCTAssertEqual(results, [.cancelled])
    }

    func testDisplayChangeKeepsTheBarCollapsed() {
        let engine = makeEngine()
        engine.collapse { _ in }
        let collapsed = visibility.succeed(0)

        engine.invalidateLayout()
        XCTAssertEqual(engine.state, .collapsed)
        XCTAssertFalse(collapsed.isInvalidated)
    }

    func testCollapsedLaunchUsesLiveFrameAndRetriesUnmatchedRegistration() {
        let clock = ManualScheduler()
        let engine = makeEngine(schedule: clock.schedule)
        engine.collapse { _ in }
        visibility.succeed(0)
        inventory.items.append(item("com.new", x: 1200))
        launches.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        XCTAssertEqual(visibility.requests[1].hidden, ["com.always", "com.hidden", "com.new"])
        visibility.succeed(1, unmatched: ["com.new"])
        clock.fire()
        XCTAssertEqual(visibility.requests[2].hidden, visibility.requests[1].hidden)
        visibility.succeed(2)
        clock.fire()
        XCTAssertEqual(visibility.requests.count, 3, "matched targets do not cause repeated writes")
        XCTAssertEqual(engine.state, .collapsed)
    }

    func testLaunchDuringCalibrationRetriesPreviouslyUnreadableIcon() {
        let clock = ManualScheduler()
        inventory.unreadableBundles = ["com.late"]
        let engine = makeEngine(schedule: clock.schedule)
        engine.collapse { _ in }
        inventory.unreadableBundles = []
        inventory.items.append(item("com.late", x: 1200))
        launches.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        XCTAssertEqual(engine.state, .calibrating)
        visibility.succeed(0)
        clock.fire()
        XCTAssertEqual(engine.layout?.sections["com.late"], .hidden)
        XCTAssertEqual(visibility.requests.last?.hidden.contains("com.late"), true)
    }

    func testIconFirstReadWhileRestrictedCanSettleOnHiddenSide() {
        let clock = ManualScheduler()
        let engine = makeEngine(schedule: clock.schedule)
        engine.collapse { _ in }
        visibility.succeed(0)
        inventory.items.append(item("com.settling", x: 1400))
        clock.fire()
        visibility.succeed(1)
        inventory.items[inventory.items.count - 1] = item("com.settling", x: 1200)
        clock.fire()
        XCTAssertEqual(engine.layout?.sections["com.settling"], .hidden)
        XCTAssertEqual(visibility.requests.last?.hidden.contains("com.settling"), true)
    }

    func testHiddenIconReappearanceRetargetsEvenWhenTargetsAreUnchanged() {
        let clock = ManualScheduler()
        let engine = makeEngine(schedule: clock.schedule)
        engine.collapse { _ in }
        visibility.succeed(0)
        inventory.items.removeAll { $0.bundleIdentifier == "com.hidden" }
        inventory.noIconBundles = ["com.hidden"]
        clock.fire()
        XCTAssertEqual(visibility.requests.count, 1)
        inventory.noIconBundles = []
        inventory.items.append(item("com.hidden", x: 1200))
        clock.fire()
        XCTAssertEqual(visibility.requests.count, 2, "a new appearance can have a default-on entry")
    }

    func testEntryRegisteringAfterFivePollsStillGetsHidden() {
        let clock = ManualScheduler()
        let engine = makeEngine(schedule: clock.schedule)
        engine.collapse { _ in }
        visibility.succeed(0)
        inventory.items.append(item("com.lateEntry", x: 1200))
        for _ in 0..<9 {
            let before = visibility.requests.count
            clock.fire()
            if visibility.requests.count > before {
                visibility.succeed(visibility.requests.count - 1, unmatched: ["com.lateEntry"])
            }
        }
        let beforeRegistration = visibility.requests.count
        clock.fire()
        XCTAssertEqual(visibility.requests.count, beforeRegistration + 1,
                       "registration at nine seconds must not outlive the retry budget")
        if visibility.requests.count > beforeRegistration {
            visibility.succeed(visibility.requests.count - 1)
        }
        clock.fire()
        XCTAssertEqual(visibility.requests.count, beforeRegistration + 1)
    }

    func testEachIconAppearanceHasItsOwnRegistrationRetryBudget() {
        let clock = ManualScheduler()
        let engine = makeEngine(schedule: clock.schedule)
        engine.collapse { _ in }
        visibility.succeed(0, unmatched: ["com.hidden"])
        for _ in 0..<29 {
            let before = visibility.requests.count
            clock.fire()
            if visibility.requests.count > before {
                visibility.succeed(visibility.requests.count - 1, unmatched: ["com.hidden"])
            }
        }
        inventory.items.append(item("com.second", x: 1200))
        clock.fire()
        visibility.succeed(visibility.requests.count - 1, unmatched: ["com.hidden", "com.second"])
        for _ in 0..<8 {
            let before = visibility.requests.count
            clock.fire()
            XCTAssertEqual(visibility.requests.count, before + 1, "the later icon has its own budget")
            if visibility.requests.count > before {
                visibility.succeed(visibility.requests.count - 1, unmatched: ["com.second"])
            }
        }
    }

    func testNewIconInAlreadyRunningAppIsDiscoveredWithoutLaunchNotification() {
        let clock = ManualScheduler()
        let engine = makeEngine(schedule: clock.schedule)
        engine.collapse { _ in }
        visibility.succeed(0)
        inventory.noIconBundles = ["com.late"]
        clock.fire()
        XCTAssertEqual(visibility.requests.count, 1)
        inventory.noIconBundles = []
        inventory.items.append(item("com.late", x: 1200))
        clock.fire()
        XCTAssertTrue(visibility.requests[1].hidden.contains("com.late"))
    }

    func testCollapsedNewIconRightOfArrowIsNeverHidden() {
        let engine = makeEngine()
        engine.collapse { _ in }
        visibility.succeed(0)
        inventory.items.append(item("com.new", x: 1500))
        engine.applicationLaunched()
        XCTAssertFalse(visibility.requests[1].hidden.contains("com.new"))
        XCTAssertTrue(visibility.requests[1].bundles.contains("com.new"))
    }

    func testPartialRestrictionClassifiesNewIconAgainstLiveHiddenSection() {
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: true)
        visibility.succeed(0)
        inventory.items.append(item("com.newAlways", x: 1050))
        inventory.items.append(item("com.newHidden", x: 1200))
        inventory.items.append(item("com.newVisible", x: 1500))
        engine.applicationLaunched()
        XCTAssertEqual(visibility.requests[1].hidden, ["com.always", "com.newAlways"])
        XCTAssertTrue(visibility.requests[1].bundles.contains("com.newHidden"))
        XCTAssertTrue(visibility.requests[1].bundles.contains("com.newVisible"))
    }

    func testUnmatchedRetriesAreBoundedAndExpandCancelsDiscovery() {
        let clock = ManualScheduler()
        let engine = makeEngine(schedule: clock.schedule)
        engine.collapse { _ in }
        visibility.succeed(0, unmatched: ["com.hidden"])
        for index in 1...30 {
            clock.fire()
            XCTAssertEqual(visibility.requests.count, index + 1)
            if visibility.requests.count == index + 1 {
                visibility.succeed(index, unmatched: ["com.hidden"])
            }
        }
        clock.fire()
        XCTAssertEqual(visibility.requests.count, 31)
        engine.applicationLaunched()
        XCTAssertEqual(visibility.requests.count, 31, "an unrelated launch does not reset this appearance's budget")
        engine.expand()
        XCTAssertTrue(clock.pending.allSatisfy(\.isCancelled))
    }

    func testUnreadableAppKeepsSectionButIsNeverNewlyHidden() {
        let engine = makeEngine()
        engine.collapse { _ in }
        visibility.succeed(0)
        engine.expand()
        inventory.items.removeAll { $0.bundleIdentifier == "com.hidden" }
        inventory.unreadableBundles = ["com.hidden", "com.unknown"]
        engine.collapse { _ in }
        XCTAssertEqual(engine.layout?.sections["com.hidden"], .hidden)
        XCTAssertEqual(engine.layout?.sections["com.unknown"], .visible)
        XCTAssertFalse(visibility.requests[1].hidden.contains("com.hidden"))
        XCTAssertTrue(visibility.requests[1].bundles.contains("com.hidden"))
        XCTAssertTrue(visibility.requests[1].bundles.contains("com.unknown"))
        XCTAssertEqual(engine.layout?.isCached, true)
    }

    func testIconlessRunningAppIsNeitherHiddenNorKept() {
        inventory.noIconBundles = ["com.parent"]
        let engine = makeEngine()
        engine.collapse { _ in }
        XCTAssertFalse(visibility.requests[0].hidden.contains("com.parent"))
        XCTAssertFalse(visibility.requests[0].bundles.contains("com.parent"))
    }

    func testSheetReportsCachedSectionsAndNewIconsWhileCollapsed() {
        let engine = makeEngine()
        engine.collapse { _ in }
        visibility.succeed(0)
        inventory.items = [item("com.hidden", x: 1600), item("com.new", x: 1200)]
        var read: MenuBarLayout?
        engine.readSections { read = $0 }
        XCTAssertEqual(read?.isCached, true)
        XCTAssertEqual(read?.sections["com.hidden"], .hidden)
        XCTAssertEqual(read?.sections["com.new"], .hidden)
        XCTAssertEqual(visibility.requests.count, 1, "the sheet must not switch apps")
        XCTAssertNil(engine.layout?.sections["com.new"], "the sheet does not mutate engine state")
    }

    func testUnrestrictedSheetReportsFreshPositions() {
        let engine = makeEngine()
        var read: MenuBarLayout?
        engine.readSections { read = $0 }
        XCTAssertEqual(read?.isCached, false)
    }

    func testUnrestrictedSheetDoesNotCallUnknownUnreadableAppsCachedPositions() {
        let engine = makeEngine()
        inventory.unreadableBundles = ["com.iconlessHelper"]
        var read: MenuBarLayout?
        engine.readSections { read = $0 }
        XCTAssertEqual(read?.isCached, false, "no previously read positions were reused")
        engine.collapse { _ in }
        visibility.succeed(0)
        engine.expand()
        engine.readSections { read = $0 }
        XCTAssertEqual(read?.isCached, false, "fully expanded Refresh has fresh readable positions")
    }

    func testEveryConcurrentCollapseCallerCompletesOnce() {
        let engine = makeEngine()
        var first: [CollapseResult] = []
        var second: [CollapseResult] = []
        engine.collapse { first.append($0) }
        engine.collapse { second.append($0) }
        XCTAssertEqual(visibility.requests.count, 1)
        visibility.succeed(0)
        XCTAssertEqual(first, [.collapsed])
        XCTAssertEqual(second, [.collapsed])
    }

    func testExpandCancelsEveryCallerBeforeDelayedSnapshotReturns() {
        inventory.deferred = true
        let engine = makeEngine()
        var results: [CollapseResult] = []
        engine.collapse { results.append($0) }
        engine.collapse { results.append($0) }
        engine.expand()
        XCTAssertEqual(results, [.cancelled, .cancelled])
        inventory.deliver()
        XCTAssertTrue(visibility.requests.isEmpty)
        XCTAssertEqual(engine.state, .expanded)
    }

    func testFailedRestoreRemainsVisibleAsProblemAndNextExpandRetries() {
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: false)
        engine.collapse { _ in }
        let handle = visibility.succeed(0)
        handle.restoresSuccessfully = false
        engine.expand()
        XCTAssertEqual(engine.state, .unavailable)
        XCTAssertEqual(engine.unavailableReason, .restoreFailed)
        XCTAssertEqual(items.alwaysHiddenItem?.isVisible, false)
        handle.restoresSuccessfully = true
        engine.expand()
        XCTAssertEqual(handle.invalidations, 2)
        XCTAssertEqual(engine.state, .expanded)
        XCTAssertNil(engine.unavailableReason)
        XCTAssertEqual(items.alwaysHiddenItem?.isVisible, true)
    }

    func testFailedActivationRestorationIsReportedEvenWithoutHandle() {
        visibility.restoresSuccessfully = false
        let engine = makeEngine()
        engine.collapse { _ in }
        visibility.fail(0)
        XCTAssertEqual(engine.unavailableReason, .restoreFailed)
        XCTAssertEqual(engine.state, .unavailable)
        visibility.restoresSuccessfully = true
        engine.expand()
        XCTAssertEqual(visibility.restores, 2)
        XCTAssertEqual(engine.state, .expanded)
    }

    func testLateCancelledActivationRetainsFailedRestoreForRetry() {
        let engine = makeEngine()
        engine.collapse { _ in }
        engine.expand()
        let handle = FakeAssertion(allowed: [])
        handle.restoresSuccessfully = false
        visibility.requests[0].completion(.success(handle))
        XCTAssertEqual(engine.unavailableReason, .restoreFailed)
        XCTAssertEqual(engine.state, .unavailable)
        handle.restoresSuccessfully = true
        engine.expand()
        XCTAssertEqual(handle.invalidations, 2)
        XCTAssertEqual(engine.state, .expanded)
    }

    func testSeparatorReturnsOnlyAfterRestorationCompletes() {
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: false)
        engine.collapse { _ in }
        XCTAssertEqual(items.alwaysHiddenItem?.isVisible, false)
        let handle = visibility.succeed(0)
        XCTAssertTrue(engine.isAlwaysHiddenSeparatorPlaced, "right-click must work while the separator is absent")
        handle.onInvalidate = {
            XCTAssertEqual(self.items.alwaysHiddenItem?.isVisible, false)
        }
        engine.expand()
        XCTAssertEqual(items.alwaysHiddenItem?.isVisible, true)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 20)
    }

    func testFileAccessFailureIsDistinctAndGrantCanRetry() {
        visibility.isAvailable = false
        visibility.unavailableReason = .fileAccessNeeded
        let engine = makeEngine()
        engine.collapse { _ in }
        XCTAssertEqual(engine.unavailableReason, .fileAccessNeeded)
        engine.requestAccess()
        XCTAssertEqual(visibility.accessRequests, 1)
        visibility.isAvailable = true
        engine.collapse { _ in }
        visibility.succeed(0)
        XCTAssertNil(engine.unavailableReason)
    }
}

// MARK: - Legacy engine

final class LegacyLengthEngineTests: XCTestCase {
    func testCollapseAndExpandFlipSeparatorLength() {
        let items = FakeItems()
        let engine = LegacyLengthEngine(items: items)
        XCTAssertEqual(engine.state, .expanded)

        var result: CollapseResult?
        engine.collapse { result = $0 }
        XCTAssertEqual(result, .collapsed)
        XCTAssertEqual(engine.state, .collapsed)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 20, "collapse leaves the always-hidden item alone")

        engine.expand()
        XCTAssertEqual(engine.state, .expanded)
        XCTAssertEqual(items.separatorItem.length, 20)
    }

    // A display change re-sizes the always-hidden item while it is inflated,
    // even with the bar expanded, and leaves it alone otherwise.
    func testDisplayChangeResizesInflatedAlwaysHiddenItem() {
        let items = FakeItems()
        let engine = LegacyLengthEngine(items: items)
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: true)
        let inflated = items.alwaysHiddenItem?.length ?? 0
        XCTAssertGreaterThan(inflated, 20)

        items.alwaysHiddenItem?.length = 300
        engine.invalidateLayout()
        XCTAssertEqual(items.alwaysHiddenItem?.length, inflated)
        XCTAssertEqual(engine.state, .expanded)

        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: false)
        engine.invalidateLayout()
        XCTAssertEqual(items.alwaysHiddenItem?.length, 20)
    }
}

// MARK: - Sections chosen in Settings (no ⌘-drag)

final class SectionOverrideTests: XCTestCase {
    private var items: FakeItems!
    private var inventory: FakeInventory!
    private var visibility: FakeVisibility!
    private var overrides: [String: MenuBarSection] = [:]
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        items = FakeItems()
        inventory = FakeInventory()
        inventory.items = [item("com.always", x: 900), item("com.hidden", x: 1100), item("com.visible", x: 1400)]
        visibility = FakeVisibility()
        overrides = [:]
        defaults = isolatedDefaults(self)
    }

    private func makeEngine() -> NativeVisibilityEngine {
        let items = self.items!
        return NativeVisibilityEngine(items: items, inventory: inventory, visibility: visibility,
                                      ownBundleIdentifier: "com.dwarvesv.minimalbar",
                                      itemFrame: { $0 === items.toggleItem ? separator : alwaysHiddenSeparator },
                                      isLTR: { true },
                                      launchNotifications: NotificationCenter(),
                                      sectionOverrides: { [unowned self] in self.overrides },
                                      defaults: defaults,
                                      schedule: { _, body in DispatchWorkItem(block: body) })
    }

    func testOverridesWinOverPositions() {
        let layout = MenuBarLayout(sections: ["com.a": .visible, "com.b": .hidden])
        let applied = layout.applying(overrides: ["com.a": .hidden, "com.b": .visible, "com.new": .alwaysHidden], alwaysHiddenEnabled: true)
        XCTAssertEqual(applied.sections, ["com.a": .hidden, "com.b": .visible, "com.new": .alwaysHidden])
    }

    func testSheetOverrideUpdatesRememberedMembershipWhileExpanded() {
        let engine = makeEngine()
        engine.readSections { _ in }
        overrides = ["com.visible": .hidden]
        engine.reapplySections { XCTAssertTrue($0) }
        XCTAssertEqual((defaults.dictionary(forKey: "rememberedSections") as? [String: Int])?["com.visible"],
                       MenuBarSection.hidden.rawValue)
        engine.readSections { XCTAssertEqual($0?.sections["com.visible"], .hidden) }
        overrides = [:]
        engine.readSections { XCTAssertEqual($0?.sections["com.visible"], .hidden) }
        XCTAssertTrue(visibility.requests.isEmpty)
    }

    func testSheetOverrideUpdatesMembershipDuringRestrictedDiscovery() {
        let scheduler = ManualScheduler()
        let items = self.items!
        let engine = NativeVisibilityEngine(items: items, inventory: inventory, visibility: visibility,
                                           ownBundleIdentifier: "com.dwarvesv.minimalbar",
                                           itemFrame: { $0 === items.toggleItem ? separator : alwaysHiddenSeparator },
                                           isLTR: { true }, launchNotifications: NotificationCenter(),
                                           sectionOverrides: { [unowned self] in self.overrides },
                                           defaults: defaults, schedule: scheduler.schedule)
        engine.collapse { _ in }
        visibility.succeed(0)
        overrides = ["com.visible": .hidden]
        engine.reapplySections { _ in }
        visibility.succeed(1)
        scheduler.fire()
        XCTAssertEqual(visibility.requests.count, 2)
        XCTAssertEqual((defaults.dictionary(forKey: "rememberedSections") as? [String: Int])?["com.visible"],
                       MenuBarSection.hidden.rawValue)
    }

    func testAlwaysHiddenChoiceHidesWhenTheSectionIsOff() {
        let layout = MenuBarLayout(sections: ["com.a": .visible])
        let applied = layout.applying(overrides: ["com.a": .alwaysHidden], alwaysHiddenEnabled: false)
        XCTAssertEqual(applied.sections, ["com.a": .hidden])
    }

    func testCollapseHidesAnAppChosenAsHiddenAndShowsOneChosenAsShown() {
        overrides = ["com.visible": .hidden, "com.hidden": .visible]
        let engine = makeEngine()
        engine.collapse { _ in }
        XCTAssertEqual(visibility.requests.last?.bundles, ["com.dwarvesv.minimalbar", "com.hidden"])
    }

    func testChangingAChoiceWhileCollapsedSwapsTheRestriction() {
        let engine = makeEngine()
        engine.collapse { _ in }
        let first = visibility.succeed(0)
        XCTAssertEqual(visibility.requests[0].bundles, ["com.dwarvesv.minimalbar", "com.visible"])

        overrides = ["com.visible": .hidden]
        var reapplied: Bool?
        engine.reapplySections { reapplied = $0 }
        XCTAssertEqual(visibility.requests.count, 2)
        XCTAssertEqual(visibility.requests[1].bundles, ["com.dwarvesv.minimalbar"])
        XCTAssertFalse(first.isInvalidated, "the old restriction stays until the new one is active")
        visibility.succeed(1)
        XCTAssertTrue(first.isInvalidated)
        XCTAssertEqual(reapplied, true)
        XCTAssertEqual(engine.state, .collapsed)
    }

    func testFailedReapplyShowsEverything() {
        let engine = makeEngine()
        engine.collapse { _ in }
        visibility.succeed(0)
        overrides = ["com.visible": .hidden]
        var reapplied: Bool?
        engine.reapplySections { reapplied = $0 }
        visibility.fail(1)
        XCTAssertEqual(reapplied, false)
        XCTAssertEqual(engine.state, .expanded)
    }

    // An app chosen as always hidden but not read from the bar (launched while
    // collapsed) must not be shown as "unseen" while expanded.
    func testExpandedKeepsAChosenAlwaysHiddenAppHiddenEvenIfUnread() {
        overrides = ["com.late": .alwaysHidden]
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: true)
        XCTAssertEqual(visibility.requests.last?.bundles, ["com.dwarvesv.minimalbar", "com.hidden", "com.visible"])
    }

    func testReadSectionsReportsEffectiveChoices() {
        overrides = ["com.visible": .hidden]
        let engine = makeEngine()
        var read: MenuBarLayout?
        engine.readSections { read = $0 }
        XCTAssertEqual(read?.sections, ["com.always": .hidden, "com.hidden": .hidden, "com.visible": .hidden])
        XCTAssertTrue(visibility.requests.isEmpty, "reading for Settings never changes what is hidden")
    }

    func testHiddenOverrideNeverSwitchesOffAnIconlessApp() {
        overrides = ["com.iconless": .hidden]
        inventory.noIconBundles = ["com.iconless"]
        let engine = makeEngine()
        engine.collapse { _ in }
        XCTAssertFalse(visibility.requests[0].hidden.contains("com.iconless"))
    }

    func testChangingOverrideDoesNotHideAnAppWhoseIconDisappeared() {
        let engine = makeEngine()
        engine.collapse { _ in }
        visibility.succeed(0)
        inventory.items.removeAll { $0.bundleIdentifier == "com.visible" }
        inventory.noIconBundles = ["com.visible"]
        overrides = ["com.visible": .hidden]
        engine.reapplySections { _ in }
        XCTAssertFalse(visibility.requests[1].hidden.contains("com.visible"))
    }
}

// MARK: - Why hiding does not work (shown to the user)

final class UnavailableReasonTests: XCTestCase {
    private func makeEngine(inventory: FakeInventory, visibility: FakeVisibility) -> NativeVisibilityEngine {
        let items = FakeItems()
        return NativeVisibilityEngine(items: items, inventory: inventory, visibility: visibility,
                                      ownBundleIdentifier: "com.dwarvesv.minimalbar",
                                      itemFrame: { $0 === items.toggleItem ? separator : alwaysHiddenSeparator },
                                      isLTR: { true },
                                      launchNotifications: NotificationCenter(),
                                      defaults: isolatedDefaults(self),
                                      schedule: { _, body in DispatchWorkItem(block: body) })
    }

    func testEachFailureHasItsOwnReasonAndSuccessClearsIt() {
        let inventory = FakeInventory()
        inventory.items = [item("com.visible", x: 1400)]
        let visibility = FakeVisibility()

        visibility.isAvailable = false
        let unsupported = makeEngine(inventory: inventory, visibility: visibility)
        unsupported.collapse { _ in }
        XCTAssertEqual(unsupported.unavailableReason, .notSupported)

        visibility.isAvailable = true
        inventory.isAuthorized = false
        let engine = makeEngine(inventory: inventory, visibility: visibility)
        engine.collapse { _ in }
        XCTAssertEqual(engine.unavailableReason, .accessibilityNeeded)

        inventory.isAuthorized = true
        engine.collapse { _ in }
        visibility.fail(0)
        XCTAssertEqual(engine.unavailableReason, .activationFailed)

        engine.collapse { _ in }
        visibility.succeed(1)
        XCTAssertNil(engine.unavailableReason, "a collapse that works clears the message")
    }
}

// MARK: - macOS 27 overflow collapse

final class OverflowCollapseGeometryTests: XCTestCase {
    func testPlainDisplayStaysUnderHalfItsWidthAndSpansIt() {
        let plan = OverflowCollapseGeometry.plan(displays: [.init(width: 1920)])
        XCTAssertEqual(plan.unitLength, 896)
        XCTAssertGreaterThanOrEqual(plan.unitLength * CGFloat(plan.activeSpacers + 1), 1920)
    }

    func testNotchedDisplayUsesTheAreaRightOfTheNotch() {
        let plan = OverflowCollapseGeometry.plan(displays: [.init(width: 1512, statusWidth: 663.5)])
        XCTAssertLessThan(plan.unitLength, 515, "535 pt is discarded on this display")
        XCTAssertGreaterThanOrEqual(plan.unitLength * CGFloat(plan.activeSpacers + 1), 663.5)
    }

    func testMixedDisplaysUseTheNarrowestLimitAndTheWidestArea() {
        let plan = OverflowCollapseGeometry.plan(displays: [.init(width: 1280), .init(width: 6016)])
        XCTAssertEqual(plan.unitLength, 576)
        XCTAssertGreaterThanOrEqual(plan.unitLength * CGFloat(plan.activeSpacers + 1), 6016)
        XCTAssertLessThanOrEqual(plan.activeSpacers, OverflowCollapseGeometry.spacerCount)
    }

    func testNoDisplayFallsBack() {
        XCTAssertEqual(OverflowCollapseGeometry.plan(displays: []), .init(unitLength: 200, activeSpacers: 0))
    }
}

final class OverflowCollapseEngineTests: XCTestCase {
    private let bar = NSStatusBar()
    private var spacers: [String: NSStatusItem] = [:]

    private func makeEngine(_ items: FakeItems) -> OverflowCollapseEngine {
        return OverflowCollapseEngine(items: items,
                                      displays: { [.init(width: 1920)] },
                                      makeSpacer: { [unowned self] name in
                                          let spacer = self.bar.statusItem(withLength: 0)
                                          self.spacers[name] = spacer
                                          return spacer
                                      })
    }

    private var spacerLengths: [CGFloat] {
        return (0..<OverflowCollapseGeometry.spacerCount).map { spacers[OverflowCollapseEngine.spacerAutosaveName($0)]!.length }
    }

    func testRegistersEverySpacerOnce() {
        _ = makeEngine(FakeItems())
        XCTAssertEqual(spacers.count, OverflowCollapseGeometry.spacerCount)
        XCTAssertEqual(Set(spacerLengths), [0])
    }

    func testCollapseInflatesTheSeparatorUnderTheLimitAndExpandRestoresIt() {
        let items = FakeItems()
        let engine = makeEngine(items)
        XCTAssertTrue(items.separatorItem.isVisible, "the separator is the boundary, so it stays in the bar")

        var result: CollapseResult?
        engine.collapse { result = $0 }
        XCTAssertEqual(result, .collapsed)
        XCTAssertEqual(engine.state, .collapsed)
        XCTAssertEqual(items.separatorItem.length, 896)
        XCTAssertEqual(spacerLengths.filter { $0 == 896 }.count, 2)

        engine.expand()
        XCTAssertEqual(engine.state, .expanded)
        XCTAssertEqual(items.separatorItem.length, 20)
        XCTAssertEqual(Set(spacerLengths), [0])
    }

    func testExpandedWithSeparatorsHiddenInflatesOnlyTheAlwaysHiddenSeparator() {
        let items = FakeItems()
        let engine = makeEngine(items)
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: true)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 896)
        XCTAssertEqual(items.separatorItem.length, 20)
        XCTAssertEqual(spacerLengths.filter { $0 == 896 }.count, 2)

        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: false)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 20)
        XCTAssertEqual(Set(spacerLengths), [0])

        engine.updateAlwaysHiddenSection(enabled: false, separatorHidden: false)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 0)
    }

    func testCollapsedInflatesTheRegularSeparatorEvenWithSeparatorsHidden() {
        let items = FakeItems()
        let engine = makeEngine(items)
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: true)
        engine.collapse { _ in }
        XCTAssertEqual(items.separatorItem.length, 896)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 20)
    }
}

// MARK: - Allow in the Menu Bar entries

final class AllowListTests: XCTestCase {
    private func apply(hiding hidden: Set<String>, keeping kept: Set<String>, to entries: NSMutableArray,
                       saved: inout AllowList.Journal) -> Bool {
        var overrides = Set<String>()
        return AllowList.apply(hiding: hidden, keeping: kept, to: entries, journal: &saved,
                               userOverrides: &overrides, executableURL: { _ in nil }).changed
    }

    private func entry(_ key: String, locations: [NSDictionary], allowed: Bool = true) -> [Any] {
        return [["bundle": ["_0": key]] as NSDictionary,
                NSMutableDictionary(dictionary: ["location": ["bundle": ["_0": key]],
                                                 "menuItemLocations": NSMutableArray(array: locations),
                                                 "isAllowed": allowed])]
    }

    private func bundle(_ id: String) -> NSDictionary { ["bundle": ["_0": id]] }
    private func path(_ url: String) -> NSDictionary { ["adhocBinary": ["_0": ["relative": url]]] }

    private func value(_ entries: NSMutableArray, _ key: String) -> NSMutableDictionary {
        var i = 0
        while i + 1 < entries.count {
            if (((entries[i] as? NSDictionary)?["bundle"] as? NSDictionary)?["_0"] as? String) == key {
                return entries[i + 1] as! NSMutableDictionary
            }
            i += 2
        }
        fatalError("no entry \(key)")
    }

    func testHidesMatchingEntriesAndRestoresThem() {
        let entries = NSMutableArray(array: entry("a.app", locations: [bundle("a.app")]) + entry("b.app", locations: [bundle("b.app")]))
        var saved: AllowList.Journal = [:]
        XCTAssertTrue(apply(hiding: ["a.app"], keeping: [], to: entries, saved: &saved))
        XCTAssertEqual(value(entries, "a.app")["isAllowed"] as? Bool, false)
        XCTAssertEqual(value(entries, "b.app")["isAllowed"] as? Bool, true)
        XCTAssertEqual(saved, [AllowList.identity(bundle("a.app"))!: AllowList.Record(original: true, written: false)])

        XCTAssertTrue(apply(hiding: [], keeping: [], to: entries, saved: &saved))
        XCTAssertEqual(value(entries, "a.app")["isAllowed"] as? Bool, true)
        XCTAssertEqual(saved, [:])
    }

    func testEntryWithOnlyAnOldBuildPathGetsTheBundleIdAdded() {
        let old = path("file:///Users/x/.work/build/S.app/Contents/MacOS/S")
        let entries = NSMutableArray(array: entry("local.s.app", locations: [old]))
        var saved: AllowList.Journal = [:]
        XCTAssertTrue(apply(hiding: ["local.s.app"], keeping: [], to: entries, saved: &saved))
        let v = value(entries, "local.s.app")
        XCTAssertEqual(v["isAllowed"] as? Bool, false)
        XCTAssertEqual(AllowList.bundles(in: v["menuItemLocations"] as? NSArray), ["local.s.app"])
        XCTAssertEqual((v["menuItemLocations"] as? NSArray)?.count, 2, "the old location is kept")
    }

    func testHelperIsMatchedThroughItsParentsEntry() {
        let entries = NSMutableArray(array: entry("com.parent", locations: [bundle("team.helper"), bundle("com.parent")]))
        var saved: AllowList.Journal = [:]
        _ = apply(hiding: ["team.helper"], keeping: [], to: entries, saved: &saved)
        XCTAssertEqual(value(entries, "com.parent")["isAllowed"] as? Bool, false)
        XCTAssertEqual((value(entries, "com.parent")["menuItemLocations"] as? NSArray)?.count, 2, "nothing added")
    }

    func testEntryListingAVisibleHelperStaysOn() {
        // iStat Menus: the main app runs without an icon (so it is not kept), its
        // helper draws the icon and sits right of the arrow.
        let entries = NSMutableArray(array: entry("com.parent", locations: [bundle("team.helper"), bundle("com.parent")]))
        var saved: AllowList.Journal = [:]
        XCTAssertFalse(apply(hiding: ["com.parent"], keeping: ["team.helper"], to: entries, saved: &saved))
        XCTAssertEqual(value(entries, "com.parent")["isAllowed"] as? Bool, true)
    }

    func testAUserSwitchedOffAppStaysOffAfterRestore() {
        let entries = NSMutableArray(array: entry("a.app", locations: [bundle("a.app")], allowed: false))
        var saved: AllowList.Journal = [:]
        _ = apply(hiding: ["a.app"], keeping: [], to: entries, saved: &saved)
        XCTAssertEqual(saved, [AllowList.identity(bundle("a.app"))!: AllowList.Record(original: false, written: false)])
        _ = apply(hiding: [], keeping: [], to: entries, saved: &saved)
        XCTAssertEqual(value(entries, "a.app")["isAllowed"] as? Bool, false)
    }

    func testNothingToChangeReportsNoChange() {
        let entries = NSMutableArray(array: entry("a.app", locations: [bundle("a.app")]))
        var saved: AllowList.Journal = [:]
        XCTAssertFalse(apply(hiding: ["not.running"], keeping: [], to: entries, saved: &saved))
    }
}

final class MenuBarAllowListBridgeTests: XCTestCase {
    private final class Store {
        var entries: NSMutableArray
        var reads = 0
        var writes = 0
        var failWrites = false
        var ignoreWrites = false
        var beforeRead: ((Int) -> Void)?
        var beforeWrite: (() -> Void)?

        init(_ entries: NSMutableArray) { self.entries = entries }

        func read() throws -> NSMutableArray {
            reads += 1
            beforeRead?(reads)
            return try copy(entries)
        }

        func write(_ value: NSMutableArray) throws {
            writes += 1
            beforeWrite?()
            if !ignoreWrites { entries = try copy(value) }
            // Synchronization can fail after CFPreferencesSetValue has applied.
            if failWrites { throw NSError(domain: "TestStore", code: 1) }
        }

        private func copy(_ value: NSMutableArray) throws -> NSMutableArray {
            let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
            return try XCTUnwrap(PropertyListSerialization.propertyList(
                from: data, options: .mutableContainersAndLeaves, format: nil) as? NSMutableArray)
        }
    }

    private var defaults: UserDefaults!
    private var suite: String!
    private let journalKey = "allowInMenuBarJournal"
    private let pendingKey = "allowInMenuBarPending"

    override func setUp() {
        super.setUp()
        suite = "HiddenBarTests.AllowList.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    private func bundle(_ id: String) -> NSDictionary { ["bundle": ["_0": id]] }
    private func path(_ name: String) -> NSDictionary {
        ["adhocBinary": ["_0": ["relative": "file:///Applications/\(name).app/Contents/MacOS/\(name)"]]]
    }

    private func entries(_ ids: [String]) -> NSMutableArray {
        let result = NSMutableArray()
        for id in ids {
            result.add(bundle(id))
            result.add(NSMutableDictionary(dictionary: ["isAllowed": true,
                                                       "menuItemLocations": NSMutableArray(object: bundle(id))]))
        }
        return result
    }

    private func value(_ store: Store, _ index: Int = 0) -> NSMutableDictionary {
        store.entries[index * 2 + 1] as! NSMutableDictionary
    }

    private func journal() throws -> AllowList.Journal {
        guard let data = defaults.data(forKey: journalKey) else { return [:] }
        return try PropertyListDecoder().decode(AllowList.Journal.self, from: data)
    }

    private func bridge(_ store: Store, running: Set<String> = ["a"],
                        synchronize: (() -> Bool)? = nil,
                        diagnostics: @escaping (MenuBarAllowListBridge.Diagnostic) -> Void = { _ in }) -> MenuBarAllowListBridge {
        MenuBarAllowListBridge(defaults: defaults, runningBundleIdentifiers: { running },
                              executableURL: { URL(string: "file:///Applications/\($0).app/Contents/MacOS/\($0)") },
                              readEntries: { try store.read() }, writeEntries: { try store.write($0) },
                              synchronizeJournal: synchronize, diagnostic: diagnostics)
    }

    private func activate(_ bridge: MenuBarAllowListBridge, keeping: [String] = []) throws -> NativeVisibilityAssertion {
        var result: Result<NativeVisibilityAssertion, Error>?
        bridge.activate(allowedSystemItems: [], allowedBundleIdentifiers: keeping) { result = $0 }
        return try XCTUnwrap(result).get()
    }

    func testExplicitTargetsLeaveIconlessRunningEntriesUntouched() throws {
        let store = Store(entries(["a", "iconless", "unreadable"]))
        let bridge = bridge(store, running: ["a", "iconless", "unreadable"])
        var result: Result<NativeVisibilityAssertion, Error>?
        bridge.activate(allowedSystemItems: [], allowedBundleIdentifiers: ["unreadable"],
                        hiddenBundleIdentifiers: ["a"]) { result = $0 }
        let handle = try XCTUnwrap(result).get()
        XCTAssertEqual(value(store, 0)["isAllowed"] as? Bool, false)
        XCTAssertEqual(value(store, 1)["isAllowed"] as? Bool, true)
        XCTAssertEqual(value(store, 2)["isAllowed"] as? Bool, true)
        XCTAssertTrue(handle.invalidate())
    }

    func testIconlessParentDoesNotProtectHiddenHelperEntry() throws {
        let store = Store(entries(["parent"]))
        value(store)["menuItemLocations"] = NSMutableArray(array: [bundle("parent"), bundle("helper")])
        let bridge = bridge(store, running: ["parent", "helper"])
        var result: Result<NativeVisibilityAssertion, Error>?
        bridge.activate(allowedSystemItems: [], allowedBundleIdentifiers: [],
                        hiddenBundleIdentifiers: ["helper"]) { result = $0 }
        let handle = try XCTUnwrap(result).get()
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, false)
        XCTAssertTrue(handle.invalidate())
    }

    func testGrantAccessResetsCancelledPromptLatch() {
        var prompts = 0
        var readable = false
        let bridge = MenuBarAllowListBridge(defaults: defaults,
            readEntries: {
                if !readable { throw NSError(domain: "TestAccess", code: 1) }
                return NSMutableArray()
            },
            accessPrompt: {
                prompts += 1
                if prompts == 2 { readable = true }
                return readable
            })
        XCTAssertFalse(bridge.isAvailable)
        XCTAssertFalse(bridge.isAvailable)
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(bridge.unavailableReason, .fileAccessNeeded)
        bridge.requestAccess()
        XCTAssertEqual(prompts, 2)
        XCTAssertTrue(bridge.isAvailable)
    }

    func testJournalIsDurableAndPendingBeforeSwitchWrite() throws {
        let store = Store(entries(["a"]))
        let bridge = bridge(store)
        var persisted = false
        store.beforeWrite = {
            let durable = UserDefaults(suiteName: self.suite)!
            persisted = durable.bool(forKey: self.pendingKey)
                && durable.data(forKey: self.journalKey) != nil
            XCTAssertEqual(try? self.journal().values.first?.original, true)
        }
        let handle = try activate(bridge)
        XCTAssertTrue(persisted)
        XCTAssertFalse(defaults.bool(forKey: pendingKey))
        XCTAssertFalse(try journal().isEmpty)
        XCTAssertTrue(handle.invalidate())
    }

    func testSuccessfulQuitAndExpandRestoresRemoveDurableRecoveryKeys() throws {
        let store = Store(entries(["a"]))
        var clearedAtSynchronization = false
        let bridge = bridge(store, synchronize: {
            let keys = [self.journalKey, self.pendingKey, "allowInMenuBarSavedValues"]
            if keys.allSatisfy({ self.defaults.object(forKey: $0) == nil }) {
                clearedAtSynchronization = true
                XCTAssertEqual(self.value(store)["isAllowed"] as? Bool, true)
            }
            return self.defaults.synchronize()
        })
        for restoringThroughHandle in [false, true] {
            clearedAtSynchronization = false
            let handle = try activate(bridge)
            XCTAssertEqual(value(store)["isAllowed"] as? Bool, false)
            XCTAssertTrue(restoringThroughHandle ? handle.invalidate() : bridge.restoreAll())
            XCTAssertTrue(clearedAtSynchronization, "cleanup must be synchronized before restore returns")
            let durable = UserDefaults(suiteName: suite)!
            for key in [journalKey, pendingKey, "allowInMenuBarSavedValues"] {
                XCTAssertNil(durable.object(forKey: key), key)
            }
        }
    }

    func testJournalSynchronizationFailureNeverWritesSwitches() {
        let store = Store(entries(["a"]))
        let bridge = bridge(store, synchronize: { false })
        XCTAssertThrowsError(try activate(bridge))
        XCTAssertEqual(store.writes, 0)
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, true)
        XCTAssertFalse((try? journal().isEmpty) ?? true)
        XCTAssertTrue(defaults.bool(forKey: pendingKey))
    }

    func testFailedSwitchWriteKeepsRecoveryAcrossRelaunch() throws {
        let store = Store(entries(["a"]))
        store.failWrites = true
        XCTAssertThrowsError(try activate(bridge(store)))
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, false)
        XCTAssertTrue(defaults.bool(forKey: pendingKey))
        store.failWrites = false
        bridge(store).restoreAfterUnexpectedExit()
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, true)
        XCTAssertTrue(try journal().isEmpty)
        XCTAssertFalse(defaults.bool(forKey: pendingKey))
    }

    func testPendingWithoutJournalStillRunsLaunchRecovery() {
        let store = Store(entries(["a"]))
        defaults.set(true, forKey: pendingKey)
        bridge(store).restoreAfterUnexpectedExit()
        XCTAssertFalse(defaults.bool(forKey: pendingKey))
        XCTAssertEqual(store.writes, 0)
        XCTAssertGreaterThanOrEqual(store.reads, 3)
    }

    func testFailedRestoreRetainsHandleForRetry() throws {
        let store = Store(entries(["a"]))
        let bridge = bridge(store)
        let handle = try activate(bridge)
        store.failWrites = true
        XCTAssertFalse(handle.invalidate())
        XCTAssertFalse(try journal().isEmpty)
        // Model a failed synchronization that did not reach the external store.
        value(store)["isAllowed"] = false
        store.failWrites = false
        XCTAssertTrue(handle.invalidate())
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, true)
        XCTAssertTrue(try journal().isEmpty)
        XCTAssertTrue(handle.invalidate())
    }

    func testCompletionJournalFailureKeepsPendingRecovery() throws {
        let store = Store(entries(["a"]))
        var synchronizations = 0
        let bridge = bridge(store, synchronize: {
            synchronizations += 1
            return synchronizations != 6
        })
        let handle = try activate(bridge)
        XCTAssertFalse(handle.invalidate())
        XCTAssertTrue(defaults.bool(forKey: pendingKey))
        XCTAssertFalse(try journal().isEmpty)
        XCTAssertTrue(handle.invalidate())
        XCTAssertTrue(try journal().isEmpty)
    }

    func testSupersededHandleCannotRestoreNewActivation() throws {
        let store = Store(entries(["a"]))
        let bridge = bridge(store)
        let first = try activate(bridge)
        let second = try activate(bridge)
        XCTAssertTrue(first.invalidate())
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, false)
        XCTAssertTrue(second.invalidate())
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, true)
    }

    func testMissingEntryRemainsJournaledUntilLaterRestore() throws {
        let store = Store(entries(["a", "b"]))
        let bridge = bridge(store, running: ["a", "b"])
        let handle = try activate(bridge)
        let bKey = store.entries[2]
        let bValue = store.entries[3]
        store.entries.removeObjects(in: NSRange(location: 2, length: 2))
        XCTAssertFalse(handle.invalidate())
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, true)
        XCTAssertEqual(try journal().count, 1)
        store.entries.add(bKey)
        store.entries.add(bValue)
        XCTAssertTrue(handle.invalidate())
        XCTAssertEqual(value(store, 1)["isAllowed"] as? Bool, true)
        XCTAssertTrue(try journal().isEmpty)
    }

    func testLaterActivationRetriesUnresolvedRestoration() throws {
        let store = Store(entries(["a", "b"]))
        let bridge = bridge(store, running: ["a", "b"])
        let handle = try activate(bridge)
        let key = store.entries[2]
        let item = store.entries[3]
        store.entries.removeObjects(in: NSRange(location: 2, length: 2))
        XCTAssertFalse(handle.invalidate())
        store.entries.add(key)
        store.entries.add(item)
        let next = try activate(bridge, keeping: ["a", "b"])
        XCTAssertTrue(try journal().isEmpty)
        XCTAssertEqual(value(store, 1)["isAllowed"] as? Bool, true)
        XCTAssertTrue(next.invalidate())
    }

    func testRestoreRemovesOnlyLocationsAddedByHiddenBar() throws {
        let store = Store(entries(["a"]))
        let original = path("Old")
        value(store)["menuItemLocations"] = NSMutableArray(object: original)
        let bridge = bridge(store)
        let handle = try activate(bridge)
        XCTAssertEqual(try journal().values.first?.addedLocations, ["a"])
        let agentLocation = bundle("agent.helper")
        (value(store)["menuItemLocations"] as! NSMutableArray).add(agentLocation)
        XCTAssertTrue(handle.invalidate())
        XCTAssertEqual(value(store)["menuItemLocations"] as? NSArray, NSArray(array: [original, agentLocation]))
    }

    func testRestorePreservesOriginallyAbsentLocationsField() throws {
        let store = Store(entries(["a"]))
        value(store).removeObject(forKey: "menuItemLocations")
        let original = try store.read()
        let bridge = bridge(store)
        let handle = try activate(bridge)
        XCTAssertTrue(handle.invalidate())
        XCTAssertEqual(store.entries, original)
    }

    func testUserChangedSwitchSurvivesRestore() throws {
        let store = Store(entries(["a"]))
        value(store)["isAllowed"] = false
        let bridge = bridge(store)
        let handle = try activate(bridge)
        value(store)["isAllowed"] = true
        XCTAssertTrue(handle.invalidate())
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, true)
        XCTAssertTrue(try journal().isEmpty)
    }

    func testReconcileDropsUserOverrideUntilNextCollapse() throws {
        let store = Store(entries(["a"]))
        let bridge = bridge(store)
        let first = try activate(bridge)
        value(store)["isAllowed"] = true
        let second = try activate(bridge)
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, true)
        XCTAssertTrue(try journal().isEmpty)
        // Once the external change has been observed, a later off choice also
        // belongs to the user rather than to the old recovery record.
        value(store)["isAllowed"] = false
        XCTAssertTrue(first.invalidate())
        XCTAssertTrue(second.invalidate())
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, false)
        value(store)["isAllowed"] = true
        let third = try activate(bridge)
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, false)
        XCTAssertTrue(third.invalidate())
    }

    func testAdhocKeyAndExecutableLocationHideAndRecover() throws {
        let store = Store(entries(["a"]))
        store.entries[0] = path("a")
        value(store)["menuItemLocations"] = NSMutableArray(object: path("a"))
        let original = try store.read()
        let bridge = bridge(store)
        let handle = try activate(bridge)
        XCTAssertTrue(handle.unmatchedHiddenBundleIdentifiers.isEmpty)
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, false)
        XCTAssertNotNil(try journal()[XCTUnwrap(AllowList.identity(path("a")))])
        XCTAssertTrue(handle.invalidate())
        XCTAssertEqual(store.entries, original)
    }

    func testAdhocKeyWithBundleLocationIsNotSkipped() throws {
        let store = Store(entries(["a"]))
        store.entries[0] = path("Old")
        let bridge = bridge(store)
        let handle = try activate(bridge)
        XCTAssertTrue(handle.unmatchedHiddenBundleIdentifiers.isEmpty)
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, false)
        XCTAssertTrue(handle.invalidate())
    }

    func testFullKeyIdentityIsStableAndDistinguishesPaths() throws {
        let a = NSDictionary(dictionary: ["adhocBinary": ["_0": ["relative": "file:///a", "base": "x"]], "version": 1])
        let reordered = NSDictionary(dictionary: ["version": 1, "adhocBinary": ["_0": ["base": "x", "relative": "file:///a"]]])
        XCTAssertEqual(try XCTUnwrap(AllowList.identity(a)), try XCTUnwrap(AllowList.identity(reordered)))
        XCTAssertNotEqual(AllowList.identity(path("a")), AllowList.identity(path("b")))
        XCTAssertNotEqual(AllowList.identity(a), AllowList.identity(["adhocBinary": ["_0": ["relative": "file:///a"]]]))
    }

    func testUnmatchedHiddenBundlesAreReturnedAndLogged() throws {
        let store = Store(entries(["a"]))
        var diagnostics: [MenuBarAllowListBridge.Diagnostic] = []
        let bridge = bridge(store, running: ["a", "missing"], diagnostics: { diagnostics.append($0) })
        let handle = try activate(bridge)
        XCTAssertEqual(handle.unmatchedHiddenBundleIdentifiers, ["missing"])
        XCTAssertTrue(diagnostics.contains(.unmatched(["missing"])))
        XCTAssertTrue(handle.invalidate())
    }

    func testPostWriteReadDetectsAndLogsMismatch() {
        let store = Store(entries(["a"]))
        store.ignoreWrites = true
        var diagnostics: [MenuBarAllowListBridge.Diagnostic] = []
        let bridge = bridge(store, diagnostics: { diagnostics.append($0) })
        XCTAssertThrowsError(try activate(bridge))
        XCTAssertTrue(diagnostics.contains(.writeMismatch))
        XCTAssertTrue(defaults.bool(forKey: pendingKey))
        XCTAssertFalse((try? journal().isEmpty) ?? true)
    }

    func testLaunchAuditLogsUnmanagedDisabledEntriesWithoutWriting() {
        let store = Store(entries(["a"]))
        value(store)["isAllowed"] = false
        var diagnostics: [MenuBarAllowListBridge.Diagnostic] = []
        let bridge = bridge(store, diagnostics: { diagnostics.append($0) })
        bridge.restoreAfterUnexpectedExit()
        XCTAssertEqual(diagnostics, [.unmanagedDisabled(AllowList.identity(bundle("a"))!)])
        XCTAssertEqual(store.writes, 0)
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, false)
    }

    func testLaunchAuditExcludesJournaledEntriesAndRecoversThem() throws {
        let store = Store(entries(["a"]))
        let bridge = bridge(store)
        _ = try activate(bridge)
        var diagnostics: [MenuBarAllowListBridge.Diagnostic] = []
        self.bridge(store, diagnostics: { diagnostics.append($0) }).restoreAfterUnexpectedExit()
        XCTAssertTrue(diagnostics.isEmpty)
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, true)
    }

    func testFreshReadPreservesConcurrentEntryAndSwitchChange() throws {
        let store = Store(entries(["a", "b"]))
        store.beforeRead = { count in
            guard count == 2 else { return }
            self.value(store, 1)["isAllowed"] = false
            store.entries.addObjects(from: self.entries(["new"]).map { $0 })
        }
        let bridge = bridge(store)
        let handle = try activate(bridge)
        XCTAssertEqual(store.entries.count, 6)
        XCTAssertEqual(value(store, 1)["isAllowed"] as? Bool, false)
        XCTAssertEqual(value(store, 2)["isAllowed"] as? Bool, true)
        XCTAssertTrue(handle.invalidate())
        XCTAssertEqual(value(store, 1)["isAllowed"] as? Bool, false)
    }

    func testFreshReadAfterJournalingCapturesNewOriginalValue() throws {
        let store = Store(entries(["a"]))
        var synchronizations = 0
        let bridge = bridge(store, synchronize: {
            synchronizations += 1
            if synchronizations == 1 {
                self.value(store)["isAllowed"] = false
                store.entries.addObjects(from: self.entries(["new"]).map { $0 })
            }
            return self.defaults.synchronize()
        })
        let handle = try activate(bridge)
        XCTAssertEqual(store.entries.count, 4)
        XCTAssertEqual(try journal().values.first?.original, false)
        XCTAssertTrue(handle.invalidate())
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, false)
        XCTAssertEqual(value(store, 1)["isAllowed"] as? Bool, true)
    }
}
