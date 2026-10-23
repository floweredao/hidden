//
//  StringExtensionTests.swift
//  HiddenBarTests
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import XCTest

// NativeVisibilityBridge.swift, compiled into this bundle, localizes its open
// panel text, so `localized` must be part of the bundle too or nothing here
// builds.
final class StringExtensionTests: XCTestCase {

    // The test bundle carries no Localizable.strings, so a key comes back as is,
    // the same fallback the app shows for a missing translation.
    func testLocalizedFallsBackToTheKey() {
        XCTAssertEqual("Allow".localized, "Allow")
    }
}
