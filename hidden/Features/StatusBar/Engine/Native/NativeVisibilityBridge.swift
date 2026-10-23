//
//  NativeVisibilityBridge.swift
//  Hidden Bar
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit

// A held native visibility restriction. Hiding lasts until invalidate() or until
// this process exits, when macOS drops it and restores the bar by itself.
protocol NativeVisibilityAssertion: AnyObject {
    func invalidate()
}

protocol NativeVisibilityProviding: AnyObject {
    var isAvailable: Bool { get }

    // Keeps only these system items and apps visible. The completion runs on the
    // main queue.
    func activate(allowedSystemItems: [Int],
                  allowedBundleIdentifiers: [String],
                  completion: @escaping (Result<NativeVisibilityAssertion, Error>) -> Void)
}

final class NativeVisibilityBridge: NativeVisibilityProviding {
    var isAvailable: Bool {
        return HBNativeVisibilityIsAvailable()
    }

    func activate(allowedSystemItems: [Int],
                  allowedBundleIdentifiers: [String],
                  completion: @escaping (Result<NativeVisibilityAssertion, Error>) -> Void) {
        HBNativeVisibilityActivate(allowedSystemItems.map { NSNumber(value: $0) },
                                   allowedBundleIdentifiers) { handle, error in
            if let handle = handle {
                completion(.success(Handle(raw: handle)))
            } else {
                completion(.failure(error ?? NSError(domain: "HBNativeVisibility", code: 2)))
            }
        }
    }

    private final class Handle: NativeVisibilityAssertion {
        private var raw: Any?

        init(raw: Any) {
            self.raw = raw
        }

        func invalidate() {
            guard let raw = raw else { return }
            self.raw = nil
            HBNativeVisibilityInvalidate(raw)
        }

        deinit {
            invalidate()
        }
    }
}

// macOS 27 hiding through the per-app "Allow in the Menu Bar" switches of
// System Settings › Menu Bar, which MenuBarAgent reads from Control Center's
// preferences. Unlike the assessment-mode restriction, these switches leave the
// Focus icon, the mic/camera capsule, Now Playing and Live Activities alone.
// MenuBarAgent reads them only when it starts, so every change restarts it
// (launchd brings it back in under a second and the bar redraws).
//
// Only running apps that are already tracked there and not allowed are
// switched off. Their previous values are kept in Hidden Bar's preferences
// until restored, so a crash or a quit while collapsed is undone at the next
// launch (restoreAfterUnexpectedExit).
final class MenuBarAllowListBridge: NativeVisibilityProviding {
    static let shared = MenuBarAllowListBridge()

    private static let savedValuesKey = "allowInMenuBarSavedValues"
    private static let bookmarkKey = "allowInMenuBarFileBookmark"

    private let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist")
    // macOS protects other apps' data: until the user picks the file once in an
    // open panel, reading it is refused. The pick is kept as a bookmark.
    private var askedThisSession = false
    private let defaults: UserDefaults
    private let runningBundleIdentifiers: () -> Set<String>
    private weak var current: Handle?

    init(defaults: UserDefaults = .standard,
         runningBundleIdentifiers: @escaping () -> Set<String> = { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }) {
        self.defaults = defaults
        self.runningBundleIdentifiers = runningBundleIdentifiers
    }

    var isAvailable: Bool {
        if (try? readTracked()) != nil { return true }
        guard !askedThisSession, Thread.isMainThread else { return false }
        askedThisSession = true
        return askForAccess() && (try? readTracked()) != nil
    }

