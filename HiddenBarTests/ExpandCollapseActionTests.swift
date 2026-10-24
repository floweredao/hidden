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

    func testSecondaryClickDoesNothingWithoutAlwaysHiddenSection() {
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .rightMouseUp, modifiers: [], alwaysHiddenSectionEnabled: false), .none)
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .leftMouseUp, modifiers: .control, alwaysHiddenSectionEnabled: false), .none)
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .leftMouseUp, modifiers: [], alwaysHiddenSectionEnabled: false), .toggle)
    }

    func testOptionLeftTogglesAlwaysHidden() {
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .leftMouseUp, modifiers: .option, alwaysHiddenSectionEnabled: true), .toggleSeparators)
    }

    func testOptionRightTogglesAlwaysHidden() {
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .rightMouseUp, modifiers: .option, alwaysHiddenSectionEnabled: true), .toggleSeparators)
    }

    func testOtherMouseEventTogglesSeparators() {
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .otherMouseUp, modifiers: [], alwaysHiddenSectionEnabled: true), .toggleSeparators)
    }

    // On macOS 27 the button's mouse-up event arrives with no modifier flags
    // while a modifier is physically held; the live flags must still count.
    func testModifiersComeFromLiveFlagsWhenEventFlagsAreEmpty() {
        let modifiers = ExpandCollapseActionResolver.modifiers(eventFlags: [], liveFlags: .option)
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .leftMouseUp, modifiers: modifiers, alwaysHiddenSectionEnabled: true), .toggleSeparators)
    }

    func testModifiersComeFromEventFlags() {
        XCTAssertTrue(ExpandCollapseActionResolver.modifiers(eventFlags: .control, liveFlags: []).contains(.control))
    }

    func testNoModifiersWithoutEventOrLiveFlags() {
        XCTAssertEqual(ExpandCollapseActionResolver.modifiers(eventFlags: nil, liveFlags: []), [])
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



}

private final class FakeMenuBarEngine: MenuBarEngine {
    var isArrangementValid = true
    var isAlwaysHiddenSeparatorPlaced = true
    var calls: [(Bool, Bool)] = []
    var onApply: ((Bool, Bool) -> Void)?
    func apply(collapsed: Bool, alwaysHiddenShown: Bool) {
        calls.append((collapsed, alwaysHiddenShown))
        onApply?(collapsed, alwaysHiddenShown)
    }
    func invalidateLayout() {}
    func refreshArrangement() {}
    func restoreAll() -> Bool { true }
}

final class MenuBarStateMachineTests: XCTestCase {
    func testGesturesRenderBeforeExactlyOneEngineCall() {
        let engine = FakeMenuBarEngine()
        var now: TimeInterval = 0
        var glyphCollapsed = false
        var displayedAlwaysHidden = false
        let state = MenuBarStateMachine(engine: engine, alwaysHiddenShown: false, clock: { now }) {
            glyphCollapsed = $0
            displayedAlwaysHidden = $1
        }
        engine.onApply = { collapsed, shown in
            XCTAssertEqual(glyphCollapsed, collapsed)
            XCTAssertEqual(displayedAlwaysHidden, shown)
        }
        XCTAssertTrue(state.perform(.toggle, alwaysHiddenEnabled: true))
        XCTAssertTrue(state.isCollapsed)
        XCTAssertEqual(engine.calls.count, 1)
        now = 0.3
        XCTAssertTrue(state.perform(.toggleSeparators, alwaysHiddenEnabled: true))
        XCTAssertFalse(state.isCollapsed)
        XCTAssertTrue(state.alwaysHiddenShown)
        XCTAssertEqual(engine.calls.count, 2)
        now = 1
        XCTAssertTrue(state.perform(.toggle, alwaysHiddenEnabled: true))
        XCTAssertEqual(engine.calls.count, 3)
    }

    func testDebounceStartsAfterLastAcceptedGesture() {
        let engine = FakeMenuBarEngine()
        var now: TimeInterval = 0
        let state = MenuBarStateMachine(engine: engine, alwaysHiddenShown: true, clock: { now }) { _, _ in }
        XCTAssertTrue(state.perform(.toggle, alwaysHiddenEnabled: true))
        now = 0.29
        XCTAssertFalse(state.perform(.toggle, alwaysHiddenEnabled: true))
        now = 0.3
        XCTAssertTrue(state.perform(.toggle, alwaysHiddenEnabled: true))
        now = 0.59
        XCTAssertFalse(state.perform(.toggleSeparators, alwaysHiddenEnabled: true))
        XCTAssertEqual(engine.calls.count, 2)
    }

    func testInvalidArrangementAndDisabledSecondaryActionMakeNoCalls() {
        let engine = FakeMenuBarEngine()
        engine.isArrangementValid = false
        let state = MenuBarStateMachine(engine: engine, alwaysHiddenShown: true) { _, _ in
            XCTFail("A refused gesture must not render")
        }
        XCTAssertFalse(state.perform(.toggle, alwaysHiddenEnabled: true))
        XCTAssertFalse(state.perform(.toggleSeparators, alwaysHiddenEnabled: false))
        engine.isAlwaysHiddenSeparatorPlaced = false
        XCTAssertFalse(state.perform(.toggleSeparators, alwaysHiddenEnabled: true))
        XCTAssertFalse(state.perform(.none, alwaysHiddenEnabled: false))
        XCTAssertFalse(state.collapse())
        XCTAssertTrue(engine.calls.isEmpty)
    }

    func testLaunchAppliesStoredStateBeforeInitialCollapse() {
        let engine = FakeMenuBarEngine()
        let state = MenuBarStateMachine(engine: engine, alwaysHiddenShown: false) { _, _ in }
        state.synchronize()
        XCTAssertFalse(engine.calls[0].0)
        XCTAssertFalse(engine.calls[0].1)
        state.collapse()
        XCTAssertTrue(engine.calls[1].0)
        XCTAssertFalse(engine.calls[1].1)
        state.collapse()
        XCTAssertEqual(engine.calls.count, 2)
    }

    func testPreferencesToggleForcesAlwaysHiddenShownWithoutRestart() {
        let engine = FakeMenuBarEngine()
        let state = MenuBarStateMachine(engine: engine, alwaysHiddenShown: false) { _, _ in }
        state.alwaysHiddenSectionToggled()
        XCTAssertTrue(state.alwaysHiddenShown)
        XCTAssertEqual(engine.calls.count, 1)
        XCTAssertTrue(engine.calls[0].1)
        state.collapse()
        let before = engine.calls.count
        state.alwaysHiddenSectionToggled()
        XCTAssertTrue(state.isCollapsed)
        XCTAssertTrue(state.alwaysHiddenShown)
        XCTAssertEqual(engine.calls.count, before + 1)
    }
}
