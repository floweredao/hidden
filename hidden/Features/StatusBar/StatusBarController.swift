import AppKit
import ApplicationServices
import os.log

final class StatusBarController: MenuBarItemProvider {
    private var timer: Timer?
    private var launchTimer: Timer?
    private var hoverMonitor: Any?
    private var hoverDwellTimer: Timer?
    private let btnExpandCollapse = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let btnSeparate = NSStatusBar.system.statusItem(withLength: 20)
    private var btnAlwaysHidden: NSStatusItem?
    private var notchOverflowController = NotchOverflowController()
    private let imgIconLine = NSImage(named: NSImage.Name("ic_line"))
    var toggleItem: NSStatusItem { btnExpandCollapse }
    var separatorItem: NSStatusItem { btnSeparate }
    var alwaysHiddenItem: NSStatusItem? { btnAlwaysHidden }
    private lazy var menuBarEngine = MenuBarEngineFactory.make(items: self)
    private lazy var state = MenuBarStateMachine(engine: menuBarEngine,
        alwaysHiddenShown: !Preferences.areSeparatorsHidden) { [weak self] collapsed, shown in
            self?.showToggle(collapsed: collapsed)
            Preferences.areSeparatorsHidden = !shown
        }
    private var isCollapsed: Bool { state.isCollapsed }
    private var menuTracking = OwnedMenuTracking()
    private weak var presentedContextMenu: NSMenu?
    private var autoCollapseDeferral = AutoCollapseDeferral()
    private static let autoCollapseLog = OSLog(subsystem: "com.dwarvesv.minimalbar", category: "AutoCollapse")
    // True while the pointer sits in any screen's menubar band (the strip between
    // visibleFrame.maxY and frame.maxY, which is the menubar's exact height there).
    // On fullscreen spaces the menubar is hidden and the band collapses to ~zero,
    // so this returns false there: intentional, no visible menubar = no deferral.
    private var isMouseInMenuBar: Bool {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.contains { screen in
            mouse.x >= screen.frame.minX && mouse.x <= screen.frame.maxX
                && mouse.y >= MenuBarBand.minY(frame: screen.frame, visibleFrame: screen.visibleFrame, thickness: NSStatusBar.system.thickness)
                && mouse.y <= screen.frame.maxY
        }
    }

    // The preferences window is an ordinary app window, not in the menu bar, so
    // the mouse-in-menubar guard does not cover it. With "use full menu bar on
    // expanding" on, an auto-collapse deactivates the app and dismisses this
    // window mid-edit (#170, same family as #66/#151). Defer the collapse while
    // it is on screen. isWindowLoaded short-circuits without force-loading the
    // window when preferences were never opened.
    private var isPreferencesWindowVisible: Bool {
        guard let wc = PreferencesWindowController.existing else { return false }
        return wc.isWindowLoaded && (wc.window?.isVisible ?? false)
            && (wc.window?.isKeyWindow ?? false)
    }
    
