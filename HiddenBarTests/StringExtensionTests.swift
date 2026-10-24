//
//  StringExtensionTests.swift
//  HiddenBarTests
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import XCTest

// String+Extension.swift is compiled straight into this bundle, which has no
// host app.
final class StringExtensionTests: XCTestCase {

    // The test bundle carries no Localizable.strings, so a key comes back as is,
    // the same fallback the app shows for a missing translation.
    func testLocalizedFallsBackToTheKey() {
        XCTAssertEqual("Allow".localized, "Allow")
    }
}
