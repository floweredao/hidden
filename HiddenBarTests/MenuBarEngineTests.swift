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

    func requestAuthorization() {
        authorizationRequests += 1
    }

    func snapshot(completion: @escaping ([MenuBarInventoryItem]) -> Void) {
        snapshots += 1
        completion(items)
    }
}

private final class FakeAssertion: NativeVisibilityAssertion {
    let allowed: [String]
    private(set) var isInvalidated = false
    var onInvalidate: (() -> Void)?

    init(allowed: [String]) {
        self.allowed = allowed
    }

    func invalidate() {
        isInvalidated = true
        onInvalidate?()
    }
}

// Hands every activation to the test, which decides when and how it completes.
private final class FakeVisibility: NativeVisibilityProviding {
    struct Request {
        let systemItems: [Int]
        let bundles: [String]
        let completion: (Result<NativeVisibilityAssertion, Error>) -> Void
    }

    var isAvailable = true
    var requests: [Request] = []

    func activate(allowedSystemItems: [Int],
                  allowedBundleIdentifiers: [String],
                  completion: @escaping (Result<NativeVisibilityAssertion, Error>) -> Void) {
        requests.append(Request(systemItems: allowedSystemItems, bundles: allowedBundleIdentifiers, completion: completion))
    }

    @discardableResult
    func succeed(_ index: Int) -> FakeAssertion {
        let assertion = FakeAssertion(allowed: requests[index].bundles)
        requests[index].completion(.success(assertion))
        return assertion
    }

    func fail(_ index: Int) {
        requests[index].completion(.failure(NSError(domain: "test", code: 1)))
    }
}

private final class FakeCaptureActivity: CaptureActivityMonitoring {
    var isActive = false
    var onChange: (() -> Void)?

    func set(_ active: Bool) {
        isActive = active
        onChange?()
    }
}

private func item(_ bundle: String?, x: CGFloat, width: CGFloat = 24) -> MenuBarInventoryItem {
    return MenuBarInventoryItem(bundleIdentifier: bundle, frame: CGRect(x: x, y: 0, width: width, height: 24))
}

