//
//  StatusBarController.swift
//  vanillaClone
//
//  Created by Thanh Nguyen on 1/30/19.
//  Copyright © 2019 Dwarves Foundation. All rights reserved.
//

import AppKit
import ApplicationServices

class StatusBarController: MenuBarItemProvider {
    
    //MARK: - Variables
    private var timer:Timer? = nil

    //MARK: - BarItems

    private let btnExpandCollapse = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let btnSeparate = NSStatusBar.system.statusItem(withLength: 1)
    private var btnAlwaysHidden:NSStatusItem? = nil

    //MARK: - Notch Overflow
    private var notchOverflowController = NotchOverflowController()
    
    var toggleItem: NSStatusItem { btnExpandCollapse }
    var separatorItem: NSStatusItem { btnSeparate }
    var alwaysHiddenItem: NSStatusItem? { btnAlwaysHidden }
    
    // How hiding is achieved (separator lengths) lives in the engine; this class
    // owns the items, the UI, and when to collapse or expand.
    private lazy var menuBarEngine: MenuBarEngine = MenuBarEngineFactory.make(items: self)
    
    private let imgIconLine = NSImage(named:NSImage.Name("ic_line"))
    
    private var isCollapsed: Bool {
        return menuBarEngine.state == .collapsed
    }
    
    private var isBtnAlwaysHiddenValidPosition: Bool {
        if !Preferences.alwaysHiddenSectionEnabled { return true }
        return menuBarEngine.isAlwaysHiddenSeparatorPlaced
    }
    
    private var isToggle = false

    // Why the last collapse hid nothing, shown in the context menu and Settings
    // until a collapse succeeds. nil while hiding works.
    private(set) var hidingProblem: HidingUnavailableReason? {
        didSet {
            guard hidingProblem != oldValue else { return }
            NotificationCenter.default.post(name: .hidingStatusChanged, object: nil)
        }
    }

    // Menus of this app being tracked (the context menu, Notch Overflow). The
    // pointer can be anywhere while one is driven by the keyboard.
    private var trackedMenuCount = 0

    private var hoverMonitor: Any?
    private var hoverDwellTimer: Timer?

