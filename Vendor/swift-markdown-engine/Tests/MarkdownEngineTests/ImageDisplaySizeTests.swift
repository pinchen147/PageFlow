//
//  ImageDisplaySizeTests.swift
//  MarkdownEngineTests
//
//  How an image is sized: without a width token never upscaled, capped by the
//  column width and by a maximum height; with one, that width within the
//  column and no height cap (doc 26 §2.5).
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

    @Test("an explicit width is the author's size: the column caps it, the height cap does not")
    func requestedWidth() {
        let asked = style.displaySize(natural: CGSize(width: 1_206, height: 2_622), requestedWidth: 200, maxWidth: 700)
        #expect(asked.width == 200)
        let portrait = style.displaySize(natural: CGSize(width: 1_170, height: 2_532), requestedWidth: 600, maxWidth: 700)
        #expect(portrait.width == 600, "width honoured")
        #expect(abs(portrait.height - 600 * 2_532 / 1_170) < 0.01, "height from the aspect ratio, past 480")
        let tooWide = style.displaySize(natural: CGSize(width: 1_000, height: 100), requestedWidth: 5_000, maxWidth: 700)
        #expect(tooWide.width == 700)
        let upscaled = style.displaySize(natural: CGSize(width: 100, height: 50), requestedWidth: 300, maxWidth: 700)
        #expect(upscaled == CGSize(width: 300, height: 150), "an explicit width may upscale")
    }

    @Test("an explicit width is at least 40 (the resize minimum), not the 50 of a natural size")
    func explicitMinimum() {
        let tiny = style.displaySize(natural: CGSize(width: 400, height: 200), requestedWidth: 30, maxWidth: 700)
        #expect(tiny == CGSize(width: 40, height: 20))
        let natural = style.displaySize(natural: CGSize(width: 30, height: 30), maxWidth: 700)
        #expect(natural.width == 50, "no token: today's 50 minimum stands")
    }
}
