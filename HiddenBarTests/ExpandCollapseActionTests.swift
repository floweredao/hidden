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

    func testToggleDuringCalibrationCancelsAndFailedRestoreRetriesExpansion() {
        XCTAssertTrue(ExpandCollapseActionResolver.shouldExpand(state: .calibrating, problem: nil))
        XCTAssertTrue(ExpandCollapseActionResolver.shouldExpand(state: .collapsed, problem: nil))
        XCTAssertTrue(ExpandCollapseActionResolver.shouldExpand(state: .unavailable, problem: .restoreFailed))
        XCTAssertFalse(ExpandCollapseActionResolver.shouldExpand(state: .expanded, problem: nil))
    }

    func testUnrelatedAndDuplicateMenuNotificationsCannotPoisonTracking() {
        var tracking = OwnedMenuTracking()
        let own = NSMenu()
        let other = NSMenu()
        tracking.began(other, owned: false)
        XCTAssertFalse(tracking.isTracking)
        tracking.began(own, owned: true)
        tracking.began(own, owned: true)
        tracking.ended(other)
        XCTAssertTrue(tracking.isTracking)
        tracking.ended(own)
        XCTAssertFalse(tracking.isTracking)
        tracking.ended(own)
        XCTAssertFalse(tracking.isTracking)
    }

    func testEveryAutoCollapseDeferralHasADistinctReason() {
        var policy = AutoCollapseDeferral()
        XCTAssertEqual(policy.reasons(now: 0, mouseInMenuBar: true, preferencesEditing: true,
                                      ownedMenuTracking: true, menuBarNavigation: true, recentKeyboardInput: false),
                       AutoCollapseDeferral.Reason.allCases)
    }

    func testStaleMenuTrackingAndAXFocusExpireWithoutSleeping() {
        var policy = AutoCollapseDeferral()
        XCTAssertEqual(policy.reasons(now: 0, mouseInMenuBar: false, preferencesEditing: false,
                                      ownedMenuTracking: true, menuBarNavigation: true, recentKeyboardInput: false),
                       [.ownedMenuTracking, .menuBarNavigation])
        XCTAssertTrue(policy.reasons(now: 60, mouseInMenuBar: false, preferencesEditing: false,
                                     ownedMenuTracking: true, menuBarNavigation: true, recentKeyboardInput: false).isEmpty)
        XCTAssertTrue(policy.reasons(now: 90, mouseInMenuBar: false, preferencesEditing: false,
                                     ownedMenuTracking: true, menuBarNavigation: true, recentKeyboardInput: false).isEmpty)
    }

    func testRealKeyboardInteractionResetsOnlyTheIdleDeferralBound() {
        var policy = AutoCollapseDeferral()
        _ = policy.reasons(now: 0, mouseInMenuBar: false, preferencesEditing: false,
                           ownedMenuTracking: false, menuBarNavigation: true, recentKeyboardInput: false)
        XCTAssertEqual(policy.reasons(now: 60, mouseInMenuBar: false, preferencesEditing: false,
                                      ownedMenuTracking: false, menuBarNavigation: true, recentKeyboardInput: true),
                       [.menuBarNavigation])
        XCTAssertTrue(policy.reasons(now: 120, mouseInMenuBar: false, preferencesEditing: false,
                                     ownedMenuTracking: false, menuBarNavigation: true, recentKeyboardInput: false).isEmpty)
    }

    func testPointerAndActivePreferencesEditingRemainProtected() {
        var policy = AutoCollapseDeferral()
        for now: TimeInterval in [0, 60, 600] {
            XCTAssertEqual(policy.reasons(now: now, mouseInMenuBar: true, preferencesEditing: true,
                                          ownedMenuTracking: false, menuBarNavigation: false, recentKeyboardInput: false),
                           [.mouseInMenuBar, .preferencesEditing])
        }
    }

    // A key press on the focused arrow is not a mouse event and must toggle,
    // not flip the always-hidden separators.
    func testKeyboardActivationToggles() {
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .keyDown, modifiers: [], alwaysHiddenSectionEnabled: true), .toggle)
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .keyUp, modifiers: [], alwaysHiddenSectionEnabled: false), .toggle)
    }

    // With "Automatically hide and show the menu bar" the visible frame reaches
    // the top of the screen, so the band must come from the bar's thickness.
    func testMenuBarBandUsesThicknessWhenBarAutoHides() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(MenuBarBand.minY(frame: frame, visibleFrame: frame, thickness: 24), 776)
    }

    func testMenuBarBandUsesVisibleFrameWhenBarIsShown() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 776)
        XCTAssertEqual(MenuBarBand.minY(frame: frame, visibleFrame: visible, thickness: 24), 776)
    }

    func testNestedCollapseIsRefusedUntilOuterOneFinishes() {
        var gate = CollapseGate()
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin())
        XCTAssertTrue(gate.isCollapsing)
        gate.end()
        XCTAssertFalse(gate.isCollapsing)
        XCTAssertTrue(gate.begin())
    }

    // A background re-activation that failed leaves the engine expanded; the
    // arrow must follow the engine instead of keeping the collapsed glyph.
    func testGlyphFollowsEngineStateAfterBackgroundChange() {
        XCTAssertTrue(EngineStatePresentation.showsCollapsedGlyph(state: .collapsed, problem: nil))
        XCTAssertFalse(EngineStatePresentation.showsCollapsedGlyph(state: .expanded, problem: .activationFailed))
        XCTAssertTrue(EngineStatePresentation.showsCollapsedGlyph(state: .expanded, problem: .restoreFailed))
        XCTAssertFalse(EngineStatePresentation.showsCollapsedGlyph(state: .expanded, problem: nil))
    }

    func testFailedLaunchRecoveryBlocksInitialCollapse() {
        XCTAssertFalse(InitialCollapsePolicy.shouldCollapse(launchRecovered: false))
        XCTAssertTrue(InitialCollapsePolicy.shouldCollapse(launchRecovered: true))
    }
}
