//
//  NativeVisibilityBridge.swift
//  Hidden Bar
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit
import os.log

// A held visibility restriction. Failed restoration keeps the handle valid so
// its caller can retry instead of reporting that the bar has been restored.
protocol NativeVisibilityAssertion: AnyObject {
    @discardableResult func invalidate() -> Bool
    var unmatchedHiddenBundleIdentifiers: Set<String> { get }
}

extension NativeVisibilityAssertion {
    var unmatchedHiddenBundleIdentifiers: Set<String> { [] }
}

protocol NativeVisibilityProviding: AnyObject {
    var isAvailable: Bool { get }
    var unavailableReason: HidingUnavailableReason { get }
    func requestAccess()
    @discardableResult func restoreAll() -> Bool

    // Keeps only these system items and apps visible. The completion runs on the
    // main queue.
    func activate(allowedSystemItems: [Int],
                  allowedBundleIdentifiers: [String],
                  completion: @escaping (Result<NativeVisibilityAssertion, Error>) -> Void)
    func activate(allowedSystemItems: [Int],
                  allowedBundleIdentifiers: [String],
                  hiddenBundleIdentifiers: Set<String>,
                  completion: @escaping (Result<NativeVisibilityAssertion, Error>) -> Void)
}

extension NativeVisibilityProviding {
    var unavailableReason: HidingUnavailableReason { .notSupported }
    func requestAccess() {}
    @discardableResult func restoreAll() -> Bool { true }
    func activate(allowedSystemItems: [Int], allowedBundleIdentifiers: [String],
                  hiddenBundleIdentifiers: Set<String>,
                  completion: @escaping (Result<NativeVisibilityAssertion, Error>) -> Void) {
        activate(allowedSystemItems: allowedSystemItems,
                 allowedBundleIdentifiers: allowedBundleIdentifiers, completion: completion)
    }
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

