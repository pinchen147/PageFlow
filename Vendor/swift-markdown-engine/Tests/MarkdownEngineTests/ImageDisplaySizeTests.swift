//
//  ImageDisplaySizeTests.swift
//  MarkdownEngineTests
//
//  How an embedded image is sized: never upscaled, capped by the column width
//  and by a maximum height, a requested width honoured within those caps.
//

import CoreGraphics
import Testing
@testable import MarkdownEngine

@Suite("Image display size")
struct ImageDisplaySizeTests {
    private let style = ImageEmbedStyle(minimumWidth: 50, maximumHeight: 480)

    @Test("a tall phone screenshot is scaled to the height cap, aspect kept")
    func tallImageIsCappedByHeight() {
        let size = style.displaySize(natural: CGSize(width: 1_206, height: 2_622), maxWidth: 700)
        #expect(size.height == 480)
        #expect(abs(size.width - 1_206 * 480 / 2_622) < 0.01)
    }

    @Test("a wide image is capped by the column; a small one keeps its natural size")
    func widthCapAndNoUpscale() {
        let wide = style.displaySize(natural: CGSize(width: 2_000, height: 400), maxWidth: 700)
        #expect(wide.width == 700 && wide.height == 140)
        let small = style.displaySize(natural: CGSize(width: 120, height: 80), maxWidth: 700)
        #expect(small == CGSize(width: 120, height: 80))
    }

    @Test("a requested width wins within the caps")
    func requestedWidth() {
        let asked = style.displaySize(natural: CGSize(width: 1_206, height: 2_622), requestedWidth: 200, maxWidth: 700)
        #expect(asked.width == 200)
        let tooTall = style.displaySize(natural: CGSize(width: 1_000, height: 4_000), requestedWidth: 600, maxWidth: 700)
        #expect(tooTall.height == 480, "the height cap still holds")
        let tooWide = style.displaySize(natural: CGSize(width: 1_000, height: 100), requestedWidth: 5_000, maxWidth: 700)
        #expect(tooWide.width == 700)
    }

    @Test("`![alt|300](url)` asks for 300 points; anything else asks for nothing")
    func altWidthSuffix() {
        #expect(MarkdownStyler.requestedWidth(inAlt: "photo|300") == 300)
        #expect(MarkdownStyler.requestedWidth(inAlt: "a|b|250 ") == 250)
        #expect(MarkdownStyler.requestedWidth(inAlt: "photo") == nil)
        #expect(MarkdownStyler.requestedWidth(inAlt: "photo|big") == nil)
        #expect(MarkdownStyler.requestedWidth(inAlt: "photo|0") == nil)
    }
}