// LTR bar used throughout: always-hidden separator at 1000, the boundary at 1300
// (the separator for the resolver, the arrow for the native engine).
private let alwaysHiddenSeparator = CGRect(x: 1000, y: 0, width: 20, height: 24)
private let separator = CGRect(x: 1300, y: 0, width: 20, height: 24)

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
    private var running: [String] = []
    private let launches = NotificationCenter()
    private var capture: FakeCaptureActivity!

    override func setUp() {
        super.setUp()
        items = FakeItems()
        inventory = FakeInventory()
        inventory.items = [item("com.always", x: 900), item("com.hidden", x: 1100), item("com.visible", x: 1400)]
        visibility = FakeVisibility()
        running = []
        capture = FakeCaptureActivity()
    }

    private func makeEngine() -> NativeVisibilityEngine {
        let items = self.items!
        return NativeVisibilityEngine(items: items, inventory: inventory, visibility: visibility,
                                      captureActivity: capture,
                                      ownBundleIdentifier: "com.dwarvesv.minimalbar",
                                      itemFrame: { $0 === items.toggleItem ? separator : alwaysHiddenSeparator },
                                      isLTR: { true },
                                      runningBundleIdentifiers: { [unowned self] in self.running },
                                      launchNotifications: launches)
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
        XCTAssertEqual(items.alwaysHiddenItem?.length, 0)

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

    func testSectionsAreNotReadWhileCollapsed() {
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: true)
        visibility.succeed(visibility.requests.count - 1)
        engine.collapse { _ in }
        visibility.succeed(visibility.requests.count - 1)
        let snapshotsBefore = inventory.snapshots

        // Hidden items would report stale positions now; the cached layout is used.
        inventory.items = [item("com.visible", x: 100)]
        engine.expand()
        XCTAssertEqual(inventory.snapshots, snapshotsBefore)
        XCTAssertEqual(visibility.requests.last?.bundles, ["com.dwarvesv.minimalbar", "com.hidden", "com.visible"])
    }

    // With only the always-hidden section hidden, every other icon is on screen,
    // so a ⌘-drag made while expanded counts on the next collapse; the hidden
    // section's stale positions do not.
    func testWhileOnlyAlwaysHiddenIsHiddenTheRestIsReadLive() {
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: true)
        visibility.succeed(visibility.requests.count - 1)

        inventory.items = [item("com.always", x: 1400), item("com.hidden", x: 1400), item("com.visible", x: 1100)]
        engine.collapse { _ in }
        XCTAssertEqual(visibility.requests.last?.bundles, ["com.dwarvesv.minimalbar", "com.hidden"])
    }

    // Hiding the always-hidden section takes its separator with it, as it did
    // before macOS 27; it only goes once the icons are actually hidden, and does
    // not flash back while collapsing or expanding.
    func testAlwaysHiddenSeparatorHidesWithItsSection() {
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: false)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 20)

        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: true)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 20, "read where it is before hiding anything")
        visibility.succeed(visibility.requests.count - 1)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 0)

        engine.collapse { _ in }
        XCTAssertEqual(items.alwaysHiddenItem?.length, 0)
        visibility.succeed(visibility.requests.count - 1)

        engine.expand()
        XCTAssertEqual(items.alwaysHiddenItem?.length, 0)
        visibility.succeed(visibility.requests.count - 1)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 0)

        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: false)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 20)
    }

    func testAlwaysHiddenSeparatorStaysWhenItsSectionCannotBeHidden() {
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: true)
        visibility.fail(visibility.requests.count - 1)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 20)
    }

    func testAlwaysHiddenSeparatorEnabledWhileCollapsedHasNoWidth() {
        let engine = makeEngine()
        engine.collapse { _ in }
        visibility.succeed(visibility.requests.count - 1)

        items.alwaysHiddenItem?.length = 20
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: false)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 0)
    }

    func testDisablingTheSectionRevealsItsApps() {
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: true)
        let hidingAlwaysHidden = visibility.succeed(visibility.requests.count - 1)

        engine.updateAlwaysHiddenSection(enabled: false, separatorHidden: true)
        XCTAssertTrue(hidingAlwaysHidden.isInvalidated)
    }

    // An app launched since the sections were read is not always hidden, so it
    // shows while expanded, at once and after a later launch.
    func testAppsLaunchedWhileExpandedAreShown() {
        running = ["com.early"]
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: true)
        XCTAssertEqual(visibility.requests.last?.bundles, ["com.dwarvesv.minimalbar", "com.hidden", "com.visible", "com.early"])
        visibility.succeed(visibility.requests.count - 1)

        running = ["com.early", "com.late", "com.always"]
        let before = visibility.requests.count
        launches.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        XCTAssertEqual(visibility.requests.count, before + 1)
        XCTAssertEqual(visibility.requests.last?.bundles, ["com.dwarvesv.minimalbar", "com.hidden", "com.visible", "com.early", "com.late"])
    }

    func testLaunchesDoNotTouchACollapsedBar() {
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
        XCTAssertEqual(results, [])
    }

    func testDisplayChangeKeepsTheBarCollapsed() {
        let engine = makeEngine()
        engine.collapse { _ in }
        let collapsed = visibility.succeed(0)

        engine.invalidateLayout()
        XCTAssertEqual(engine.state, .collapsed)
        XCTAssertFalse(collapsed.isInvalidated)
    }

    // MARK: Microphone and camera (#437)

    func testCollapseWhileCapturingHoldsNoRestriction() {
        capture.isActive = true
        let engine = makeEngine()
        var results: [CollapseResult] = []
        engine.collapse { results.append($0) }

        XCTAssertEqual(results, [.collapsed], "the bar keeps the state the user asked for")
        XCTAssertEqual(engine.state, .collapsed)
        XCTAssertTrue(visibility.requests.isEmpty, "assessment mode would hide the recording indicators")
    }

    func testCaptureStartingWhileCollapsedDropsTheRestriction() {
        let engine = makeEngine()
        engine.collapse { _ in }
        let collapsed = visibility.succeed(0)

        capture.set(true)
        XCTAssertTrue(collapsed.isInvalidated)
        XCTAssertEqual(engine.state, .collapsed)
        XCTAssertEqual(visibility.requests.count, 1)
    }

    func testCaptureStoppingHidesAgainFromAFreshRead() {
        let engine = makeEngine()
        engine.collapse { _ in }
        visibility.succeed(0)
        capture.set(true)
        let snapshotsBefore = inventory.snapshots

        // The bar is unrestricted while capturing, so the sections are re-read.
        inventory.items = [item("com.hidden", x: 1100), item("com.moved", x: 1400)]
        capture.set(false)
        XCTAssertEqual(inventory.snapshots, snapshotsBefore + 1)
        XCTAssertEqual(visibility.requests.count, 2)
        XCTAssertEqual(visibility.requests.last?.bundles, ["com.dwarvesv.minimalbar", "com.moved"])
        let restored = visibility.succeed(1)
        XCTAssertFalse(restored.isInvalidated)
        XCTAssertEqual(engine.state, .collapsed)
    }

    func testExpandWhileCapturingThenStoppingRestoresTheExpandedPresentation() {
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: true)
        visibility.succeed(visibility.requests.count - 1)
        engine.collapse { _ in }
        let collapsed = visibility.succeed(visibility.requests.count - 1)

        capture.set(true)
        XCTAssertTrue(collapsed.isInvalidated)
        let requestsWhileCapturing = visibility.requests.count
        engine.expand()
        XCTAssertEqual(visibility.requests.count, requestsWhileCapturing, "nothing is hidden while capturing, not even always-hidden")

        capture.set(false)
        XCTAssertEqual(visibility.requests.last?.bundles, ["com.dwarvesv.minimalbar", "com.hidden", "com.visible"])
    }

    func testCaptureStartingDuringActivationDropsTheResultButStillCollapses() {
        let engine = makeEngine()
        var results: [CollapseResult] = []
        engine.collapse { results.append($0) }

        capture.set(true)
        let late = visibility.succeed(0)

        XCTAssertTrue(late.isInvalidated)
        XCTAssertEqual(results, [.collapsed])
        XCTAssertEqual(engine.state, .collapsed)
    }

    // Expanded with the always-hidden section hidden also holds the assessment
    // restriction, so a call started while expanded must drop it too.
    func testCaptureWhileExpandedWithAlwaysHiddenHiddenDropsAndRestoresIt() {
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: true)
        let expanded = visibility.succeed(visibility.requests.count - 1)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 0)

        capture.set(true)
        XCTAssertTrue(expanded.isInvalidated, "nothing may be restricted while the mic is in use")
        XCTAssertEqual(engine.state, .expanded)
        let requestsWhileCapturing = visibility.requests.count
        engine.applicationLaunched()
        XCTAssertEqual(visibility.requests.count, requestsWhileCapturing)

        capture.set(false)
        XCTAssertEqual(visibility.requests.last?.bundles, ["com.dwarvesv.minimalbar", "com.hidden", "com.visible"],
                       "the always-hidden section is kept from the last read while its separator has no width")
        visibility.succeed(visibility.requests.count - 1)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 0)
    }

    func testCaptureStoppingWhileCollapsedKeepsTheAlwaysHiddenSeparatorCollapsed() {
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: false)
        engine.collapse { _ in }
        visibility.succeed(visibility.requests.count - 1)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 0)

        capture.set(true)
        capture.set(false)
        XCTAssertEqual(visibility.requests.last?.bundles, ["com.dwarvesv.minimalbar", "com.visible"])
        visibility.succeed(visibility.requests.count - 1)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 0)
        XCTAssertEqual(engine.state, .collapsed)
    }

    func testUnchangedCaptureStateLeavesTheRestrictionAlone() {
        let engine = makeEngine()
        engine.collapse { _ in }
        let collapsed = visibility.succeed(0)

        capture.set(false)
        XCTAssertFalse(collapsed.isInvalidated)
        XCTAssertEqual(visibility.requests.count, 1)
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
