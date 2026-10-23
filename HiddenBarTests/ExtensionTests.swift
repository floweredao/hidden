//
//  ExtensionTests.swift
//  HiddenBarTests
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit
import XCTest

final class BundleExtensionTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleExtensionTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // A synthetic bundle on disk, a fresh path each time because Bundle caches
    // instances by path.
    private func makeBundle(_ info: [String: Any]) throws -> Bundle {
        let contents = directory.appendingPathComponent("Fixture.bundle/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = Bundle(url: contents.deletingLastPathComponent())
        return try XCTUnwrap(bundle)
    }

    // About shows these: the fork version over the numeric one, then the build
    // number and the commit the "Record Git Commit" phase stamped.
    func testVersionsAreReadFromInfoPlist() throws {
        let bundle = try makeBundle([
            "CFBundleIdentifier": "com.example.fixture",
            "CFBundleShortVersionString": "1.11.1",
            "CFBundleVersion": "16",
            "HBForkVersion": "1.11.1-fw.2",
            "HBGitCommit": "0123abc",
        ])
        XCTAssertEqual(bundle.releaseVersionNumber, "1.11.1")
        XCTAssertEqual(bundle.buildVersionNumber, "16")
        XCTAssertEqual(bundle.forkVersionNumber, "1.11.1-fw.2")
        XCTAssertEqual(bundle.gitCommit, "0123abc")
    }

    // An upstream or unstamped build has no fork keys; About then falls back.
    func testMissingKeysReadAsNil() throws {
        let bundle = try makeBundle(["CFBundleIdentifier": "com.example.fixture"])
        XCTAssertNil(bundle.releaseVersionNumber)
        XCTAssertNil(bundle.buildVersionNumber)
        XCTAssertNil(bundle.forkVersionNumber)
        XCTAssertNil(bundle.gitCommit)
    }
}

final class UserDefaultsKeyTests: XCTestCase {

    // These names are what users' preference files hold and what the docs'
    // `defaults write` commands use; renaming one silently resets that setting.
    func testStoredKeyNamesAreStable() {
        XCTAssertEqual(UserDefaults.Key.globalKey, "globalKey")
        XCTAssertEqual(UserDefaults.Key.numberOfSecondForAutoHide, "numberOfSecondForAutoHide")
        XCTAssertEqual(UserDefaults.Key.isAutoStart, "isAutoStart")
        XCTAssertEqual(UserDefaults.Key.isAutoHide, "isAutoHide")
        XCTAssertEqual(UserDefaults.Key.isShowPreference, "isShowPreferences")
        XCTAssertEqual(UserDefaults.Key.areSeparatorsHidden, "areSeparatorsHidden")
        XCTAssertEqual(UserDefaults.Key.alwaysHiddenSectionEnabled, "alwaysHiddenSectionEnabled")
        XCTAssertEqual(UserDefaults.Key.useFullStatusBarOnExpandEnabled, "useFullStatusBarOnExpandEnabled")
        XCTAssertEqual(UserDefaults.Key.hoverToExpand, "hoverToExpand")
        XCTAssertEqual(UserDefaults.Key.notchOverflowEnabled, "notchOverflowEnabled")
        XCTAssertEqual(UserDefaults.Key.sectionOverrides, "sectionOverrides")
        XCTAssertEqual(UserDefaults.Key.showsSystemIndicatorsWhenExpanded, "showsSystemIndicatorsWhenExpanded")
        XCTAssertEqual(UserDefaults.Key.hidesIntoSystemOverflow, "hidesIntoSystemOverflow")
        XCTAssertEqual(UserDefaults.Key.hidesWithMenuBarSettings, "hidesWithMenuBarSettings")
    }
}

final class NotificationNameTests: XCTestCase {

    // Two names that shared a string would wake each other's observers.
    func testNamesAreDistinct() {
        let names: [Notification.Name] = [.prefsChanged, .alwayHideToggle, .sectionOverridesChanged,
                                          .hidingStatusChanged, .systemIndicatorsPreferenceChanged]
        XCTAssertEqual(Set(names.map { $0.rawValue }).count, names.count)
    }
}

final class StackViewExtensionTests: XCTestCase {

    // The Settings illustration is rebuilt on every change; each icon carries
    // its own size constraints, which must not outlive it (PR #335).
    func testRemoveAllSubViewsRemovesTheViewsAndTheirConstraints() {
        let stack = NSStackView()
        var widths: [NSLayoutConstraint] = []
        for _ in 0..<3 {
            let view = NSView()
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
            let width = view.widthAnchor.constraint(equalToConstant: 16)
            width.isActive = true
            widths.append(width)
        }
        XCTAssertEqual(stack.views.count, 3)

        stack.removeAllSubViews()

        XCTAssertTrue(stack.views.isEmpty)
        XCTAssertTrue(stack.arrangedSubviews.isEmpty)
        XCTAssertTrue(stack.subviews.isEmpty)
        XCTAssertFalse(widths.contains { $0.isActive })
    }

    func testRemoveAllSubViewsOnAnEmptyStackDoesNothing() {
        let stack = NSStackView()
        stack.removeAllSubViews()
        XCTAssertTrue(stack.views.isEmpty)
    }
}

final class ViewExtensionTests: XCTestCase {

    func testOriginIsNilOutsideAWindow() {
        XCTAssertNil(NSView().getOrigin)
    }

    // The origin is the window's, in screen coordinates, not the view's frame.
    func testOriginIsTheWindowOrigin() {
        let window = NSWindow(contentRect: NSRect(x: 120, y: 340, width: 200, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 10, y: 20, width: 30, height: 40))
        window.contentView?.addSubview(view)
        XCTAssertEqual(view.getOrigin, CGPoint(x: 120, y: 340))
    }
}