    // True while the pointer sits in any screen's menubar band (the strip between
    // visibleFrame.maxY and frame.maxY, which is the menubar's exact height there).
    // On fullscreen spaces the menubar is hidden and the band collapses to ~zero,
    // so this returns false there: intentional, no visible menubar = no deferral.
    private var isMouseInMenuBar: Bool {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.contains { screen in
            mouse.x >= screen.frame.minX && mouse.x <= screen.frame.maxX
                && mouse.y >= screen.visibleFrame.maxY && mouse.y <= screen.frame.maxY
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

    @objc private func menuBeganTracking() {
        trackedMenuCount += 1
    }

    @objc private func menuEndedTracking() {
        trackedMenuCount = max(0, trackedMenuCount - 1)
    }

    //MARK: - Methods
    init() {
        setupUI()
        restoreRemovedStatusItems()
        setupAlwayHideStatusBar()
        setupHoverToExpandIfEnabled()
        NotificationCenter.default.addObserver(self, selector: #selector(handleScreenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateAutoHide), name: .prefsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sectionOverridesChanged), name: .sectionOverridesChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuBeganTracking), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuEndedTracking), name: NSMenu.didEndTrackingNotification, object: nil)
        // Sections are read from where the items sit, so wait until macOS has put
        // them back in place before hiding the always-hidden section; read at
        // launch, the separator has no position yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if Preferences.areSeparatorsHidden { self?.hideSeparators() }
            self?.collapseMenuBar()
        }

        autoCollapseIfNeeded()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        hoverDwellTimer?.invalidate()
        if let monitor = hoverMonitor {
            NSEvent.removeMonitor(monitor)
        }
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
    
    // Settings can place apps in sections without ⌘-drag where the engine allows it.
    var supportsSectionAssignment: Bool {
        return menuBarEngine.supportsSectionAssignment
    }

    func readSections(completion: @escaping (MenuBarLayout?) -> Void) {
        menuBarEngine.readSections(completion: completion)
    }

    // A choice made in Settings takes effect right away, collapsed or not.
    @objc private func sectionOverridesChanged() {
        let wasCollapsed = isCollapsed
        menuBarEngine.reapplySections { [weak self] succeeded in
            guard let self = self, wasCollapsed, !succeeded else { return }
            self.hidingProblem = self.menuBarEngine.unavailableReason ?? .activationFailed
            self.didFailToCollapseMenuBar()
        }
    }

    @objc private func handleScreenParametersChanged() {
        // The engine re-applies recomputed lengths to the LIVE items, or a
        // display hot-plug leaves them at a stale length (PR #354).
        menuBarEngine.invalidateLayout()
    }
    
    private func restoreRemovedStatusItems() {
        // Cmd-dragging a status item off the bar is persisted by macOS via
        // autosaveName, leaving the app running but unreachable. These items are
        // the app's only UI, so they self-restore at launch.
        btnExpandCollapse.isVisible = true
        btnSeparate.isVisible = true
        // Create the engine now so one that does not use the separator (macOS 27
        // native hiding) takes it back out before it is ever drawn.
        _ = menuBarEngine
    }

    private func setupUI() {
        if let button = btnSeparate.button {
            button.image = self.imgIconLine
            button.setAccessibilityLabel("Hidden Bar Menu".localized)
            button.target = self
            button.action = #selector(self.showContextMenuFromSeparator(sender:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        if let button = btnExpandCollapse.button {
            button.target = self
            button.setAccessibilityHelp("With the always-hidden section on, right-click shows or hides it. Option-click opens the Hidden Bar menu.".localized)
            
            button.action = #selector(self.btnExpandCollapsePressed(sender:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        showToggle(collapsed: false)
        btnExpandCollapse.autosaveName = "hiddenbar_expandcollapse";
        btnSeparate.autosaveName = "hiddenbar_separate";
    }
    
    @objc func btnExpandCollapsePressed(sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        // AXPress synthesis carries no NSEvent; the resolver maps nil to .toggle
        // so VoiceOver can operate the bar.
        let modifiers = ExpandCollapseActionResolver.modifiers(eventFlags: event?.modifierFlags, liveFlags: NSEvent.modifierFlags)
        switch ExpandCollapseActionResolver.action(eventType: event?.type, modifiers: modifiers, alwaysHiddenSectionEnabled: Preferences.alwaysHiddenSectionEnabled) {
        case .toggle:
            self.expandCollapseIfNeeded()
        case .contextMenu:
            // The same context menu the separator has, so settings stay
            // reachable on macOS 27, where the separator is gone.
            showContextMenu(from: sender)
        case .toggleSeparators:
            self.showHideSeparatorsAndAlwayHideArea()
        }
    }

    @objc private func showContextMenuFromSeparator(sender: NSStatusBarButton) {
        showContextMenu(from: sender)
    }

    // Builds a brand-new NSMenu for every presentation rather than mutating
    // a reused one via a delegate callback (content changes on an
    // already-displayed-before NSMenu instance could leave its backing
    // window at a stale size until an unrelated redraw corrected it).
    //
    // Uses popUp(at:), not performClick(nil): this method is ITSELF called
    // from this same button's own action handler (a real click already in
    // progress). performClick(nil) here re-entered NSStatusBarButtonCell's
    // own sendAction dispatch, recursing into this handler again and
    // stack-overflowing (SIGSEGV, confirmed via crash report) - unlike
    // NotchOverflowController.showOverflowMenuFromSeparator, which is safe
    // because it's invoked from a *different* control's action (a menu
    // item), not from btnExpandCollapse's own click handler.
    //
    // Previously anchored at `button.bounds.maxY + 5` (5pt above the
    // button's TOP edge). For a menu-bar item that's essentially the
    // physical top of the screen, so once "Show Notch Items" made the menu
    // one row taller, that top row landed in the sliver above the visible
    // screen and AppKit showed its standard "content doesn't fit here"
    // scroll-indicator caret instead of rendering it - hovering over the
    // indicator scrolled the whole menu into view, which is what looked
    // like the item "appearing on hover". Anchoring at the button's BOTTOM
    // edge instead (y: 0, not bounds.maxY) keeps the menu entirely within
    // on-screen space, growing downward from below the button.
    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = getContextMenu()
        // Anchored in screen coordinates (in: nil) at the item's bottom-left, so
        // the menu always grows downward from under the item. Anchored in the
        // button instead, a menu with the hiding-problem rows was placed with its
        // first row in the sliver behind the menu bar, where AppKit replaces it
        // with a scroll caret (measured: first row at y=1 under a 30pt menu bar).
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

    func showHideSeparatorsAndAlwayHideArea() {
        Preferences.areSeparatorsHidden ? self.showSeparators() : self.hideSeparators()
        
        if self.isCollapsed {self.expandMenubar()}
    }
    
    private func showSeparators() {
        Preferences.areSeparatorsHidden = false
        
        if !self.isCollapsed {
            menuBarEngine.expand()
        }
        menuBarEngine.updateAlwaysHiddenSection(enabled: Preferences.alwaysHiddenSectionEnabled, separatorHidden: false)
    }
    
    private func hideSeparators() {
        guard self.isBtnAlwaysHiddenValidPosition else {return}
        
        Preferences.areSeparatorsHidden = true
        
        if !self.isCollapsed {
            menuBarEngine.expand()
        }
        menuBarEngine.updateAlwaysHiddenSection(enabled: Preferences.alwaysHiddenSectionEnabled, separatorHidden: true)
    }
    
    func expandCollapseIfNeeded() {
        //prevented rapid click cause icon show many in Dock
        if isToggle {return}
        isToggle = true
        self.isCollapsed ? self.expandMenubar() : self.collapseMenuBar()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isToggle = false
        }
    }
    
    private func collapseMenuBar() {
        guard menuBarEngine.isArrangementValid && !self.isCollapsed else {
            autoCollapseIfNeeded()
            return
        }

        menuBarEngine.collapse { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .collapsed:
                self.hidingProblem = nil
                self.didCollapseMenuBar()
            case .unavailable:
                self.hidingProblem = self.menuBarEngine.unavailableReason ?? .activationFailed
                self.didFailToCollapseMenuBar()
            }
        }
    }

    // Nothing was hidden (the engine cannot hide on this system, or is waiting for
    // a permission), so show the bar as expanded, and restore the activation
    // policy in case the UI had already switched to collapsed.
    private func didFailToCollapseMenuBar() {
        showToggle(collapsed: false)
        if Preferences.useFullStatusBarOnExpandEnabled {
            NSApp.setActivationPolicy(.regular)
        }
    }

    private func didCollapseMenuBar() {
        showToggle(collapsed: true)
        if Preferences.useFullStatusBarOnExpandEnabled {
            NSApp.setActivationPolicy(.accessory)
            NSApp.deactivate()
        }
    }

    private func expandMenubar() {
        guard self.isCollapsed else {return}
        menuBarEngine.expand()
        showToggle(collapsed: false)
        autoCollapseIfNeeded()
        
        if Preferences.useFullStatusBarOnExpandEnabled {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            
        }
    }
    
    private func autoCollapseIfNeeded() {
        guard Preferences.isAutoHide else {return}
        guard !isCollapsed else { return }

        startTimerToAutoHide()
    }

    private func startTimerToAutoHide() {
        timer?.invalidate()
        self.timer = Timer.scheduledTimer(withTimeInterval: Preferences.numberOfSecondForAutoHide, repeats: false) { [weak self] _ in
            guard let self = self, Preferences.isAutoHide else { return }
            // Don't yank the bar shut mid-interaction: while the pointer is in the
            // menubar (hovering, clicking, dragging icons), a menu is open, or the
            // keyboard or VoiceOver is moving through the menu bar, defer and re-arm.
            // Intentionally unbounded; each re-arm invalidates the previous timer,
            // so deferral never accumulates timers.
            if self.isMouseInMenuBar || self.isPreferencesWindowVisible
                || self.trackedMenuCount > 0 || self.isMenuBarNavigationActive {
                self.startTimerToAutoHide()
            } else {
                self.collapseMenuBar()
            }
        }
    }
    
    // Built fresh on every call (see showContextMenu(from:)), so every field
    // below reflects state as of THIS presentation - no separate "patch the
    // title after the fact" step is needed for the auto-collapse item.
    private func getContextMenu() -> NSMenu {
        let menu = NSMenu()

        // Say why the bar does not hide, with the way to fix it, instead of
        // leaving the arrow to look broken.
        if let problem = hidingProblem {
            let reasonItem = NSMenuItem(title: Self.describe(problem), action: nil, keyEquivalent: "")
            reasonItem.isEnabled = false
            menu.addItem(reasonItem)
            let fixItem = problem == .accessibilityNeeded
                ? NSMenuItem(title: "Open Accessibility Settings…".localized, action: #selector(openAccessibilitySettings), keyEquivalent: "")
                : NSMenuItem(title: "Try Hiding Again".localized, action: #selector(retryHiding), keyEquivalent: "")
            fixItem.target = self
            menu.addItem(fixItem)
            menu.addItem(NSMenuItem.separator())
        }

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

    static func describe(_ problem: HidingUnavailableReason) -> String {
        switch problem {
        case .notSupported:
            return "Icons can't be hidden: this build can't hide them on this version of macOS.".localized
        case .accessibilityNeeded:
            return "Icons can't be hidden: Hidden Bar needs the Accessibility permission.".localized
        case .boundaryUnreadable:
            return "Icons can't be hidden yet: the arrow's position can't be read.".localized
        case .activationFailed:
            return "Icons can't be hidden: macOS didn't allow it.".localized
        }
    }

    @objc func openAccessibilitySettings() {
        Util.openAccessibilitySettings()
    }

    // Collapses again, which clears the problem once hiding works.
    @objc func retryHiding() {
        if isCollapsed {
            hidingProblem = nil
        } else {
            collapseMenuBar()
        }
    }

    @objc func updateAutoHide() {
        autoCollapseIfNeeded()
    }
    
    @objc func openPreferenceViewControllerIfNeeded() {
        Util.showPrefWindow()
    }

    @objc func showNotchOverflow() {
        notchOverflowController.showOverflowMenuFromSeparator(near: btnExpandCollapse)
    }
    
    @objc func toggleAutoHide() {
        Preferences.isAutoHide.toggle()
    }
}


//MARK: - Alway hide feature
extension StatusBarController {
    private func setupAlwayHideStatusBar() {
        NotificationCenter.default.addObserver(self, selector: #selector(alwaysHiddenSectionToggled), name: .alwayHideToggle, object: nil)
        toggleStatusBarIfNeeded()
    }

    // Turning the section on shows its separator so it can be ⌘-dragged into
    // place; the saved "hide separators" state is reset to match, or the next
    // right-click would only flip the preference and appear to do nothing.
    @objc private func alwaysHiddenSectionToggled() {
        if Preferences.alwaysHiddenSectionEnabled {
            Preferences.areSeparatorsHidden = false
        }
        toggleStatusBarIfNeeded()
    }

    private func toggleStatusBarIfNeeded() {
        if Preferences.alwaysHiddenSectionEnabled {
            if let existing = self.btnAlwaysHidden {
                NSStatusBar.system.removeStatusItem(existing)
            }
            self.btnAlwaysHidden = NSStatusBar.system.statusItem(withLength: 0)
            if let button = btnAlwaysHidden?.button {
                button.image = self.imgIconLine
                button.appearsDisabled = true
                button.setAccessibilityLabel("Hidden Bar Menu".localized)
                // On macOS 27 this is the only separator left in the bar, so it
                // opens the context menu like the regular separator does;
                // without an action, clicking it did nothing. Right-mouse-up
                // must be in the mask too, or a right-click is not delivered.
                button.target = self
                button.action = #selector(self.showContextMenuFromSeparator(sender:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            self.btnAlwaysHidden?.autosaveName = "hiddenbar_terminate"
            self.btnAlwaysHidden?.isVisible = true
            // Last, so the engine decides the new item's width.
            menuBarEngine.updateAlwaysHiddenSection(enabled: true, separatorHidden: false)
        } else {
            if let existing = self.btnAlwaysHidden {
                NSStatusBar.system.removeStatusItem(existing)
            }
            self.btnAlwaysHidden = nil
            // The engine must forget the section too, or macOS 27 keeps hiding
            // its apps while expanded after the section is switched off.
            menuBarEngine.updateAlwaysHiddenSection(enabled: false, separatorHidden: Preferences.areSeparatorsHidden)
        }
    }
}
