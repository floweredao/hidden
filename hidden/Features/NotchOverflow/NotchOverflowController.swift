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
  func showOverflowMenuFromSeparator(near item: NSStatusItem) {
    guard ensureAccessibility() else { return }
    let menu = buildOverflowMenu()
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
    let read = extras.map { (extras: $0, failed: readFailed) } ?? getAllMenuBarExtras()
    let allExtras = read.extras
    let resolvedBoundary = boundary ?? Self.currentBoundary().overflowThresholdX
    let (hiddenExtras, visibleExtras) = MenuBarExtraClassifier.classify(allExtras, boundary: resolvedBoundary)

    let menu = NSMenu()
    menu.autoenablesItems = false

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
      } else if read.failed {
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

    return menu
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

  // `failed` is true when an app did not answer (busy, hung or timed out), so
  // the list may be missing its items.
  private func getAllMenuBarExtras() -> (extras: [MenuBarExtraInfo], failed: Bool) {
    var results: [MenuBarExtraInfo] = []
    var failed = false
    let myPID = ProcessInfo.processInfo.processIdentifier

    for app in NSWorkspace.shared.runningApplications {
      if app.processIdentifier == myPID { continue }
      // Only app bundles own status items; helpers would each sit out the timeout.
      guard app.bundleURL?.pathExtension == "app" else { continue }

      let axApp = AXUIElementCreateApplication(app.processIdentifier)
      // This runs on the main thread while the menu opens; without a short
      // timeout one busy app freezes Hidden Bar for the default several seconds.
      AXUIElementSetMessagingTimeout(axApp, 0.1)
      var extrasRef: AnyObject?
      let err = AXUIElementCopyAttributeValue(
        axApp, "AXExtrasMenuBar" as CFString, &extrasRef)
      guard err == .success else {
        if err == .cannotComplete || err == .apiDisabled { failed = true }
        continue
      }

      var childrenRef: AnyObject?
      let childErr = AXUIElementCopyAttributeValue(
        extrasRef as! AXUIElement,
        kAXChildrenAttribute as CFString, &childrenRef)
      guard childErr == .success,
        let children = childrenRef as? [AXUIElement]
      else { continue }

      for child in children {
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

        results.append(MenuBarExtraInfo(
          element: child,
          appName: app.localizedName ?? "Unknown",
          appIcon: app.icon,
          title: titleRef as? String,
          pid: app.processIdentifier,
          position: pos,
          size: size
        ))
      }
    }
    return (results, failed)
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
