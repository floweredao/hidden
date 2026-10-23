//
//  ExpandCollapseActionTests.swift
//  HiddenBarTests
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit
import XCTest

final class ExpandCollapseActionTests: XCTestCase {

    // Assistive synthesis (VoiceOver AXPress) produces no NSEvent; a nil event
    // must still toggle the bar, matching a plain left click.
    func testNilEventToggles() {
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: nil, modifiers: [], alwaysHiddenSectionEnabled: true), .toggle)
    }

    func testLeftClickToggles() {
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .leftMouseUp, modifiers: [], alwaysHiddenSectionEnabled: true), .toggle)
    }

    func testRightClickTogglesAlwaysHiddenSection() {
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .rightMouseUp, modifiers: [], alwaysHiddenSectionEnabled: true), .toggleSeparators)
    }

    func testControlClickActsAsRightClick() {
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .leftMouseUp, modifiers: .control, alwaysHiddenSectionEnabled: true), .toggleSeparators)
    }

    func testRightClickShowsContextMenuWithoutAlwaysHiddenSection() {
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .rightMouseUp, modifiers: [], alwaysHiddenSectionEnabled: false), .contextMenu)
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .leftMouseUp, modifiers: .control, alwaysHiddenSectionEnabled: false), .contextMenu)
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .leftMouseUp, modifiers: [], alwaysHiddenSectionEnabled: false), .toggle)
    }

    func testOptionLeftShowsContextMenu() {
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .leftMouseUp, modifiers: .option, alwaysHiddenSectionEnabled: true), .contextMenu)
    }

    func testOptionRightShowsContextMenu() {
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .rightMouseUp, modifiers: .option, alwaysHiddenSectionEnabled: true), .contextMenu)
    }

    func testOtherMouseEventTogglesSeparators() {
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .otherMouseUp, modifiers: [], alwaysHiddenSectionEnabled: true), .toggleSeparators)
    }

    // On macOS 27 the button's mouse-up event arrives with no modifier flags
    // while a modifier is physically held; the live flags must still count.
    func testModifiersComeFromLiveFlagsWhenEventFlagsAreEmpty() {
        let modifiers = ExpandCollapseActionResolver.modifiers(eventFlags: [], liveFlags: .option)
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .leftMouseUp, modifiers: modifiers, alwaysHiddenSectionEnabled: true), .contextMenu)
    }

    func testModifiersComeFromEventFlags() {
        XCTAssertTrue(ExpandCollapseActionResolver.modifiers(eventFlags: .control, liveFlags: []).contains(.control))
    }

    func testNoModifiersWithoutEventOrLiveFlags() {
        XCTAssertEqual(ExpandCollapseActionResolver.modifiers(eventFlags: nil, liveFlags: []), [])
    }

    // Device-dependent bits (which physical Control or Shift key) are dropped,
    // so they never make two presses of the same shortcut compare unequal.
    func testDeviceDependentFlagsAreDropped() {
        let leftControlKeyBit = NSEvent.ModifierFlags(rawValue: 0x1)
        let modifiers = ExpandCollapseActionResolver.modifiers(eventFlags: [.option, leftControlKeyBit], liveFlags: [])
        XCTAssertEqual(modifiers, .option)
    }

    func testEventAndLiveFlagsAreCombined() {
        let modifiers = ExpandCollapseActionResolver.modifiers(eventFlags: .control, liveFlags: .option)
        XCTAssertEqual(modifiers, [.control, .option])
    }

    func testShiftOrCommandLeftClickStillToggles() {
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .leftMouseUp, modifiers: .shift, alwaysHiddenSectionEnabled: true), .toggle)
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .leftMouseUp, modifiers: .command, alwaysHiddenSectionEnabled: true), .toggle)
    }

    func testOptionWinsOverControl() {
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .leftMouseUp, modifiers: [.option, .control], alwaysHiddenSectionEnabled: true), .contextMenu)
    }

    // A press with no event is an assistive one: it toggles even while Option
    // reads as held.
    func testNilEventTogglesWhateverTheModifiers() {
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: nil, modifiers: .option, alwaysHiddenSectionEnabled: false), .toggle)
    }
}
