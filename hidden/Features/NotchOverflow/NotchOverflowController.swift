//
//  NotchOverflowController.swift
//  Hidden Bar
//
//  Created by Nadir on 2026/03/30.
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit
import ApplicationServices

// MARK: - Menu Bar Extra Info

struct MenuBarExtraInfo {
  let element: AXUIElement
  let appName: String
  let appIcon: NSImage?
  let title: String?
  let pid: pid_t
  let position: CGPoint
  let size: CGSize
}

// MARK: - Notch Geometry

/// Pure geometry: where the notch is and which X coordinates on the menu-bar
/// row it makes unreachable. Kept free of NSScreen/AppKit calls so it can be
/// unit-tested with synthetic screen values instead of live hardware.
struct NotchBoundary: Equatable {
  let hasNotch: Bool
  /// The leftmost X, in screen coordinates, at which a status item is
  /// guaranteed clear of the notch. Items positioned left of this are
  /// either under the notch or squeezed off past its left edge.
  let overflowThresholdX: CGFloat
}

enum NotchGeometry {
  // Matches the pre-fix behavior's default (half of a common 1728pt-wide
  // screen) so a screen that unexpectedly can't report safeAreaInsets still
  // gets a sane threshold instead of 0.
  static let fallbackThresholdX: CGFloat = 972

  /// - Parameters:
  ///   - screenFrame: the candidate screen's full frame (`NSScreen.frame`).
  ///   - safeAreaInsetsTop: `NSScreen.safeAreaInsets.top`; > 0 on notched Macs.
  ///   - auxiliaryTopRightAreaMinX: `NSScreen.auxiliaryTopRightArea?.minX`,
  ///     Apple's own safe-rect boundary for content right of the notch.
  static func computeBoundary(
    screenFrame: CGRect,
    safeAreaInsetsTop: CGFloat,
    auxiliaryTopRightAreaMinX: CGFloat?
  ) -> NotchBoundary {
    let hasNotch = safeAreaInsetsTop > 0
    guard hasNotch, let thresholdX = auxiliaryTopRightAreaMinX else {
      return NotchBoundary(hasNotch: hasNotch, overflowThresholdX: fallbackThresholdX)
    }
    return NotchBoundary(hasNotch: true, overflowThresholdX: thresholdX)
  }
}

// MARK: - Extras Classification

/// Pure classification of already-fetched extras against a boundary. Split
/// from AX enumeration so the sorting/filtering rules are testable without
/// a live Accessibility permission or other running apps.
enum MenuBarExtraClassifier {
  static func classify(
    _ extras: [MenuBarExtraInfo],
    boundary: CGFloat
  ) -> (hidden: [MenuBarExtraInfo], visible: [MenuBarExtraInfo]) {
    let renderable = extras.filter { $0.size.width > 0 && $0.size.height > 0 }
    let hidden = renderable
      .filter { $0.position.x < boundary }
      .sorted { $0.position.x > $1.position.x }
    let visible = renderable
      .filter { $0.position.x >= boundary }
      .sorted { $0.position.x > $1.position.x }
    return (hidden, visible)
  }
}

// MARK: - NotchOverflowController

class NotchOverflowController: NSObject {

  // MARK: - Notch Detection