        @discardableResult func invalidate() -> Bool {
            guard let raw = raw else { return true }
            self.raw = nil
            HBNativeVisibilityInvalidate(raw)
            return true
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
    private static let journalKey = "allowInMenuBarJournal"
    private static let pendingKey = "allowInMenuBarPending"
    private static let bookmarkKey = "allowInMenuBarFileBookmark"
    private static let log = OSLog(subsystem: "com.dwarvesv.minimalbar", category: "AllowInMenuBar")

    enum Diagnostic: Equatable {
        case unmatched(Set<String>)
        case writeMismatch
        case unmanagedDisabled(String)
        case restoreFailed
    }

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
    private let executableURL: (String) -> URL?
    private let readEntries: (() throws -> NSMutableArray)?
    private let writeEntries: ((NSMutableArray) throws -> Void)?
    private let synchronizeJournal: () -> Bool
    private let diagnostic: (Diagnostic) -> Void
    private let accessPrompt: (() -> Bool)?
    private var userOverrides = Set<String>()
    private weak var current: Handle?

    init(defaults: UserDefaults = .standard,
         runningBundleIdentifiers: @escaping () -> Set<String> = { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) },
         executableURL: @escaping (String) -> URL? = { id in
             NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id }?.executableURL
         },
         readEntries: (() throws -> NSMutableArray)? = nil,
         writeEntries: ((NSMutableArray) throws -> Void)? = nil,
         synchronizeJournal: (() -> Bool)? = nil,
         diagnostic: @escaping (Diagnostic) -> Void = { _ in },
         accessPrompt: (() -> Bool)? = nil) {
        self.defaults = defaults
        self.runningBundleIdentifiers = runningBundleIdentifiers
        self.executableURL = executableURL
        self.readEntries = readEntries
        self.writeEntries = writeEntries
        self.synchronizeJournal = synchronizeJournal ?? { defaults.synchronize() }
        self.diagnostic = diagnostic
        self.accessPrompt = accessPrompt
    }

    var isAvailable: Bool {
        if (try? readTracked()) != nil { return true }
        guard !askedThisSession, Thread.isMainThread else { return false }
        askedThisSession = true
        return askForAccess() && (try? readTracked()) != nil
    }

    var unavailableReason: HidingUnavailableReason { .fileAccessNeeded }

    func requestAccess() {
        askedThisSession = false
        _ = isAvailable
    }

    private func askForAccess() -> Bool {
        if let prompt = accessPrompt { return prompt() }
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
        activate(allowedSystemItems: allowedSystemItems,
                 allowedBundleIdentifiers: allowedBundleIdentifiers,
                 hiddenBundleIdentifiers: hidden, completion: completion)
    }

    func activate(allowedSystemItems: [Int],
                  allowedBundleIdentifiers: [String],
                  hiddenBundleIdentifiers: Set<String>,
                  completion: @escaping (Result<NativeVisibilityAssertion, Error>) -> Void) {
        let allowed = Set(allowedBundleIdentifiers)
        do {
            if current == nil { userOverrides = [] }
            let unmatched = try updateTracked(hiding: hiddenBundleIdentifiers, keeping: allowed)
            if !unmatched.isEmpty {
                os_log("Unmatched hidden bundles: %{public}@", log: Self.log, type: .error,
                       unmatched.sorted().joined(separator: ", "))
                diagnostic(.unmatched(unmatched))
            }
            let handle = Handle(owner: self, unmatched: unmatched)
            current = handle
            completion(.success(handle))
        } catch {
            completion(.failure(error))
        }
    }

    // Puts back every switch Hidden Bar turned off. Called by the held handle
    // and at launch, in case the last session ended while collapsed.
    @discardableResult func restoreAll() -> Bool {
        guard !journal.isEmpty || defaults.bool(forKey: Self.pendingKey) else { return true }
        do {
            _ = try updateTracked(hiding: [], keeping: [])
            return journal.isEmpty
        } catch {
            os_log("Restoring failed: %{public}@", log: Self.log, type: .error, error.localizedDescription)
            diagnostic(.restoreFailed)
            return false
        }
    }

    func restoreAfterUnexpectedExit() {
        // Audit before recovery so unrelated disabled entries are never claimed.
        if let entries = try? readTracked() {
            let saved = journal
            for index in stride(from: 0, to: entries.count - entries.count % 2, by: 2) {
                guard let key = entries[index] as? NSDictionary,
                      let identity = AllowList.identity(key),
                      let value = entries[index + 1] as? NSDictionary,
                      value["isAllowed"] as? Bool == false,
                      saved[identity] == nil,
                      AllowList.bundle(key).flatMap({ saved[$0] }) == nil else { continue }
                os_log("Unmanaged disabled entry: %{public}@", log: Self.log, type: .info, identity)
                diagnostic(.unmanagedDisabled(identity))
            }
        }
        restoreAll()
    }

    private var journal: AllowList.Journal {
        if let data = defaults.data(forKey: Self.journalKey),
           let saved = try? PropertyListDecoder().decode(AllowList.Journal.self, from: data) {
            return saved
        }
        // Builds before the journal used bundle ids. Migrate them on the next write.
        return (defaults.dictionary(forKey: Self.savedValuesKey) as? [String: Bool] ?? [:])
            .mapValues { AllowList.Record(original: $0, written: false) }
    }

    private func persist(_ journal: AllowList.Journal, pending: Bool) throws {
        if journal.isEmpty && !pending {
            // Successful restoration must durably remove recovery ownership
            // before termination can leave an obsolete journal on disk.
            defaults.removeObject(forKey: Self.journalKey)
            defaults.removeObject(forKey: Self.savedValuesKey)
            defaults.removeObject(forKey: Self.pendingKey)
        } else {
            defaults.set(try PropertyListEncoder().encode(journal), forKey: Self.journalKey)
            defaults.set(journal.mapValues(\.original), forKey: Self.savedValuesKey)
            defaults.set(pending, forKey: Self.pendingKey)
        }
        guard synchronizeJournal() else { throw NSError(domain: "AllowInMenuBar.Journal", code: 1) }
    }

    // trackedApplications is a binary plist of alternating keys and values:
    // key {bundle: {_0: id}} (or {adhocBinary: ...}), value {location, menuItemLocations, isAllowed}.
    // MenuBarAgent adds entries on its own, so the list is always read fresh
    // (synchronize first) and only isAllowed of existing entries is changed.
    private func readTracked() throws -> NSMutableArray {
        if let readEntries = readEntries { return try readEntries() }
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

    private func updateTracked(hiding hidden: Set<String>, keeping kept: Set<String>) throws -> Set<String> {
        let initial = try readTracked()
        let before = journal
        var planned = before
        _ = AllowList.apply(hiding: hidden, keeping: kept, to: initial, journal: &planned,
                            userOverrides: &userOverrides, executableURL: executableURL)
        try persist(before.merging(planned) { _, new in new }, pending: true)
        // Journal synchronization can take time. Rebase the change on a fresh
        // read afterwards, and journal any newly discovered originals as well.
        // This is not atomic: CFPreferences has no compare-and-swap operation.
        let entries = try readTracked()
        var remaining = before
        let result = AllowList.apply(hiding: hidden, keeping: kept, to: entries, journal: &remaining,
                                     userOverrides: &userOverrides, executableURL: executableURL)
        // Keep restored records until the external write succeeds too.
        let recovery = before.merging(remaining) { _, new in new }
        try persist(recovery, pending: true)
        if result.changed {
            try writeTracked(entries)
            let actual = try readTracked()
            if !entries.isEqual(actual) {
                os_log("trackedApplications differs after write", log: Self.log, type: .error)
                diagnostic(.writeMismatch)
                throw NSError(domain: "AllowInMenuBar", code: 3)
            }
        }
        do {
            try persist(remaining, pending: false)
        } catch {
            // A failed completion sync must not erase the pending recovery
            // record from this process's UserDefaults cache.
            do {
                try persist(recovery, pending: true)
            } catch {
                os_log("Recovery journal synchronization failed: %{public}@", log: Self.log,
                       type: .error, error.localizedDescription)
            }
            throw error
        }
        return result.unmatched
    }

    private func writeTracked(_ entries: NSMutableArray) throws {
        if let writeEntries = writeEntries { return try writeEntries(entries) }
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
        let unmatchedHiddenBundleIdentifiers: Set<String>

        init(owner: MenuBarAllowListBridge, unmatched: Set<String>) {
            self.owner = owner
            self.unmatchedHiddenBundleIdentifiers = unmatched
        }

        // Only the latest activation restores: the engine activates the new
        // state before invalidating the old one.
        @discardableResult func invalidate() -> Bool {
            guard let owner = owner, owner.current === self else { return true }
            guard owner.restoreAll() else { return false }
            owner.current = nil
            self.owner = nil
            return true
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
    struct Record: Codable, Equatable {
        let original: Bool
        let written: Bool
        var addedLocations: [String] = []
        var locationsWereAbsent = false
    }

    typealias Journal = [String: Record]

    struct Change {
        let changed: Bool
        let unmatched: Set<String>
    }

    // Sorting every dictionary level keeps identity independent of plist ordering
    // while retaining the complete key, including ad-hoc paths and extra fields.
    static func identity(_ key: NSDictionary) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: key, options: [.sortedKeys]),
              let result = String(data: data, encoding: .utf8) else { return nil }
        return result
    }

    static func bundle(_ key: NSDictionary) -> String? {
        (key["bundle"] as? NSDictionary)?["_0"] as? String
    }

    static func bundles(in locations: NSArray?) -> Set<String> {
        var result = Set<String>()
        for case let location as NSDictionary in locations ?? [] {
            if let id = (location["bundle"] as? NSDictionary)?["_0"] as? String {
                result.insert(id)
            }
        }
        return result
    }

    private static func matches(_ location: NSDictionary, candidates: Set<String>,
                                executableURL: (String) -> URL?) -> Set<String> {
        if let id = bundle(location) { return candidates.contains(id) ? [id] : [] }
        guard let path = ((location["adhocBinary"] as? NSDictionary)?["_0"] as? NSDictionary)?["relative"] as? String,
              let url = URL(string: path), url.isFileURL else { return [] }
        return Set(candidates.filter { executableURL($0)?.standardizedFileURL == url.standardizedFileURL })
    }

    // The journal and entries are caller-owned values. No preferences or running
    // application lookups happen here, making reconciliation deterministic.
    static func apply(hiding hidden: Set<String>, keeping kept: Set<String>, to entries: NSMutableArray,
                      journal: inout Journal, userOverrides: inout Set<String>,
                      executableURL: (String) -> URL?) -> Change {
        var changed = false
        let candidates = hidden.union(kept)
        var pairs: [(key: NSDictionary, identity: String, value: NSMutableDictionary)] = []
        var index = 0
        while index + 1 < entries.count {
            if let key = entries[index] as? NSDictionary, let identity = identity(key),
               let value = entries[index + 1] as? NSMutableDictionary {
                pairs.append((key, identity, value))
            }
            index += 2
        }
        var listed = Set<String>()
        for pair in pairs {
            for case let location as NSDictionary in pair.value["menuItemLocations"] as? NSArray ?? [] {
                listed.formUnion(matches(location, candidates: candidates, executableURL: executableURL))
            }
        }
        var matched = Set<String>()
        for pair in pairs {
            guard let isAllowed = pair.value["isAllowed"] as? Bool else { continue }
            let id = pair.identity
            if let legacy = bundle(pair.key), journal[id] == nil,
               let record = journal.removeValue(forKey: legacy) {
                journal[id] = record
            }
            var record = journal[id]
            let overridden = record.map { isAllowed != $0.written } ?? false
            if overridden { userOverrides.insert(id) }

            let locations = (pair.value["menuItemLocations"] as? NSArray)?.mutableCopy() as? NSMutableArray ?? NSMutableArray()
            var locationsChanged = false
            var represented = Set<String>()
            for case let location as NSDictionary in locations {
                represented.formUnion(matches(location, candidates: candidates, executableURL: executableURL))
            }
            let keyMatches = matches(pair.key, candidates: candidates, executableURL: executableURL)
            let missing = keyMatches.intersection(hidden).subtracting(listed)
            let shouldHide = !represented.union(missing).isDisjoint(with: hidden)
                && represented.isDisjoint(with: kept) && !userOverrides.contains(id)

            if shouldHide {
                if record == nil {
                    record = Record(original: isAllowed, written: false,
                                    locationsWereAbsent: pair.value["menuItemLocations"] == nil)
                }
                for bundle in missing.sorted() {
                    locations.add(["bundle": ["_0": bundle]] as NSDictionary)
                    record?.addedLocations.append(bundle)
                    locationsChanged = true
                }
                journal[id] = record
                matched.formUnion(represented.union(missing).intersection(hidden))
            } else {
                if let record = record {
                    // Only remove our exact additions, not locations the agent
                    // registered while the restriction was active.
                    for bundle in record.addedLocations {
                        let addition = ["bundle": ["_0": bundle]] as NSDictionary
                        if let offset = (0..<locations.count).first(where: { addition.isEqual(locations[$0]) }) {
                            locations.removeObject(at: offset)
                            locationsChanged = true
                        }
                    }
                }
                journal.removeValue(forKey: id)
            }
            if locationsChanged {
                if !shouldHide && record?.locationsWereAbsent == true && locations.count == 0 {
                    pair.value.removeObject(forKey: "menuItemLocations")
                } else {
                    pair.value["menuItemLocations"] = locations
                }
                changed = true
            }
            let next = shouldHide ? false : (overridden ? isAllowed : record?.original ?? isAllowed)
            if next != isAllowed {
                pair.value["isAllowed"] = next
                changed = true
            }
        }
        return Change(changed: changed, unmatched: hidden.subtracting(matched))
    }
}
