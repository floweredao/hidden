//
//  AppDelegate.swift
//  vanillaClone
//
//  Created by Thanh Nguyen on 1/24/19.
//  Copyright © 2019 Dwarves Foundation. All rights reserved.
//

import AppKit
import HotKey
import ServiceManagement
#if HIDDENBAR_UPDATER
import OSLog
import Sparkle
#endif

@NSApplicationMain

class AppDelegate: NSObject, NSApplicationDelegate{
    
    // Created in applicationDidFinishLaunching, after the defaults and the layout
    // direction it reads are in place and only in the instance that stays.
    private(set) var statusBarController: StatusBarController!

    #if HIDDENBAR_UPDATER
    // The fork's own updater: checks floweredao/hidden's appcast (SUFeedURL) and
    // installs only archives signed with the fork's EdDSA key (SUPublicEDKey).
    // Started in applicationDidFinishLaunching, only in the instance that stays.
    // SUVerifyUpdateBeforeExtraction makes the EdDSA signature mandatory before an
    // archive is even unpacked, so a code-signing match alone can never replace it.
    private let updaterDelegate = UpdaterDelegate()
    private let userDriverDelegate = UpdaterUserDriverDelegate()
    private(set) lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: updaterDelegate, userDriverDelegate: userDriverDelegate)
    #endif

    var hotKey: HotKey? {
        didSet {
            guard let hotKey = hotKey else { return }

            hotKey.keyDownHandler = { [weak self] in
                self?.statusBarController.expandCollapseIfNeeded()
            }
        }
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        guard ensureSingleInstance() else { return }
        registerDefaultValues()
        detectLTRLang()
        statusBarController = StatusBarController()
        setupAutoStartApp()
        setupHotKey()
        #if HIDDENBAR_UPDATER
        updaterController.startUpdater()
        #endif
        openPreferencesIfNeeded()
    }

    // Opening the app again (Finder, Spotlight, Launchpad) shows Preferences, so
    // settings stay reachable without the context menu.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Util.showPrefWindow()
        return true
    }

    /// Hidden Bar is a menu bar utility with no visible window, so launching it a
    /// second time looks like a no-op while silently spawning a duplicate instance.
    /// If another instance with the same bundle ID is already running, activate it
    /// and terminate this one instead.
    private func ensureSingleInstance() -> Bool {
        let current = ProcessInfo.processInfo.processIdentifier
        let existing = NSWorkspace.shared.runningApplications.first {
            guard $0.bundleIdentifier == Bundle.main.bundleIdentifier,
                  $0.processIdentifier != current else { return false }
            #if DEBUG
            // Let a dev build run next to the installed copy; only dedupe
            // relaunches of the same bundle path.
            return $0.bundleURL == Bundle.main.bundleURL
            #else
            return true
            #endif
        }
        guard let existing else { return true }
        existing.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)
        return false
    }
    
    func openPreferencesIfNeeded() {
        if Preferences.isShowPreference {
            Util.showPrefWindow()
        }
    }
    
    func setupAutoStartApp() {
        removeLegacyLauncherLoginItem()
        Util.setUpAutoStart(isAutoStart: Preferences.isAutoStart)
    }

    private func removeLegacyLauncherLoginItem() {
        // Builds before the SMAppService migration registered a helper app in BTM;
        // macOS never garbage-collects that record (TN3111), so deauthorize it once.
        let migratedKey = "smAppServiceMigrated"
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        SMLoginItemSetEnabled("com.dwarvesv.LauncherApplication" as CFString, false)
        UserDefaults.standard.set(true, forKey: migratedKey)
    }
    
    // A plain value, separate from the side-effecting `register(defaults:)`
    // call, so the "what are the defaults" behavior is testable without
    // spinning up an AppDelegate (which creates real status bar items).
    static let defaultPreferenceValues: [String: Any] = [
        UserDefaults.Key.isAutoStart: false,
        UserDefaults.Key.isShowPreference: true,
        UserDefaults.Key.isAutoHide: true,
        UserDefaults.Key.numberOfSecondForAutoHide: 10.0,
        UserDefaults.Key.areSeparatorsHidden: false,
        UserDefaults.Key.alwaysHiddenSectionEnabled: false,
        UserDefaults.Key.notchOverflowEnabled: true,
        UserDefaults.Key.showsSystemIndicatorsWhenExpanded: true
    ]

    func registerDefaultValues() {
        UserDefaults.standard.register(defaults: AppDelegate.defaultPreferenceValues)
    }
    
    func setupHotKey() {
        guard let globalKey = Preferences.globalKey else {return}
        hotKey = HotKey(keyCombo: KeyCombo(carbonKeyCode: globalKey.keyCode, carbonModifiers: globalKey.carbonFlags))
    }
    
    func detectLTRLang() {
        // Languages like Arabic uses right to left (RTL) writing direction,
        // so some behavier of the app needs to be changed in these cases
        
        Constant.isUsingLTRLanguage = (NSApplication.shared.userInterfaceLayoutDirection == .leftToRight)
    }
   
}

#if HIDDENBAR_UPDATER
/// Logs the updater's milestones (`log stream --predicate 'subsystem == "com.dwarvesv.minimalbar" && category == "updater"'`)
/// so a release can be checked end to end without watching the screen.
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private let log = Logger(subsystem: "com.dwarvesv.minimalbar", category: "updater")

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        log.notice("appcast loaded: \(appcast.items.count, privacy: .public) item(s)")
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        log.notice("update found: \(item.versionString, privacy: .public) (\(item.displayVersionString, privacy: .public))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        log.notice("no update: up to date")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        log.notice("ready to install on quit: \(item.versionString, privacy: .public)")
        return false
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        log.error("update aborted: \(error.localizedDescription, privacy: .public)")
    }
}

/// Hidden Bar runs as a menu-bar agent (LSUIElement) with no window to sit
/// behind, so Sparkle's scheduled "update available" alert is brought to the
/// front when it appears instead of opening unseen behind other apps.
final class UpdaterUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate && !state.userInitiated {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
#endif
