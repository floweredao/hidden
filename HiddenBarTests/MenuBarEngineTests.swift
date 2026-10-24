import AppKit
import XCTest

private final class FakeItems: MenuBarItemProvider {
    private let bar = NSStatusBar()
    let toggleItem: NSStatusItem
    let separatorItem: NSStatusItem
    var alwaysHiddenItem: NSStatusItem?

    init() {
        toggleItem = bar.statusItem(withLength: NSStatusItem.variableLength)
        separatorItem = bar.statusItem(withLength: 1)
        alwaysHiddenItem = bar.statusItem(withLength: 20)
        toggleItem.isVisible = true
        separatorItem.isVisible = true
        alwaysHiddenItem?.isVisible = true
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
    var unavailableReason: HidingUnavailableReason = .fileAccessNeeded
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
        guard requests.indices.contains(index) else {
            XCTFail("No activation request at index \(index)")
            return FakeAssertion(allowed: [])
        }
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
    var delays: [TimeInterval] = []

    func schedule(_ delay: TimeInterval, _ body: @escaping () -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem(block: body)
        delays.append(delay)
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

final class LegacyLengthEngineTests: XCTestCase {
    func testApplyAndRestoreLengthsWithoutHidingOurItems() {
        let items = FakeItems()
        let engine = LegacyLengthEngine(items: items)
        engine.apply(collapsed: true, alwaysHiddenShown: false)
        XCTAssertGreaterThan(items.separatorItem.length, 20)
        XCTAssertGreaterThan(items.alwaysHiddenItem!.length, 20)
        engine.apply(collapsed: false, alwaysHiddenShown: false)
        XCTAssertEqual(items.separatorItem.length, 20)
        let length = items.alwaysHiddenItem!.length
        items.alwaysHiddenItem?.length = 300
        engine.invalidateLayout()
        XCTAssertEqual(items.alwaysHiddenItem?.length, length)
        XCTAssertTrue(engine.restoreAll())
        XCTAssertEqual(items.separatorItem.length, 20)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 20)
    }
}

private final class ManualWriter {
    var pending: [() -> Void] = []
    var isExecuting = false
    func enqueue(_ work: @escaping () -> Void) { pending.append(work) }
    func run() {
        while !pending.isEmpty {
            let work = pending.removeFirst()
            isExecuting = true
            work()
            isExecuting = false
        }
    }
    func synchronize(_ work: @escaping () -> Bool) -> Bool {
        run()
        isExecuting = true
        defer { isExecuting = false }
        return work()
    }
}

final class AllowListEngineTests: XCTestCase {
    private var items: FakeItems!
    private var inventory: FakeInventory!
    private var bridge: FakeVisibility!
    private var scheduler: ManualScheduler!
    private var writer: ManualWriter!
    private var workspace: NotificationCenter!
    private var boundaryX: CGFloat = 1300
    private var alwaysX: CGFloat = 1000
    private var shift: CGFloat = 0
    private var missingAlwaysFrame = false
    private var missingSeparatorFrame = false
    private var moves: NotificationCenter!
    private var arrowWindow: NSObject!
    private var separatorWindow: NSObject!
    private var alwaysWindow: NSObject!

    override func setUp() {
        items = FakeItems()
        inventory = FakeInventory()
        inventory.items = [item("com.always", x: 900), item("com.hidden", x: 1100), item("com.visible", x: 1400)]
        bridge = FakeVisibility()
        scheduler = ManualScheduler()
        writer = ManualWriter()
        workspace = NotificationCenter()
        boundaryX = 1300
        alwaysX = 1000
        shift = 0
        missingAlwaysFrame = false
        missingSeparatorFrame = false
        moves = NotificationCenter()
        arrowWindow = NSObject()
        separatorWindow = NSObject()
        alwaysWindow = NSObject()
    }

    private func makeEngine() -> AllowListEngine {
        AllowListEngine(items: items, bridge: bridge, inventory: inventory,
            ownBundle: "own", frame: { [unowned self] item in
                if item === self.items.toggleItem { return CGRect(x: 1330 + self.shift, y: 0, width: 20, height: 24) }
                if item === self.items.separatorItem {
                    return self.missingSeparatorFrame ? nil : CGRect(x: self.boundaryX + self.shift, y: 0, width: 20, height: 24)
                }
                return self.missingAlwaysFrame ? nil : CGRect(x: self.alwaysX + self.shift, y: 0, width: 20, height: 24)
            }, isLTR: { true }, window: { [unowned self] item in
                if item === self.items.toggleItem { return self.arrowWindow }
                if item === self.items.separatorItem { return self.separatorWindow }
                return self.alwaysWindow
            }, notifications: moves, workspaceNotifications: workspace,
            schedule: scheduler.schedule, enqueue: writer.enqueue, synchronize: writer.synchronize,
            deliver: { $0() })
    }

    private func snapshot(_ engine: AllowListEngine) {
        scheduler.fire()
        writer.run()
    }

    private func complete(_ index: Int) {
        bridge.succeed(index)
        writer.run()
    }

    func testDesiredHiddenSetsAndSynchronousOwnItems() {
        let engine = makeEngine()
        snapshot(engine)
        engine.apply(collapsed: true, alwaysHiddenShown: false)
        XCTAssertFalse(items.separatorItem.isVisible)
        XCTAssertFalse(items.alwaysHiddenItem!.isVisible)
        XCTAssertEqual(items.separatorItem.length, 20)
        XCTAssertTrue(bridge.requests.isEmpty, "writes never run in apply")
        writer.run()
        XCTAssertEqual(bridge.requests.first?.hidden, ["com.always", "com.hidden"])
        XCTAssertEqual(Set(bridge.requests.first?.bundles ?? []), ["com.visible", "own", "com.apple.MenuBarAgent", "com.apple.controlcenter"])
        complete(0)
        engine.apply(collapsed: false, alwaysHiddenShown: false)
        XCTAssertTrue(items.separatorItem.isVisible)
        XCTAssertFalse(items.alwaysHiddenItem!.isVisible)
        writer.run()
        XCTAssertEqual(bridge.requests.dropFirst().first?.hidden, ["com.always"])
        complete(1)
        let restores = bridge.restores
        engine.apply(collapsed: false, alwaysHiddenShown: true)
        writer.run()
        XCTAssertEqual(bridge.restores, restores + 1)
        XCTAssertTrue(items.alwaysHiddenItem!.isVisible)
        XCTAssertEqual(scheduler.delays.last, 1.5)
    }

    func testLatestPendingWriteWinsWhileAnActivationIsInFlight() {
        let engine = makeEngine()
        snapshot(engine)
        engine.apply(collapsed: true, alwaysHiddenShown: false)
        writer.run()
        XCTAssertEqual(bridge.requests.count, 1)
        engine.apply(collapsed: false, alwaysHiddenShown: true)
        engine.apply(collapsed: true, alwaysHiddenShown: false)
        engine.apply(collapsed: false, alwaysHiddenShown: false)
        writer.run()
        XCTAssertEqual(bridge.requests.count, 1)
        complete(0)
        XCTAssertEqual(bridge.requests.count, 2)
        XCTAssertEqual(bridge.requests.dropFirst().first?.hidden, ["com.always"])
        complete(1)
    }

    func testRequestsCoalesceBeforeWriterStarts() {
        let engine = makeEngine()
        snapshot(engine)
        engine.apply(collapsed: true, alwaysHiddenShown: false)
        engine.apply(collapsed: false, alwaysHiddenShown: false)
        writer.run()
        XCTAssertEqual(bridge.requests.count, 1)
        XCTAssertEqual(bridge.requests.first?.hidden, ["com.always"])
        complete(0)
    }

    func testFirstCollapseWaitsForLaunchSnapshotWithoutAnotherApply() {
        inventory.deferred = true
        let engine = makeEngine()
        scheduler.fire()
        XCTAssertEqual(inventory.snapshots, 1)
        engine.apply(collapsed: true, alwaysHiddenShown: false)
        writer.run()
        XCTAssertTrue(bridge.requests.isEmpty)
        inventory.deliver()
        writer.run()
        XCTAssertEqual(bridge.requests.count, 1)
        XCTAssertEqual(bridge.requests.first?.hidden, ["com.always", "com.hidden"])
        complete(0)
    }

    func testCollapseDoesNotCancelPendingLaunchSnapshot() {
        let engine = makeEngine()
        engine.apply(collapsed: true, alwaysHiddenShown: false)
        snapshot(engine)
        XCTAssertEqual(bridge.requests.count, 1)
        complete(0)
    }

    func testHiddenBundlesKeepTheirCachedSectionAcrossStaleFrames() {
        let engine = makeEngine()
        snapshot(engine)
        engine.apply(collapsed: true, alwaysHiddenShown: false)
        writer.run()
        complete(0)
        inventory.items = [item("com.always", x: 1800), item("com.hidden", x: 1800), item("com.visible", x: 1450)]
        engine.refreshArrangement()
        snapshot(engine)
        XCTAssertEqual(bridge.requests.last?.hidden, ["com.always", "com.hidden"])
        complete(1)
    }

    func testNoSnapshotsOnClicksOrIdleAndOneShotDoesNotRepeat() {
        let engine = makeEngine()
        snapshot(engine)
        engine.apply(collapsed: true, alwaysHiddenShown: true)
        writer.run()
        complete(0)
        XCTAssertEqual(inventory.snapshots, 1)
        engine.apply(collapsed: false, alwaysHiddenShown: true)
        writer.run()
        XCTAssertEqual(inventory.snapshots, 1)
        snapshot(engine)
        XCTAssertEqual(inventory.snapshots, 2)
        XCTAssertTrue(scheduler.pending.allSatisfy { $0.isCancelled })
    }

    func testSnapshotTriggersDebounceAndWorkspaceOnlyWhenFullyShown() {
        let engine = makeEngine()
        engine.refreshArrangement()
        engine.invalidateLayout()
        workspace.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        snapshot(engine)
        XCTAssertEqual(inventory.snapshots, 1)
        engine.apply(collapsed: true, alwaysHiddenShown: true)
        writer.run()
        complete(0)
        workspace.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        XCTAssertTrue(scheduler.pending.allSatisfy { $0.isCancelled })
        engine.apply(collapsed: false, alwaysHiddenShown: false)
        writer.run()
        complete(1)
        workspace.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        XCTAssertTrue(scheduler.pending.allSatisfy { $0.isCancelled })
    }

    func testRefreshedShownBundlesFollowSeparatorRatherThanArrow() {
        inventory.items = [item("com.gap", x: 1315), item("com.hidden", x: 1100)]
        let engine = makeEngine()
        snapshot(engine)
        engine.apply(collapsed: true, alwaysHiddenShown: true)
        writer.run()
        XCTAssertEqual(bridge.requests.first?.hidden, ["com.hidden"])
        complete(0)
    }

    func testDisablingAlwaysHiddenRevealsItsBundlesWhileExpanded() {
        let engine = makeEngine()
        snapshot(engine)
        engine.apply(collapsed: false, alwaysHiddenShown: false)
        writer.run()
        complete(0)
        items.alwaysHiddenItem = nil
        let restores = bridge.restores
        engine.apply(collapsed: false, alwaysHiddenShown: false)
        writer.run()
        XCTAssertEqual(bridge.restores, restores + 1)
    }

    func testArrangementIsCachedWhileSeparatorIsAbsent() {
        let engine = makeEngine()
        XCTAssertTrue(engine.isArrangementValid)
        XCTAssertTrue(engine.isAlwaysHiddenSeparatorPlaced)
        engine.apply(collapsed: true, alwaysHiddenShown: false)
        boundaryX = 1400
        XCTAssertTrue(engine.isArrangementValid)
        XCTAssertTrue(engine.isAlwaysHiddenSeparatorPlaced)
        engine.apply(collapsed: false, alwaysHiddenShown: true)
        XCTAssertFalse(engine.isArrangementValid)
    }

    func testQuitRestoresAndCancelsQueuedHideBeforeItWrites() {
        let engine = makeEngine()
        snapshot(engine)
        let restores = bridge.restores
        engine.apply(collapsed: true, alwaysHiddenShown: false)
        XCTAssertTrue(engine.restoreAll())
        writer.run()
        XCTAssertTrue(bridge.requests.isEmpty)
        XCTAssertEqual(bridge.restores, restores + 1)
        engine.refreshArrangement()
        snapshot(engine)
        XCTAssertTrue(bridge.requests.isEmpty)
    }

    func testUnavailableBridgeLeavesImmediateUIAndReportsFileAccess() {
        bridge.isAvailable = false
        let engine = makeEngine()
        snapshot(engine)
        engine.apply(collapsed: true, alwaysHiddenShown: false)
        writer.run()
        XCTAssertFalse(items.separatorItem.isVisible)
        XCTAssertTrue(engine.needsFileAccess)
        XCTAssertTrue(bridge.requests.isEmpty)
        bridge.isAvailable = true
        engine.requestAccess()
        writer.run()
        XCTAssertFalse(engine.needsFileAccess)
        XCTAssertEqual(bridge.accessRequests, 1)
        XCTAssertEqual(bridge.requests.count, 1)
        complete(0)
    }
    func testUnknownAlwaysHiddenPlacementStaysMeasurableUntilLaunchSnapshot() {
        missingAlwaysFrame = true
        let engine = makeEngine()
        engine.apply(collapsed: false, alwaysHiddenShown: false)
        XCTAssertTrue(engine.isAlwaysHiddenSeparatorPlaced, "unknown placement must not lock out a secondary click")
        XCTAssertTrue(items.alwaysHiddenItem!.isVisible)
        missingAlwaysFrame = false
        snapshot(engine)
        XCTAssertTrue(engine.isAlwaysHiddenSeparatorPlaced)
        XCTAssertFalse(items.alwaysHiddenItem!.isVisible)
        XCTAssertEqual(bridge.requests.first?.hidden, ["com.always"])
        complete(0)
    }

    func testPermissionGrantedAfterSkippedLaunchSnapshotRetriesOnCollapse() {
        inventory.isAuthorized = false
        let engine = makeEngine()
        snapshot(engine)
        XCTAssertEqual(inventory.snapshots, 0)
        XCTAssertEqual(inventory.authorizationRequests, 1)
        inventory.isAuthorized = true
        engine.apply(collapsed: true, alwaysHiddenShown: false)
        XCTAssertEqual(inventory.snapshots, 0, "the click only schedules the requested snapshot")
        snapshot(engine)
        XCTAssertEqual(inventory.snapshots, 1)
        XCTAssertEqual(bridge.requests.first?.hidden, ["com.always", "com.hidden"])
        complete(0)
    }

    func testMissingLaunchBoundaryRetriesOnNextCollapseWithoutPolling() {
        missingSeparatorFrame = true
        let engine = makeEngine()
        snapshot(engine)
        XCTAssertEqual(inventory.snapshots, 0)
        XCTAssertTrue(scheduler.pending.isEmpty)
        missingSeparatorFrame = false
        engine.apply(collapsed: true, alwaysHiddenShown: false)
        snapshot(engine)
        XCTAssertEqual(inventory.snapshots, 1)
        XCTAssertEqual(bridge.requests.first?.hidden, ["com.always", "com.hidden"])
        complete(0)
    }

    func testMoveNotificationsIgnoreUniformShiftAndCoalesceChangedOffsets() {
        let engine = makeEngine()
        snapshot(engine)
        shift = 100
        moves.post(name: NSWindow.didMoveNotification, object: arrowWindow)
        moves.post(name: NSWindow.didMoveNotification, object: separatorWindow)
        snapshot(engine)
        XCTAssertEqual(inventory.snapshots, 1, "clock width changes must not walk AX")
        boundaryX = 1250
        moves.post(name: NSWindow.didMoveNotification, object: separatorWindow)
        moves.post(name: NSWindow.didMoveNotification, object: arrowWindow)
        snapshot(engine)
        XCTAssertEqual(inventory.snapshots, 2)
        alwaysX = 950
        moves.post(name: NSWindow.didMoveNotification, object: alwaysWindow)
        snapshot(engine)
        XCTAssertEqual(inventory.snapshots, 3)
        XCTAssertTrue(scheduler.pending.isEmpty)
    }

    func testQuitWithActivationInFlightRestoresOnceAndIgnoresLateCompletion() {
        let engine = makeEngine()
        snapshot(engine)
        engine.apply(collapsed: true, alwaysHiddenShown: false)
        writer.run()
        XCTAssertEqual(bridge.requests.count, 1)
        let restores = bridge.restores
        XCTAssertTrue(engine.restoreAll())
        complete(0)
        XCTAssertEqual(bridge.requests.count, 1)
        XCTAssertEqual(bridge.restores, restores + 1)
        XCTAssertTrue(writer.pending.isEmpty)
    }

}

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
        var failReads = false
        var ignoreWrites = false
        var beforeRead: ((Int) -> Void)?
        var beforeWrite: (() -> Void)?

        init(_ entries: NSMutableArray) { self.entries = entries }

        func read() throws -> NSMutableArray {
            reads += 1
            beforeRead?(reads)
            if failReads { throw NSError(domain: "TestStore.Synchronize", code: 1) }
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

    func testReleasedTargetKeepsUserOverrideUntilNextCollapse() throws {
        let store = Store(entries(["a"]))
        let bridge = bridge(store)
        let first = try activate(bridge)
        value(store)["isAllowed"] = true
        let second = try activate(bridge, keeping: ["a"])
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

    func testFreshReadAfterJournalingPreservesOriginalForHiddenTarget() throws {
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
        XCTAssertEqual(try journal().values.first?.original, true)
        XCTAssertEqual(try journal().values.first?.lastObserved, false)
        XCTAssertTrue(handle.invalidate())
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, true)
        XCTAssertEqual(value(store, 1)["isAllowed"] as? Bool, true)
    }

    func testRestoreCompletionRereadsBeforeDiscardingRecovery() throws {
        let store = Store(entries(["a"]))
        var synchronizations = 0
        let bridge = bridge(store, synchronize: {
            synchronizations += 1
            if synchronizations == 6 {
                self.value(store)["isAllowed"] = false
            }
            return self.defaults.synchronize()
        })
        let handle = try activate(bridge)
        XCTAssertFalse(handle.invalidate(), "a late OFF must leave restore unconfirmed")
        XCTAssertEqual(try journal().values.first?.original, true)
        XCTAssertTrue(defaults.bool(forKey: pendingKey))
    }

    func testSuccessfulRestoreKeepsCompletedRecoveryEvidence() throws {
        let store = Store(entries(["a"]))
        let bridge = bridge(store)
        let handle = try activate(bridge)
        XCTAssertTrue(handle.invalidate())
        let data = try XCTUnwrap(defaults.data(forKey: "allowInMenuBarCompletedRecovery"))
        let completed = try PropertyListDecoder().decode(AllowList.Journal.self, from: data)
        XCTAssertEqual(completed.values.first?.original, true)
        XCTAssertNotNil(completed.values.first?.transactionID)
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, true)
    }

    func testRestoreCompletionReadFailureKeepsRecovery() throws {
        let store = Store(entries(["a"]))
        var synchronizations = 0
        let bridge = bridge(store, synchronize: {
            synchronizations += 1
            if synchronizations == 6 { store.failReads = true }
            return self.defaults.synchronize()
        })
        let handle = try activate(bridge)
        XCTAssertFalse(handle.invalidate(), "failed synchronized read is not confirmation")
        XCTAssertEqual(try journal().values.first?.original, true)
        XCTAssertTrue(defaults.bool(forKey: pendingKey))
        store.failReads = false
        XCTAssertTrue(handle.invalidate())
    }

    func testUnattributedOnThenOffKeepsRetiredOriginal() throws {
        let store = Store(entries(["a"]))
        let bridge = bridge(store)
        let first = try activate(bridge)
        value(store)["isAllowed"] = true
        let second = try activate(bridge, keeping: ["a"])
        value(store)["isAllowed"] = false
        XCTAssertTrue(first.invalidate())
        XCTAssertTrue(second.invalidate())
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, false, "an external OFF is not ours to undo")
        let data = try XCTUnwrap(defaults.data(forKey: "allowInMenuBarRetiredRecovery"))
        let retired = try PropertyListDecoder().decode(AllowList.Journal.self, from: data)
        XCTAssertEqual(retired.values.first?.original, true)
        XCTAssertEqual(retired.values.first?.retiredReason, "unattributedChange")
        XCTAssertEqual(retired.values.first?.lastObserved, true)
        XCTAssertNotNil(retired.values.first?.transactionID)
    }