    // Keyboard (Control-F8, or VoiceOver's menu extras) is in the menu bar or
    // one of its menus: the focused element anywhere is a menu-bar item or a
    // menu. Needs Accessibility; without it only the pointer and this app's own
    // menus defer the collapse.
    private var isMenuBarNavigationActive: Bool {
        guard AXIsProcessTrusted() else { return false }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.1)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element as! AXUIElement, kAXRoleAttribute as CFString, &role)
        let menuRoles: Set<String> = [kAXMenuBarRole, kAXMenuBarItemRole, kAXMenuRole, kAXMenuItemRole, "AXMenuExtra"]
        return (role as? String).map(menuRoles.contains) ?? false
    }

    @objc private func menuBeganTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        var root = menu
        while let parent = root.supermenu { root = parent }
        let owned = root === presentedContextMenu || root === btnExpandCollapse.menu
            || root === btnSeparate.menu || root === btnAlwaysHidden?.menu
        menuTracking.began(menu, owned: owned)
    }

    @objc private func menuEndedTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        menuTracking.ended(menu)
    }


    init() {
        setupUI()
        btnExpandCollapse.isVisible = true
        btnSeparate.isVisible = true
        updateAlwaysHiddenItem()
        setupHoverToExpandIfEnabled()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleScreenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        center.addObserver(self, selector: #selector(updateAutoHide), name: .prefsChanged, object: nil)
        center.addObserver(self, selector: #selector(alwaysHiddenSectionToggled), name: .alwayHideToggle, object: nil)
        center.addObserver(self, selector: #selector(menuBeganTracking(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(menuEndedTracking(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
        state.synchronize()
        launchTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            self?.collapseMenuBar()
        }
        autoCollapseIfNeeded()
    }

    deinit {
        timer?.invalidate()
        launchTimer?.invalidate()
        hoverDwellTimer?.invalidate()
        if let monitor = hoverMonitor { NSEvent.removeMonitor(monitor) }
        NotificationCenter.default.removeObserver(self)
    }

    // Opt-in via `defaults write com.dwarvesv.minimalbar hoverToExpand -bool true`.
    // No monitor is installed at all unless the pref is true at launch.
    private func setupHoverToExpandIfEnabled() {
        guard Preferences.hoverToExpand else { return }
        NSLog("HoverToExpand: enabled, installing global mouse monitor")
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self = self else { return }
            guard self.isCollapsed && self.isMouseInMenuBar else {
                self.hoverDwellTimer?.invalidate()
                self.hoverDwellTimer = nil
                return
            }
            // Short dwell so a pointer merely passing through doesn't expand.
            guard self.hoverDwellTimer == nil else { return }
            self.hoverDwellTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.hoverDwellTimer = nil
                if self.isCollapsed && self.isMouseInMenuBar {
                    self.expandMenubar()
                }
            }
        }
    }
    

    private func expandMenubar() {
        guard isCollapsed else { return }
        perform(.toggle)
    }

    private func setupUI() {
        configureSeparator(btnSeparate)
        if let button = btnExpandCollapse.button {
            button.target = self
            button.action = #selector(btnExpandCollapsePressed(sender:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        showToggle(collapsed: false)
        btnExpandCollapse.autosaveName = "hiddenbar_expandcollapse"
        btnSeparate.autosaveName = "hiddenbar_separate"
    }

    private func configureSeparator(_ item: NSStatusItem) {
        guard let button = item.button else { return }
        button.image = imgIconLine
        button.setAccessibilityLabel("Hidden Bar Menu".localized)
        button.target = self
        button.action = #selector(showContextMenuFromSeparator(sender:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc func btnExpandCollapsePressed(sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let flags = ExpandCollapseActionResolver.modifiers(eventFlags: event?.modifierFlags, liveFlags: NSEvent.modifierFlags)
        perform(ExpandCollapseActionResolver.action(eventType: event?.type, modifiers: flags,
            alwaysHiddenSectionEnabled: Preferences.alwaysHiddenSectionEnabled))
    }

    @objc private func showContextMenuFromSeparator(sender: NSStatusBarButton) {
        showContextMenu(from: sender)
    }

    // A fresh menu avoids stale AppKit sizing; popUp avoids re-entering this button action.
    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = getContextMenu()
        presentedContextMenu = menu
        defer {
            menuTracking.ended(menu)
            presentedContextMenu = nil
        }
        // Anchoring below the bar keeps the first row out of AppKit's scroll-caret region.
        if let frame = button.window?.frame {
            menu.popUp(positioning: nil, at: NSPoint(x: frame.minX, y: frame.minY), in: nil)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)
        }
    }
    
    // The arrow is an image only, so VoiceOver gets a name for what pressing it
    // does; it changes with the state, so the new state is read after a toggle.
    private func showToggle(collapsed: Bool) {
        guard let button = btnExpandCollapse.button else { return }
        button.image = collapsed ? Assets.expandImage : Assets.collapseImage
        button.setAccessibilityLabel(collapsed
            ? "Show Hidden Menu Bar Icons".localized
            : "Hide Menu Bar Icons".localized)
    }


    func expandCollapseIfNeeded() { perform(.toggle) }

    private func perform(_ action: ExpandCollapseAction) {
        guard state.perform(action, alwaysHiddenEnabled: Preferences.alwaysHiddenSectionEnabled) else { return }
        didChangeState()
    }

    private func collapseMenuBar() {
        guard state.collapse() else { return }
        didChangeState()
    }

    private func didChangeState() {
        autoCollapseIfNeeded()
        if Preferences.useFullStatusBarOnExpandEnabled {
            NSApp.setActivationPolicy(isCollapsed ? .accessory : .regular)
            if isCollapsed { NSApp.deactivate() }
            else { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    @objc private func handleScreenParametersChanged() { menuBarEngine.invalidateLayout() }
    func refreshArrangement() { menuBarEngine.refreshArrangement() }
    @discardableResult func restoreAll() -> Bool { menuBarEngine.restoreAll() }

    @objc private func alwaysHiddenSectionToggled() {
        updateAlwaysHiddenItem()
        state.alwaysHiddenSectionToggled()
        menuBarEngine.refreshArrangement()
    }

    private func updateAlwaysHiddenItem() {
        if Preferences.alwaysHiddenSectionEnabled && btnAlwaysHidden == nil {
            let item = NSStatusBar.system.statusItem(withLength: 20)
            configureSeparator(item)
            item.button?.appearsDisabled = true
            item.autosaveName = "hiddenbar_terminate"
            item.isVisible = true
            btnAlwaysHidden = item
        } else if !Preferences.alwaysHiddenSectionEnabled, let item = btnAlwaysHidden {
            NSStatusBar.system.removeStatusItem(item)
            btnAlwaysHidden = nil
        }
    }

    private func autoCollapseIfNeeded() {
        timer?.invalidate()
        guard Preferences.isAutoHide, !isCollapsed else { return }

        autoCollapseDeferral = AutoCollapseDeferral()
        startTimerToAutoHide()
    }

    private func startTimerToAutoHide() {
        timer?.invalidate()
        let interval = max(1, Preferences.numberOfSecondForAutoHide)
        os_log("Scheduled in %{public}.1f seconds", log: Self.autoCollapseLog, type: .info, interval)
        let next = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            guard Preferences.isAutoHide else {
                os_log("Cancelled: preference disabled", log: Self.autoCollapseLog, type: .info)
                return
            }
            guard !self.isCollapsed else {
                os_log("Deferred: engine not expanded", log: Self.autoCollapseLog, type: .info)
                return
            }
            let navigation = self.isMenuBarNavigationActive
            let reasons = self.autoCollapseDeferral.reasons(
                now: ProcessInfo.processInfo.systemUptime, mouseInMenuBar: self.isMouseInMenuBar,
                preferencesEditing: self.isPreferencesWindowVisible, ownedMenuTracking: self.menuTracking.isTracking,
                menuBarNavigation: navigation,
                recentKeyboardInput: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 2)
            for reason in reasons {
                os_log("Deferred: %{public}@", log: Self.autoCollapseLog, type: .info, reason.rawValue)
            }
            if !reasons.isEmpty {
                self.startTimerToAutoHide()
            } else {
                if navigation || self.menuTracking.isTracking {
                    os_log("Expired stale menu/navigation deferral", log: Self.autoCollapseLog, type: .info)
                }
                os_log("Collapsing", log: Self.autoCollapseLog, type: .info)
                self.collapseMenuBar()
            }
        }
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }
    

    private func getContextMenu() -> NSMenu {
        let menu = NSMenu()
        #if HIDDENBAR_NATIVE_VISIBILITY
        if let engine = menuBarEngine as? AllowListEngine, engine.needsFileAccess {
            let access = NSMenuItem(title: "Grant Access…".localized, action: #selector(grantAccess), keyEquivalent: "")
            access.target = self
            menu.addItem(access)
            menu.addItem(.separator())
        }
        #endif
        // Notch overflow menu item (only on notch Macs, and only when enabled)
        if NotchOverflowController.hasNotch && Preferences.notchOverflowEnabled {
            let overflowItem = NSMenuItem(title: "Show Notch Items".localized, action: #selector(showNotchOverflow), keyEquivalent: "")
            overflowItem.target = self
            menu.addItem(overflowItem)
            menu.addItem(NSMenuItem.separator())
        }

        let prefItem = NSMenuItem(title: "Preferences...".localized, action: #selector(openPreferenceViewControllerIfNeeded), keyEquivalent: "P")
        prefItem.target = self
        menu.addItem(prefItem)

        let toggleAutoHideTitle = Preferences.isAutoHide ? "Disable Auto Collapse" : "Enable Auto Collapse"
        let toggleAutoHideItem = NSMenuItem(title: toggleAutoHideTitle.localized, action: #selector(toggleAutoHide), keyEquivalent: "t")
        toggleAutoHideItem.target = self
        menu.addItem(toggleAutoHideItem)

        #if HIDDENBAR_UPDATER
        if let updater = (NSApp.delegate as? AppDelegate)?.updaterController {
            let updateItem = NSMenuItem(title: "Check for Updates…".localized, action: #selector(updater.checkForUpdates(_:)), keyEquivalent: "")
            updateItem.target = updater
            menu.addItem(updateItem)
        }
        #endif

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit".localized, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }


    @objc func grantAccess() {
        #if HIDDENBAR_NATIVE_VISIBILITY
        (menuBarEngine as? AllowListEngine)?.requestAccess()
        #endif
    }
    @objc func updateAutoHide() { autoCollapseIfNeeded() }
    @objc func openPreferenceViewControllerIfNeeded() { Util.showPrefWindow() }
    @objc func showNotchOverflow() {
        notchOverflowController.showOverflowMenuFromSeparator(near: btnExpandCollapse)
    }
    @objc func toggleAutoHide() { Preferences.isAutoHide.toggle() }
}
