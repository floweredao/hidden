//
//  AssetsTests.swift
//  HiddenBarTests
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit
import XCTest

// The arrow points toward the hidden icons while collapsed and away from them
// while expanded. They sit on the hidden side of the arrow: its left in a
// left-to-right layout, its right otherwise (MenuBarOrder.isItem).
final class AssetsTests: XCTestCase {

    private var savedIsLTR = false

    override func setUp() {
        super.setUp()
        savedIsLTR = Constant.isUsingLTRLanguage
    }

    override func tearDown() {
        Constant.isUsingLTRLanguage = savedIsLTR
        super.tearDown()
    }

    private func chevron(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        let configured = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        configured?.isTemplate = true
        return configured
    }

    // Draws the image into a fixed-size bitmap so two images compare by what
    // they show, not by object identity.
    private func pixels(of image: NSImage?) -> Data? {
        guard let image = image,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let bytes = rep.bitmapData else { return nil }
        return Data(bytes: bytes, count: rep.bytesPerRow * rep.pixelsHigh)
    }

    private func assertShows(_ image: NSImage?, _ expected: String, not other: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let expectedPixels = pixels(of: chevron(expected))
        let otherPixels = pixels(of: chevron(other))
        XCTAssertNotNil(expectedPixels, file: file, line: line)
        XCTAssertNotEqual(expectedPixels, otherPixels, file: file, line: line)
        let shown = pixels(of: image)
        XCTAssertNotNil(shown, file: file, line: line)
        XCTAssertEqual(shown, expectedPixels, "expected \(expected)", file: file, line: line)
    }

    func testLeftToRightArrowPointsLeftWhileCollapsed() {
        Constant.isUsingLTRLanguage = true
        assertShows(Assets.expandImage, "chevron.left", not: "chevron.right")
        assertShows(Assets.collapseImage, "chevron.right", not: "chevron.left")
    }

    func testRightToLeftArrowPointsRightWhileCollapsed() {
        Constant.isUsingLTRLanguage = false
        assertShows(Assets.expandImage, "chevron.right", not: "chevron.left")
        assertShows(Assets.collapseImage, "chevron.left", not: "chevron.right")
    }

    // Template images follow the menu bar's light or dark appearance.
    func testArrowsAreTemplates() {
        XCTAssertEqual(Assets.expandImage?.isTemplate, true)
        XCTAssertEqual(Assets.collapseImage?.isTemplate, true)
    }
}