    func testRebasedOriginalConflictRetainsFirstObservedValue() throws {
        let store = Store(entries(["a"]))
        var synchronizations = 0
        let bridge = bridge(store, synchronize: {
            synchronizations += 1
            if synchronizations == 1 { self.value(store)["isAllowed"] = false }
            return self.defaults.synchronize()
        })
        let handle = try activate(bridge)
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, false)
        XCTAssertEqual(try journal().values.first?.original, true)
        XCTAssertEqual(try journal().values.first?.lastObserved, false)
        XCTAssertNil(defaults.data(forKey: "allowInMenuBarRetiredRecovery"))
        XCTAssertTrue(handle.invalidate())
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, true)
        let data = try XCTUnwrap(defaults.data(forKey: "allowInMenuBarCompletedRecovery"))
        let completed = try PropertyListDecoder().decode(AllowList.Journal.self, from: data)
        XCTAssertEqual(completed.values.first?.original, true)
        XCTAssertEqual(completed.values.first?.lastObserved, false)
    }

    func testDuplicateIdentityCannotConsumeRecoveryOnce() throws {
        let store = Store(entries(["a"]))
        let bridge = bridge(store)
        let handle = try activate(bridge)
        store.entries.addObjects(from: try store.read().map { $0 })
        XCTAssertFalse(handle.invalidate())
        XCTAssertEqual(store.writes, 1, "duplicate identities must fail before external writes")
        XCTAssertEqual(value(store, 0)["isAllowed"] as? Bool, false)
        XCTAssertEqual(value(store, 1)["isAllowed"] as? Bool, false)
        XCTAssertEqual(try journal().values.first?.original, true)
    }

    func testRepeatedHiddenReactivationAndDisappearingInstancesKeepOriginals() throws {
        let store = Store(entries(["a"]))
        let bridge = bridge(store)
        var handle = try activate(bridge)
        let identity = try XCTUnwrap(AllowList.identity(bundle("a")))
        let original = try XCTUnwrap(journal()[identity])
        var disappeared: [Any] = []
        for cycle in 0..<3 {
            value(store)["isAllowed"] = true
            let instanceKey = path("diag\(cycle)")
            store.entries.add(instanceKey)
            store.entries.add(NSMutableDictionary(dictionary: [
                "isAllowed": true, "menuItemLocations": NSMutableArray(object: bundle("a"))
            ]))
            handle = try activate(bridge)
            XCTAssertEqual(value(store)["isAllowed"] as? Bool, false)
            XCTAssertEqual(value(store, 1)["isAllowed"] as? Bool, false)
            XCTAssertEqual(try journal()[identity], original)
            let instanceID = try XCTUnwrap(AllowList.identity(instanceKey))
            XCTAssertEqual(try journal()[instanceID]?.original, true)

            let writes = store.writes
            handle = try activate(bridge)
            XCTAssertEqual(store.writes, writes, "unchanged OFF switches must not be rewritten")
            disappeared.append(contentsOf: [store.entries[2], store.entries[3]])
            store.entries.removeObjects(in: NSRange(location: 2, length: 2))
            handle = try activate(bridge)
            XCTAssertEqual(try journal()[instanceID]?.original, true)
        }
        XCTAssertFalse(handle.invalidate(), "missing instances still require recovery")
        XCTAssertEqual(try journal().count, 3)
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, true)
        store.entries.addObjects(from: disappeared)
        XCTAssertTrue(handle.invalidate())
        XCTAssertTrue(try journal().isEmpty)
        for index in 0..<4 {
            XCTAssertEqual(value(store, index)["isAllowed"] as? Bool, true)
        }
        let completed = try PropertyListDecoder().decode(AllowList.Journal.self,
            from: XCTUnwrap(defaults.data(forKey: "allowInMenuBarCompletedRecovery")))
        XCTAssertEqual(completed.count, 4)
        XCTAssertTrue(completed.values.allSatisfy(\.original))
    }

    func testExplicitRetargetRehidesDespiteEarlierReleasedOverride() throws {
        let store = Store(entries(["a"]))
        let bridge = bridge(store)
        let first = try activate(bridge)
        value(store)["isAllowed"] = true
        let released = try activate(bridge, keeping: ["a"])
        var result: Result<NativeVisibilityAssertion, Error>?
        bridge.activate(allowedSystemItems: [], allowedBundleIdentifiers: [],
                        hiddenBundleIdentifiers: ["a"]) { result = $0 }
        let retargeted = try XCTUnwrap(result).get()
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, false)
        XCTAssertEqual(try journal().values.first?.original, true)
        XCTAssertTrue(first.invalidate())
        XCTAssertTrue(released.invalidate())
        XCTAssertTrue(retargeted.invalidate())
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, true)
    }

    func testExplicitTargetRebaseKeepsFirstOriginalInBothDirections() throws {
        for original in [true, false] {
            let store = Store(entries(["a"]))
            value(store)["isAllowed"] = original
            var synchronizations = 0
            let bridge = bridge(store, synchronize: {
                synchronizations += 1
                if synchronizations == 1 { self.value(store)["isAllowed"] = !original }
                return self.defaults.synchronize()
            })
            var result: Result<NativeVisibilityAssertion, Error>?
            bridge.activate(allowedSystemItems: [], allowedBundleIdentifiers: [],
                            hiddenBundleIdentifiers: ["a"]) { result = $0 }
            let handle = try XCTUnwrap(result).get()
            XCTAssertEqual(value(store)["isAllowed"] as? Bool, false)
            XCTAssertEqual(try journal().values.first?.original, original)
            XCTAssertEqual(try journal().values.first?.lastObserved, !original)
            XCTAssertNil(try journal().values.first?.retiredReason)
            XCTAssertNil(defaults.data(forKey: "allowInMenuBarRetiredRecovery"))
            XCTAssertTrue(handle.invalidate())
            XCTAssertEqual(value(store)["isAllowed"] as? Bool, original)
        }
    }

    func testEntryMissingOnRebaseKeepsFirstJournalOriginal() throws {
        let store = Store(entries(["a"]))
        let originalEntries = try store.read()
        var synchronizations = 0
        let bridge = bridge(store, synchronize: {
            synchronizations += 1
            if synchronizations == 1 { store.entries.removeAllObjects() }
            return self.defaults.synchronize()
        })
        let handle = try activate(bridge)
        XCTAssertEqual(try journal().values.first?.original, true)
        XCTAssertEqual(store.writes, 0)
        XCTAssertFalse(bridge.restoreAll())
        XCTAssertEqual(try journal().values.first?.original, true)
        store.entries = originalEntries
        XCTAssertTrue(bridge.restoreAll())
        XCTAssertTrue(try journal().isEmpty)
        XCTAssertEqual(value(store)["isAllowed"] as? Bool, true)
        XCTAssertTrue(handle.invalidate())
    }
}
