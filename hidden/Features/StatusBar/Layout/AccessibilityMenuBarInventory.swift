//
//  AccessibilityMenuBarInventory.swift
//  Hidden Bar
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit
import ApplicationServices

// Lists other apps' status items through public Accessibility API: every running
// app's AXExtrasMenuBar children, with the owning bundle from the process.
// Needs the Accessibility permission, and does not work inside the App Sandbox
// (the sandbox denies the mach-lookup to com.apple.axserver even when the
// permission is granted), so only the non-sandboxed direct build uses it.
final class AccessibilityMenuBarInventory: MenuBarInventoryProviding {
    private static let messagingTimeout: Float = 0.1

    private var hasRequestedAuthorization = false

    var isAuthorized: Bool {
        return AXIsProcessTrusted()
    }

    // Shows the system prompt once per launch; asking on every collapse would
    // nag while the user is still in System Settings.
    func requestAuthorization() {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // Accessibility round-trips to every app take about a second in total, so the
    // walk runs off the main thread.
    func snapshot(completion: @escaping (MenuBarInventorySnapshot) -> Void) {
        // Only app bundles own status items. Skipping the rest (dozens of WebKit
        // and XPC helpers, each of which would sit out the timeout) cuts the walk
        // from ~2.8s to ~1s.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != ownPID && $0.bundleURL?.pathExtension == "app" }
            .map { (pid: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier) }
        DispatchQueue.global(qos: .userInitiated).async {
            let items = Self.statusItems(of: apps)
            DispatchQueue.main.async { completion(items) }
        }
    }

    // The per-app queries are independent, and serially they add up to seconds of
    // collapse delay with many apps running, so they run concurrently. Results
    // keep the running-app order.
    private static func statusItems(of apps: [(pid: pid_t, bundleIdentifier: String?)]) -> MenuBarInventorySnapshot {
        var perApp = [MenuBarInventorySnapshot](repeating: .init(items: []), count: apps.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: apps.count) { index in
            let found = statusItems(of: apps[index])
            lock.lock()
            perApp[index] = found
            lock.unlock()
        }
        return MenuBarInventorySnapshot(items: perApp.flatMap(\.items),
                                        unreadableBundles: Set(perApp.flatMap(\.unreadableBundles)),
                                        noIconBundles: Set(perApp.flatMap(\.noIconBundles)))
    }

    private static func statusItems(of app: (pid: pid_t, bundleIdentifier: String?)) -> MenuBarInventorySnapshot {
        let bundles = Set(app.bundleIdentifier.map { [$0] } ?? [])
        let unreadable = MenuBarInventorySnapshot(items: [], unreadableBundles: bundles)
        let element = AXUIElementCreateApplication(app.pid)
        // The default timeout is several seconds per app, and one busy or hung
        // app then stalls the collapse (measured: ~18s on a normal session).
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var barValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &barValue)
        if error == .noValue || error == .attributeUnsupported {
            return MenuBarInventorySnapshot(items: [], noIconBundles: bundles)
        }
        guard error == .success, let bar = barValue else { return unreadable }
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return unreadable }
        let items = children.compactMap { child in
            frame(of: child).map { MenuBarInventoryItem(bundleIdentifier: app.bundleIdentifier, frame: $0) }
        }
        // A missing sibling could be on the visible side. Do not hide the whole
        // app using only the children whose frames happened to be readable.
        guard items.count == children.count else { return unreadable }
        let visibleItems = items.filter { $0.frame.width > 0 && $0.frame.height > 0 }
        return MenuBarInventorySnapshot(items: visibleItems,
                                        noIconBundles: visibleItems.isEmpty ? bundles : [])
    }

    // Accessibility frames use a top-left origin, AppKit's bottom-left. Only the
    // horizontal position matters for sections, and x is the same in both.
    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }
}
