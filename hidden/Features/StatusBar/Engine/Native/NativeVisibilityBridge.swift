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
// The switches are written through cfprefsd (CFPreferences with the file's
// absolute path as the domain), which tells MenuBarAgent about the change, so it
// applies it within a second without being restarted; a plain file write is not
// seen until MenuBarAgent restarts, which blanks the whole menu bar. The
// technique follows Chest (github.com/boringbar/chest, MIT).
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
    private static let trackedKey = "trackedApplications" as CFString
    // An absolute path (without .plist) makes CFPreferences use that very file.
    private var domain: CFString {
        return fileURL.deletingPathExtension().path as CFString
    }
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
        panel.message = NSLocalizedString("To hide icons while keeping the Focus and microphone indicators, Hidden Bar changes the \"Allow in the Menu Bar\" switches. Select this file to allow it.", comment: "")
        panel.prompt = NSLocalizedString("Allow", comment: "")
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
        let hidden = runningBundleIdentifiers().subtracting(allowed)
        do {
            var saved = savedValues
            try updateTracked { entries in
                AllowList.apply(hiding: hidden, keeping: allowed, to: entries, saved: &saved)
            }
            savedValues = saved
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
            var remaining = saved
            try updateTracked { entries in
                AllowList.apply(hiding: [], keeping: [], to: entries, saved: &remaining)
            }
            savedValues = [:]
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
    // MenuBarAgent adds entries on its own, so the list is always read fresh
    // (synchronize first) and only isAllowed of existing entries is changed.
    private func readTracked() throws -> NSMutableArray {
        let domain = self.domain
        let blob: Data? = try withFile { _ in
            CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            return CFPreferencesCopyValue(Self.trackedKey, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Data
        }
        guard let blob = blob,
              let entries = try PropertyListSerialization.propertyList(from: blob, options: .mutableContainersAndLeaves, format: nil) as? NSMutableArray
        else { throw NSError(domain: "AllowInMenuBar", code: 1) }
        return entries
    }

    private func updateTracked(_ change: (NSMutableArray) -> Bool) throws {
        let entries = try readTracked()
        guard change(entries) else { return }
        let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
        let domain = self.domain
        let written: Bool = try withFile { _ in
            CFPreferencesSetValue(Self.trackedKey, data as CFData, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            return CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        guard written else { throw NSError(domain: "AllowInMenuBar", code: 2) }
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

// Which "Allow in the Menu Bar" entries to switch for a set of apps.
//
// MenuBarAgent identifies a status item by its app's bundle id and applies a
// switch live only to items whose identity is in the entry's menuItemLocations;
// the entry's key alone is not enough (an entry left by an old build can carry
// only that build's executable path, and then its switch is ignored). So an
// entry is matched through menuItemLocations, and an entry keyed by a hidden app
// whose locations lack that app's bundle id gets it added first. A helper that
// draws the icon (iStat Menus Status) is matched the same way, through the
// parent app's entry that lists it.
enum AllowList {
    static func bundles(in locations: NSArray?) -> Set<String> {
        var result = Set<String>()
        for case let location as NSDictionary in locations ?? [] {
            if let id = (location["bundle"] as? NSDictionary)?["_0"] as? String {
                result.insert(id)
            }
        }
        return result
    }

    private static func keyBundle(_ key: Any) -> String? {
        return ((key as? NSDictionary)?["bundle"] as? NSDictionary)?["_0"] as? String
    }

    // Switches off every entry listing a hidden app and no kept one (one switch
    // governs all of an entry's items, so an entry that also lists a visible
    // helper stays on), and puts every other entry Hidden Bar changed back to
    // its saved value. saved maps an entry's key bundle id to the value it had
    // before. Returns whether anything changed.
    static func apply(hiding hidden: Set<String>, keeping kept: Set<String>, to entries: NSMutableArray, saved: inout [String: Bool]) -> Bool {
        var changed = false
        var pairs: [(key: String, value: NSMutableDictionary)] = []
        var index = 0
        while index + 1 < entries.count {
            if let key = keyBundle(entries[index]), let value = entries[index + 1] as? NSMutableDictionary {
                pairs.append((key, value))
            }
            index += 2
        }
        var listed = Set<String>()
        for pair in pairs {
            listed.formUnion(bundles(in: pair.value["menuItemLocations"] as? NSArray))
        }
        for pair in pairs where hidden.contains(pair.key) && !listed.contains(pair.key) {
            let locations = (pair.value["menuItemLocations"] as? NSArray)?.mutableCopy() as? NSMutableArray ?? NSMutableArray()
            locations.add(["bundle": ["_0": pair.key]] as NSDictionary)
            pair.value["menuItemLocations"] = locations
            changed = true
        }
        for pair in pairs {
            guard let isAllowed = pair.value["isAllowed"] as? Bool else { continue }
            let next: Bool
            let locations = bundles(in: pair.value["menuItemLocations"] as? NSArray)
            if !locations.isDisjoint(with: hidden) && locations.isDisjoint(with: kept) {
                if saved[pair.key] == nil { saved[pair.key] = isAllowed }
                next = false
            } else {
                next = saved.removeValue(forKey: pair.key) ?? isAllowed
            }
            if next != isAllowed {
                pair.value["isAllowed"] = next
                changed = true
            }
        }
        return changed
    }
}