  // The notched built-in display, not NSScreen.main (the screen with the key
  // window): with an external display focused, the notch would read as absent
  // and "Show Notch Items" would vanish from the menu.
  private static func currentBoundary() -> NotchBoundary {
    guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else {
      return NotchBoundary(hasNotch: false, overflowThresholdX: NotchGeometry.fallbackThresholdX)
    }
    let safeAreaTop: CGFloat
    let auxRightMinX: CGFloat?
    if #available(macOS 12.0, *) {
      safeAreaTop = screen.safeAreaInsets.top
      auxRightMinX = screen.auxiliaryTopRightArea?.minX
    } else {
      safeAreaTop = 0
      auxRightMinX = nil
    }
    return NotchGeometry.computeBoundary(
      screenFrame: screen.frame,
      safeAreaInsetsTop: safeAreaTop,
      auxiliaryTopRightAreaMinX: auxRightMinX
    )
  }

  static var hasNotch: Bool {
    currentBoundary().hasNotch
  }

  /// Show overflow menu anchored to a status item (called from StatusBarController)
  // The menu opens at once with a reading row; the Accessibility walk (up to
  // 0.1s per unresponsive app) runs off the main thread and fills it in, so a
  // hung app never freezes Hidden Bar and Esc closes the menu meanwhile.
  func showOverflowMenuFromSeparator(near item: NSStatusItem) {
    guard ensureAccessibility() else { return }
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(makeSectionHeader(title: "Notch Overflow".localized, fontSize: 12))
    let reading = NSMenuItem(title: "Reading menu bar items…".localized, action: nil, keyEquivalent: "")
    reading.isEnabled = false
    menu.addItem(reading)
    let apps = Self.appsToRead()
    DispatchQueue.global(qos: .userInitiated).async {
      let read = Self.menuBarExtras(of: apps)
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        menu.removeAllItems()
        self.fill(menu, extras: read.extras, boundary: Self.currentBoundary().overflowThresholdX,
                  readFailed: read.failed, isAuthorized: AXIsProcessTrusted())
      }
    }
    item.menu = menu
    item.button?.performClick(nil)
    DispatchQueue.main.async {
      item.menu = nil
    }
  }

  // MARK: - Menu Building

  /// - Parameters:
  ///   - readFailed: some apps did not answer, so an empty list may be incomplete.
  ///   - isAuthorized: whether Accessibility is granted; without it nothing can be read.
  func buildOverflowMenu(
    extras: [MenuBarExtraInfo]? = nil,
    boundary: CGFloat? = nil,
    readFailed: Bool = false,
    isAuthorized: Bool = AXIsProcessTrusted()
  ) -> NSMenu {
    let read = extras.map { (extras: $0, failed: readFailed) } ?? Self.menuBarExtras(of: Self.appsToRead())
    let menu = NSMenu()
    menu.autoenablesItems = false
    fill(menu, extras: read.extras, boundary: boundary ?? Self.currentBoundary().overflowThresholdX,
         readFailed: read.failed, isAuthorized: isAuthorized)
    return menu
  }

  private func fill(_ menu: NSMenu, extras allExtras: [MenuBarExtraInfo], boundary resolvedBoundary: CGFloat,
                    readFailed: Bool, isAuthorized: Bool) {
    let (hiddenExtras, visibleExtras) = MenuBarExtraClassifier.classify(allExtras, boundary: resolvedBoundary)

    // Title
    menu.addItem(makeSectionHeader(title: "Notch Overflow".localized, fontSize: 12))
    menu.addItem(NSMenuItem.separator())

    // Hidden section
    if !hiddenExtras.isEmpty {
      menu.addItem(makeSectionHeader(title: String(format: "Hidden Behind Notch (%d)".localized, hiddenExtras.count)))
      menu.addItem(NSMenuItem.separator())

      for info in hiddenExtras {
        menu.addItem(makeMenuItem(for: info, hidden: true))
      }
    }

    // Visible section
    if !visibleExtras.isEmpty {
      if !hiddenExtras.isEmpty { menu.addItem(NSMenuItem.separator()) }
      menu.addItem(makeSectionHeader(title: String(format: "Visible (%d)".localized, visibleExtras.count)))
      menu.addItem(NSMenuItem.separator())

      for info in visibleExtras {
        menu.addItem(makeMenuItem(for: info, hidden: false))
      }
    }

    // Empty state: say which of the three it is, so a user who has granted the
    // permission is not told to grant it again.
    if hiddenExtras.isEmpty && visibleExtras.isEmpty {
      let title: String
      if !isAuthorized {
        title = "No items found (grant Accessibility permission)".localized
      } else if readFailed {
        title = "Menu bar items could not be read. Try again.".localized
      } else {
        title = "No items found".localized
      }
      let emptyItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      emptyItem.isEnabled = false
      menu.addItem(emptyItem)
      if !isAuthorized {
        let settingsItem = NSMenuItem(
          title: "Open Accessibility Settings…".localized,
          action: #selector(openAccessibilitySettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
      }
    }
  }

  // Disabled, non-interactive label. Bold + labelColor (full contrast) rather
  // than secondaryLabelColor/AppKit's default disabled-item dimming, which
  // read poorly against a dark selection highlight.
  private func makeSectionHeader(title: String, fontSize: CGFloat = 13) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    item.attributedTitle = NSAttributedString(
      string: title,
      attributes: [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
        .foregroundColor: NSColor.labelColor
      ])
    return item
  }

  private func makeMenuItem(for info: MenuBarExtraInfo, hidden: Bool = false) -> NSMenuItem {
    let item = NSMenuItem()
    let displayTitle = (info.title?.isEmpty == false) ? info.title! : info.appName

    if hidden {
      // Color alone isn't an accessible way to convey "hidden" (colorblind
      // users get nothing from it, and systemOrange reads poorly against a
      // dark selection highlight). A glyph + bold weight works in any theme.
      item.attributedTitle = NSAttributedString(
        string: "\u{26A0}\u{FE0F} \(displayTitle)",
        attributes: [
          .font: NSFont.boldSystemFont(ofSize: 13),
          .foregroundColor: NSColor.labelColor
        ])
    } else {
      item.title = displayTitle
    }

    if let icon = info.appIcon {
      item.image = hidden ? icon.resizedForMenu(tinted: true) : icon.resizedForMenu()
    }
    item.representedObject = info
    item.target = self
    item.action = #selector(activateItem(_:))
    return item
  }

  @objc private func openAccessibilitySettings() {
    Util.openAccessibilitySettings()
  }

  @objc private func activateItem(_ sender: NSMenuItem) {
    guard let info = sender.representedObject as? MenuBarExtraInfo else { return }
    AXUIElementPerformAction(info.element, kAXPressAction as CFString)
  }

  // MARK: - Accessibility

  private func ensureAccessibility() -> Bool {
    if AXIsProcessTrusted() { return true }
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    AXIsProcessTrustedWithOptions(opts)
    return false
  }

  // MARK: - AX Enumeration

  private struct AppToRead {
    let pid: pid_t
    let name: String
    let icon: NSImage?
  }

  // Read on the main thread (NSRunningApplication), walked off it.
  private static func appsToRead() -> [AppToRead] {
    let myPID = ProcessInfo.processInfo.processIdentifier
    // Only app bundles own status items; helpers would each sit out the timeout.
    return NSWorkspace.shared.runningApplications
      .filter { $0.processIdentifier != myPID && $0.bundleURL?.pathExtension == "app" }
      .map { AppToRead(pid: $0.processIdentifier, name: $0.localizedName ?? "Unknown", icon: $0.icon) }
  }

  // `failed` is true when an app did not answer (busy, hung or timed out), so
  // the list may be missing its items. Apps are queried concurrently, each with
  // a short timeout, and results keep the running-app order.
  private static func menuBarExtras(of apps: [AppToRead]) -> (extras: [MenuBarExtraInfo], failed: Bool) {
    var perApp = [[MenuBarExtraInfo]](repeating: [], count: apps.count)
    var failed = false
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: apps.count) { index in
      let (found, appFailed) = menuBarExtras(of: apps[index])
      lock.lock()
      perApp[index] = found
      failed = failed || appFailed
      lock.unlock()
    }
    return (perApp.flatMap { $0 }, failed)
  }

  private static func menuBarExtras(of app: AppToRead) -> ([MenuBarExtraInfo], Bool) {
    let axApp = AXUIElementCreateApplication(app.pid)
    // Without a short timeout one busy app holds the read for several seconds.
    AXUIElementSetMessagingTimeout(axApp, 0.1)
    var extrasRef: AnyObject?
    let err = AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &extrasRef)
    guard err == .success else {
      return ([], err == .cannotComplete || err == .apiDisabled)
    }
    var childrenRef: AnyObject?
    let childErr = AXUIElementCopyAttributeValue(extrasRef as! AXUIElement, kAXChildrenAttribute as CFString, &childrenRef)
    guard childErr == .success, let children = childrenRef as? [AXUIElement] else { return ([], false) }

    let results: [MenuBarExtraInfo] = children.map { child in
      var titleRef: AnyObject?
      AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)

      var posRef: AnyObject?
      AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef)
      var pos = CGPoint.zero
      if let pv = posRef { AXValueGetValue(pv as! AXValue, .cgPoint, &pos) }

      var sizeRef: AnyObject?
      AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef)
      var size = CGSize.zero
      if let sv = sizeRef { AXValueGetValue(sv as! AXValue, .cgSize, &size) }

      return MenuBarExtraInfo(
        element: child,
        appName: app.name,
        appIcon: app.icon,
        title: titleRef as? String,
        pid: app.pid,
        position: pos,
        size: size
      )
    }
    return (results, false)
  }

}

// MARK: - NSImage Extension

private extension NSImage {
  func resizedForMenu(tinted: Bool = false) -> NSImage {
    let target = NSSize(width: 18, height: 18)
    return NSImage(size: target, flipped: false) { rect in
      self.draw(in: rect,
                from: NSRect(origin: .zero, size: self.size),
                operation: .sourceOver, fraction: tinted ? 0.5 : 1.0)
      return true
    }
  }
}
