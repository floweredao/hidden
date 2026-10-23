//
//  ModelTests.swift
//  HiddenBarTests
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import XCTest

// The key codes used here are ones the description names itself (Return,
// Delete, Space, F-keys), so no test depends on the keyboard layout of the
// machine that runs it.
private func keybind(function: Bool = false, control: Bool = false, command: Bool = false,
                     shift: Bool = false, option: Bool = false, capsLock: Bool = false,
                     characters: String? = nil, keyCode: UInt32) -> GlobalKeybindPreferences {
    return GlobalKeybindPreferences(function: function, control: control, command: command,
                                    shift: shift, option: option, capsLock: capsLock,
                                    carbonFlags: 0, characters: characters, keyCode: keyCode)
}

final class GlobalKeybindPreferencesTests: XCTestCase {

    func testNamedKeysUseTheirSymbols() {
        XCTAssertEqual(keybind(keyCode: 36).description, "⏎")
        XCTAssertEqual(keybind(keyCode: 51).description, "⌫")
        XCTAssertEqual(keybind(keyCode: 49).description, "⎵")
    }

    // F-keys arrive with the function flag set; they read "F18", not "FnF18" (#191).
    func testFunctionKeysShowTheirNameWithoutFn() {
        XCTAssertEqual(keybind(function: true, keyCode: 122).description, "F1")
        XCTAssertEqual(keybind(function: true, keyCode: 79).description, "F18")
        XCTAssertEqual(keybind(function: true, control: true, keyCode: 90).description, "⌃F20")
    }

    func testFnIsShownForOtherKeysPressedWithFunction() {
        XCTAssertEqual(keybind(function: true, keyCode: 51).description, "Fn⌫")
    }

    func testCapsLockFollowsTheOtherModifiers() {
        XCTAssertEqual(keybind(control: true, capsLock: true, keyCode: 36).description, "⌃⇪⏎")
    }

    // What Preferences stores: the JSON the shortcut was saved as must still
    // decode into the same shortcut.
    func testStoredShortcutDecodes() throws {
        let json = #"{"function":false,"control":true,"command":true,"shift":false,"option":false,"capsLock":false,"carbonFlags":4352,"characters":"\r","keyCode":36}"#
        let decoded = try JSONDecoder().decode(GlobalKeybindPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.keyCode, 36)
        XCTAssertEqual(decoded.carbonFlags, 4352)
        XCTAssertEqual(decoded.description, "⌃⌘⏎")
    }

    func testRoundTripKeepsEveryField() throws {
        let original = keybind(function: true, control: true, command: true, shift: true,
                               option: true, capsLock: true, characters: "x", keyCode: 79)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GlobalKeybindPreferences.self, from: data)
        XCTAssertEqual(decoded.function, true)
        XCTAssertEqual(decoded.control, true)
        XCTAssertEqual(decoded.command, true)
        XCTAssertEqual(decoded.shift, true)
        XCTAssertEqual(decoded.option, true)
        XCTAssertEqual(decoded.capsLock, true)
        XCTAssertEqual(decoded.characters, "x")
        XCTAssertEqual(decoded.keyCode, 79)
        XCTAssertEqual(decoded.description, original.description)
    }
}

final class SelectedSecondTests: XCTestCase {

    func testEachChoiceHasItsDelay() {
        XCTAssertEqual(SelectedSecond.fiveSeconds.toSeconds(), 5)
        XCTAssertEqual(SelectedSecond.tenSeconds.toSeconds(), 10)
        XCTAssertEqual(SelectedSecond.fifteenSeconds.toSeconds(), 15)
        XCTAssertEqual(SelectedSecond.thirdtySeconds.toSeconds(), 30)
        XCTAssertEqual(SelectedSecond.oneMinus.toSeconds(), 60)
    }

    // The Settings pop-up selects by position, so every delay must lead back to
    // the item it came from.
    func testEveryChoiceRoundTripsThroughItsDelay() {
        for position in 0...4 {
            guard let choice = SelectedSecond(rawValue: position) else {
                return XCTFail("no choice at position \(position)")
            }
            XCTAssertEqual(SelectedSecond.secondToPossition(seconds: choice.toSeconds()), position)
        }
        XCTAssertNil(SelectedSecond(rawValue: 5))
    }

    // A never-set preference reads as 0 seconds; it and any unknown value show
    // the first item.
    func testUnknownDelaysSelectTheFirstChoice() {
        XCTAssertEqual(SelectedSecond.secondToPossition(seconds: 0), 0)
        XCTAssertEqual(SelectedSecond.secondToPossition(seconds: 45), 0)
    }
}
