import AppKit

final class AllowListEngine: MenuBarEngine {
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> DispatchWorkItem
    private struct Offsets: Equatable {
        let separatorToArrow: CGFloat
        let alwaysHiddenToSeparator: CGFloat?
    }

    private struct Write {
        let revision: Int
        let hidden: Set<String>
        let allowed: [String]
    }

    private weak var items: MenuBarItemProvider?
    private let bridge: NativeVisibilityProviding
    private let inventory: MenuBarInventoryProviding
    private let ownBundle: String
    private let frame: (NSStatusItem) -> CGRect?
    private let isLTR: () -> Bool
    private let window: (NSStatusItem) -> AnyObject?
    private let schedule: Scheduler
    private let enqueue: (@escaping () -> Void) -> Void
    private let synchronize: (@escaping () -> Bool) -> Bool
    private let deliver: (@escaping () -> Void) -> Void
    private let notifications: NotificationCenter
    private let workspaceNotifications: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var snapshotWork: DispatchWorkItem?
    private var snapshotInFlight = false
    private var snapshotRequested = false
    private var hasSnapshot = false
    private var snapshotSkipped = false
    private var snapshotNeedsInventory = false
    private var lastOffsets: Offsets?
    private var sections: [String: MenuBarSection] = [:]
    private var hidden = Set<String>()
    private var collapsed = false
    private var alwaysHiddenShown = true
    private var separatorFrame: CGRect?
    private var alwaysHiddenFrame: CGRect?
    private var arrangementValid = false
    private var alwaysHiddenPlaced = false
    private var alwaysHiddenPlacementKnown = false
    private var availabilityChecked = false
    private(set) var needsFileAccess = false
    private var revision = 0
    private var settledSnapshotNeeded = false

    // The mailbox is shared with the writer; everything else above is main-thread state.
    private let lock = NSLock()
    private var pending: Write?
    private var writerRunning = false
    private var stopped = false