    private func askForAccess() -> Bool {
        let panel = NSOpenPanel()
        panel.message = "To hide icons while keeping the Focus and microphone indicators, Hidden Bar changes the \"Allow in the Menu Bar\" switches. Select this file to allow it.".localized
        panel.prompt = "Allow".localized
        panel.directoryURL = fileURL.deletingLastPathComponent()
        panel.nameFieldStringValue = fileURL.lastPathComponent
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        // An accessory app's panel never becomes key, so it could not be typed
        // into or confirmed with Return; be a regular app while it is open.
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        NSApp.setActivationPolicy(previousPolicy)
        guard response == .OK, let picked = panel.url,
              picked.standardizedFileURL.path == fileURL.standardizedFileURL.path,
              let bookmark = try? picked.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return false }
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        return true
    }

    // The bookmarked URL when there is one, so the user's pick grants access.
    private func withFile<T>(_ body: (URL) throws -> T) throws -> T {
        var stale = false
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey),
              let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return try body(fileURL) }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }

    func activate(allowedSystemItems: [Int],
                  allowedBundleIdentifiers: [String],
                  completion: @escaping (Result<NativeVisibilityAssertion, Error>) -> Void) {
        let allowed = Set(allowedBundleIdentifiers)
        let running = runningBundleIdentifiers()
        do {
            var saved = savedValues
            try updateTracked { bundle, isAllowed in
                let hide = running.contains(bundle) && !allowed.contains(bundle)
                if hide {
                    if saved[bundle] == nil { saved[bundle] = isAllowed }
                    return false
                }
                // Shown again: back to the value it had before Hidden Bar.
                return saved.removeValue(forKey: bundle) ?? isAllowed
            }
            savedValues = saved
            Self.restartMenuBarAgent()
            let handle = Handle(owner: self)
            current = handle
            completion(.success(handle))
        } catch {
            completion(.failure(error))
        }
    }

    // Puts back every switch Hidden Bar turned off. Called by the held handle
    // and at launch, in case the last session ended while collapsed.
    func restoreAll() {
        let saved = savedValues
        guard !saved.isEmpty else { return }
        do {
            try updateTracked { bundle, isAllowed in saved[bundle] ?? isAllowed }
            savedValues = [:]
            Self.restartMenuBarAgent()
        } catch {
            NSLog("AllowInMenuBar: restoring failed: \(error.localizedDescription)")
        }
    }

    func restoreAfterUnexpectedExit() {
        restoreAll()
    }

    private var savedValues: [String: Bool] {
        get { defaults.dictionary(forKey: Self.savedValuesKey) as? [String: Bool] ?? [:] }
        set { newValue.isEmpty ? defaults.removeObject(forKey: Self.savedValuesKey) : defaults.set(newValue, forKey: Self.savedValuesKey) }
    }

    // trackedApplications is a binary plist of alternating keys and values:
    // key {bundle: {_0: id}} (or {adhocBinary: ...}), value {location, menuItemLocations, isAllowed}.
    private func readTracked() throws -> (root: NSMutableDictionary, entries: NSMutableArray) {
        let data = try withFile { try Data(contentsOf: $0) }
        guard let root = try PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil) as? NSMutableDictionary,
              let blob = root["trackedApplications"] as? Data,
              let entries = try PropertyListSerialization.propertyList(from: blob, options: .mutableContainersAndLeaves, format: nil) as? NSMutableArray
        else { throw NSError(domain: "AllowInMenuBar", code: 1) }
        return (root, entries)
    }

    private func updateTracked(_ change: (String, Bool) -> Bool) throws {
        let (root, entries) = try readTracked()
        var changed = false
        var index = 0
        while index + 1 < entries.count {
            defer { index += 2 }
            guard let key = entries[index] as? NSDictionary,
                  let bundle = (key["bundle"] as? NSDictionary)?["_0"] as? String,
                  let value = entries[index + 1] as? NSMutableDictionary,
                  let isAllowed = value["isAllowed"] as? Bool else { continue }
            let next = change(bundle, isAllowed)
            if next != isAllowed {
                value["isAllowed"] = next
                changed = true
            }
        }
        guard changed else { return }
        root["trackedApplications"] = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        // In place: a temporary file beside it would need access to the folder.
        try withFile { try data.write(to: $0) }
    }

    private static func restartMenuBarAgent() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["MenuBarAgent"]
        try? process.run()
        process.waitUntilExit()
    }

    private final class Handle: NativeVisibilityAssertion {
        private weak var owner: MenuBarAllowListBridge?

        init(owner: MenuBarAllowListBridge) {
            self.owner = owner
        }

        // Only the latest activation restores: the engine activates the new
        // state before invalidating the old one.
        func invalidate() {
            guard let owner = owner, owner.current === self else { return }
            owner.current = nil
            self.owner = nil
            owner.restoreAll()
        }
    }
}