    init(items: MenuBarItemProvider,
         bridge: NativeVisibilityProviding = MenuBarAllowListBridge.shared,
         inventory: MenuBarInventoryProviding = AccessibilityMenuBarInventory(),
         ownBundle: String = Bundle.main.bundleIdentifier ?? "com.dwarvesv.minimalbar",
         frame: @escaping (NSStatusItem) -> CGRect? = { $0.button?.window?.frame },
         isLTR: @escaping () -> Bool = { Constant.isUsingLTRLanguage },
         window: @escaping (NSStatusItem) -> AnyObject? = { $0.button?.window },
         notifications: NotificationCenter = .default,
         workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         schedule: @escaping Scheduler = { delay, body in
             let work = DispatchWorkItem(block: body)
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
             return work
         },
         queue: DispatchQueue = DispatchQueue(label: "com.dwarvesv.minimalbar.allow-list", qos: .userInitiated),
         enqueue: ((@escaping () -> Void) -> Void)? = nil,
         synchronize: ((@escaping () -> Bool) -> Bool)? = nil,
         deliver: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.items = items
        self.bridge = bridge
        self.inventory = inventory
        self.ownBundle = ownBundle
        self.frame = frame
        self.isLTR = isLTR
        self.window = window
        self.notifications = notifications
        self.workspaceNotifications = workspaceNotifications
        self.schedule = schedule
        self.enqueue = enqueue ?? { queue.async(execute: $0) }
        self.synchronize = synchronize ?? { queue.sync(execute: $0) }
        self.deliver = deliver
        observers.append(notifications.addObserver(forName: NSWindow.didMoveNotification, object: nil, queue: .main) { [weak self] note in
            guard let self = self, !self.collapsed, let items = self.items,
                  let moved = note.object as AnyObject?,
                  moved === self.window(items.separatorItem) || moved === self.window(items.toggleItem)
                    || moved === items.alwaysHiddenItem.flatMap(self.window) else { return }
            // AppKit moves our windows one at a time, so compare offsets after layout settles.
            self.requestSnapshot(after: 0.1, onlyIfOffsetsChanged: true)
        })
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(workspaceNotifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.applicationsChanged()
            })
        }
        requestSnapshot(after: 0)
    }

    deinit {
        snapshotWork?.cancel()
        observers.forEach(notifications.removeObserver)
        workspaceObservers.forEach(workspaceNotifications.removeObserver)
    }

    var isArrangementValid: Bool {
        if !collapsed { captureArrangement() }
        return arrangementValid
    }

    var isAlwaysHiddenSeparatorPlaced: Bool {
        if !collapsed { captureArrangement() }
        return items?.alwaysHiddenItem != nil && (!alwaysHiddenPlacementKnown || alwaysHiddenPlaced)
    }

    private func captureArrangement() {
        guard let items = items else { return }
        if items.separatorItem.isVisible, let boundary = frame(items.separatorItem), let arrow = frame(items.toggleItem) {
            separatorFrame = boundary
            arrangementValid = isLTR() ? boundary.midX < arrow.midX : boundary.midX > arrow.midX
        }
        if items.alwaysHiddenItem == nil {
            alwaysHiddenFrame = nil
            alwaysHiddenPlaced = false
            alwaysHiddenPlacementKnown = false
        } else if let item = items.alwaysHiddenItem, item.isVisible, let always = frame(item), let boundary = separatorFrame {
            alwaysHiddenFrame = always
            alwaysHiddenPlacementKnown = true
            alwaysHiddenPlaced = isLTR() ? always.midX < boundary.midX : always.midX > boundary.midX
        }
    }

    func apply(collapsed: Bool, alwaysHiddenShown: Bool) {
        captureArrangement()
        settledSnapshotNeeded = settledSnapshotNeeded || (self.collapsed && !collapsed)
            || (!self.alwaysHiddenShown && alwaysHiddenShown)
        self.collapsed = collapsed
        self.alwaysHiddenShown = alwaysHiddenShown
        updateOwnItems()
        if collapsed && !hasSnapshot && snapshotSkipped && !snapshotInFlight {
            snapshotSkipped = false
            requestSnapshot(after: 0)
        }
        // Availability may open a modal file picker, so it must not run in the click handler.
        deliver { [weak self] in self?.writeDesiredState() }
    }

    private func updateOwnItems() {
        items?.separatorItem.length = 20
        items?.alwaysHiddenItem?.length = 20
        // Unknown boundaries must get their first layout before they can disappear.
        // Until the first inventory lands the | also stays, because removing it shifts
        // the icons beside it and the inventory would classify them against a stale boundary.
        items?.separatorItem.isVisible = !collapsed || separatorFrame == nil || !hasSnapshot
        items?.alwaysHiddenItem?.isVisible = !alwaysHiddenPlacementKnown || (!collapsed && alwaysHiddenShown)
        lastOffsets = relativeOffsets()
    }

    private func relativeOffsets() -> Offsets? {
        guard let items = items, items.separatorItem.isVisible,
              let separator = frame(items.separatorItem), let arrow = frame(items.toggleItem) else { return nil }
        let always = items.alwaysHiddenItem.flatMap { item in
            item.isVisible ? frame(item).map { $0.midX - separator.midX } : nil
        }
        return Offsets(separatorToArrow: separator.midX - arrow.midX, alwaysHiddenToSeparator: always)
    }

    func invalidateLayout() { refreshArrangement() }
    func refreshArrangement() { requestSnapshot(after: 0.1) }

    func applicationsChanged() {
        guard !collapsed && hidden.isEmpty else { return }
        requestSnapshot(after: 0.1)
    }

    func requestAccess() {
        availabilityChecked = false
        bridge.requestAccess()
        writeDesiredState()
    }

    private func requestSnapshot(after delay: TimeInterval, onlyIfOffsetsChanged: Bool = false) {
        snapshotNeedsInventory = snapshotNeedsInventory || !onlyIfOffsetsChanged
        snapshotWork?.cancel()
        snapshotWork = schedule(delay) { [weak self] in
            guard let self = self else { return }
            self.snapshotWork = nil
            let offsets = self.relativeOffsets()
            let changed = offsets != self.lastOffsets
            self.lastOffsets = offsets
            guard self.snapshotNeedsInventory || changed else { return }
            self.snapshotNeedsInventory = false
            if self.snapshotInFlight {
                self.snapshotRequested = true
                return
            }
            self.captureArrangement()
            guard let boundary = self.separatorFrame,
                  self.items?.alwaysHiddenItem == nil || self.alwaysHiddenPlacementKnown else {
                self.snapshotSkipped = true
                return
            }
            guard self.inventory.isAuthorized else {
                self.snapshotSkipped = true
                self.inventory.requestAuthorization()
                return
            }
            self.snapshotSkipped = false
            self.updateOwnItems()
            let always = self.items?.alwaysHiddenItem == nil ? nil : self.alwaysHiddenFrame
            self.snapshotInFlight = true
            self.inventory.snapshot { [weak self] snapshot in
                guard let self = self else { return }
                self.snapshotInFlight = false
                let layout = MenuBarLayoutResolver.resolve(inventory: snapshot.items,
                    separatorFrame: boundary, alwaysHiddenSeparatorFrame: always,
                    isLTR: self.isLTR(), excludingBundle: self.ownBundle)
                var fresh = layout.sections.filter { !snapshot.unreadableBundles.contains($0.key) }
                // Hidden frames are stale even when AX still returns them.
                for bundle in self.hidden { fresh[bundle] = self.sections[bundle] }
                self.sections = fresh
                self.hasSnapshot = true
                self.updateOwnItems()
                self.writeDesiredState()
                if self.snapshotRequested {
                    self.snapshotRequested = false
                    self.requestSnapshot(after: 0.1)
                }
            }
        }
    }

    private func writeDesiredState() {
        lock.lock()
        let quitting = stopped
        lock.unlock()
        guard !quitting && hasSnapshot else { return }
        if !availabilityChecked {
            availabilityChecked = true
            needsFileAccess = !bridge.isAvailable
        }
        guard !needsFileAccess else {
            NSLog("AllowListEngine: Menu Bar settings file access needed")
            return
        }
        let wanted: Set<MenuBarSection> = collapsed ? [.hidden, .alwaysHidden]
            : (alwaysHiddenShown || items?.alwaysHiddenItem == nil ? [] : [.alwaysHidden])
        let desired = Set(sections.filter { wanted.contains($0.value) }.keys)
        let allowed = Set(sections.keys).subtracting(desired)
            .union([ownBundle]).union(MenuBarLayoutResolver.systemItemOwners).sorted()
        revision += 1
        let write = Write(revision: revision, hidden: desired, allowed: allowed)
        // Protect frames for both committed and queued hides until restoration finishes.
        hidden.formUnion(desired)
        lock.lock()
        pending = write
        let start = !writerRunning
        writerRunning = true
        lock.unlock()
        if start { enqueue { [weak self] in self?.drain() } }
    }

    private func drain() {
        lock.lock()
        guard !stopped, let write = pending else {
            writerRunning = false
            lock.unlock()
            return
        }
        pending = nil
        lock.unlock()
        if write.hidden.isEmpty {
            let restored = bridge.restoreAll()
            finished(write, succeeded: restored)
        } else {
            bridge.activate(allowedSystemItems: [], allowedBundleIdentifiers: write.allowed,
                            hiddenBundleIdentifiers: write.hidden) { [weak self] result in
                guard let self = self else { return }
                // The bridge is synchronous; enqueue also keeps injected deferred completions serialized.
                self.enqueue {
                    switch result {
                    case .success:
                        self.finished(write, succeeded: true)
                    case .failure(let error):
                        NSLog("AllowListEngine: write failed: %@", error.localizedDescription)
                        self.finished(write, succeeded: false)
                    }
                }
            }
        }
    }

    private func finished(_ write: Write, succeeded: Bool) {
        deliver { [weak self] in
            guard let self = self, write.revision == self.revision else { return }
            if succeeded { self.hidden = write.hidden }
            if succeeded && write.hidden.isEmpty && !self.collapsed && self.settledSnapshotNeeded {
                self.settledSnapshotNeeded = false
                self.requestSnapshot(after: 1.5)
            }
        }
        drain()
    }

    @discardableResult func restoreAll() -> Bool {
        snapshotWork?.cancel()
        lock.lock()
        stopped = true
        pending = nil
        lock.unlock()
        // Waiting for the serial writer here prevents a queued collapse from re-hiding after Quit.
        return synchronize { [self] in
            let restored = bridge.restoreAll()
            return restored
        }
    }
}
