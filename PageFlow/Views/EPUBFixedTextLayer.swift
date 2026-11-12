//
//  EPUBFixedTextLayer.swift
//  PageFlow
//
//  The text of a fixed-layout page: each positioned block set on its own, in
//  page units, drawn scaled to the page. `EPUBPageTextView` hosts it: drawing,
//  hit testing and line rects come from here, while its own storage still
//  holds the chapter's text for words, links and attachments. Painted ranges
//  are copied in from the page's usual paint.
//

import AppKit
import EPUBKit

final class EPUBFixedTextLayer {
    private struct Block {
        let range: NSRange
        let frame: CGRect
        let storage: NSTextStorage
        let layout: NSLayoutManager
        let container: NSTextContainer
    }

    /// A line wider than any page, for text that never wraps.
    private static let unwrappedWidth: CGFloat = 1_000_000

    let page: EPUBFixedPage
    private let blocks: [Block]

    init(page: EPUBFixedPage) {
        self.page = page
        blocks = page.blocks.compactMap { block in
            guard NSMaxRange(block.range) <= page.text.length else { return nil }
            let storage = NSTextStorage(attributedString: page.text.attributedSubstring(from: block.range))
            let layout = NSLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(containerSize: CGSize(width: min(block.frame.width, Self.unwrappedWidth),
                                                                  height: Self.unwrappedWidth))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            return Block(range: block.range, frame: block.frame, storage: storage, layout: layout, container: container)
        }
    }

    /// Draws every block; `scale` is view points per page unit.
    func draw(scale: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.scale(by: scale)
        transform.concat()
        for block in blocks {
            let glyphs = block.layout.glyphRange(for: block.container)
            block.layout.drawBackground(forGlyphRange: glyphs, at: block.frame.origin)
            block.layout.drawGlyphs(forGlyphRange: glyphs, at: block.frame.origin)
        }
    }

    /// Takes the page's painted ranges (highlights, Find, the selection, the
    /// spoken word) from the layout manager they were painted on.
    func copyPaint(from source: NSLayoutManager, keys: [NSAttributedString.Key]) {
        for block in blocks {
            let local = NSRange(location: 0, length: block.storage.length)
            for key in keys { block.layout.removeTemporaryAttribute(key, forCharacterRange: local) }
            var index = block.range.location
            while index < NSMaxRange(block.range) {
                var effective = NSRange()
                let attributes = source.temporaryAttributes(atCharacterIndex: index, effectiveRange: &effective)
                let run = NSIntersectionRange(effective, block.range)
                guard run.length > 0 else { break }
                if !attributes.isEmpty {
                    block.layout.addTemporaryAttributes(attributes, forCharacterRange:
                        NSRange(location: run.location - block.range.location, length: run.length))
                }
                index = NSMaxRange(run)
            }
        }
    }

    /// Paper shows only what the text itself carries.
    func bakePaint() {
        for block in blocks { block.layout.bakeTemporaryAttributes() }
    }

    private func block(holding index: Int) -> Block? {
        blocks.first { NSLocationInRange(index, $0.range) }
    }

    /// The block under a point in page units, or the nearest.
    private func nearestBlock(to point: CGPoint) -> Block? {
        func distance(_ block: Block) -> CGFloat {
            let used = usedRect(of: block)
            let dx = max(used.minX - point.x, 0, point.x - used.maxX)
            let dy = max(used.minY - point.y, 0, point.y - used.maxY)
            return dx * dx + dy * dy
        }
        return blocks.min { distance($0) < distance($1) }
    }

    /// Where the page's text is, in page units.
    var textRects: [CGRect] { blocks.map(usedRect(of:)) }

    /// Where the page's links are drawn, in page units: their text, and any
    /// image that is one.
    var linkRects: [CGRect] {
        var rects: [CGRect] = []
        for block in blocks {
            block.layout.ensureLayout(for: block.container)
            let whole = NSRange(location: 0, length: block.storage.length)
            block.storage.enumerateAttribute(.link, in: whole) { value, range, _ in
                guard value != nil else { return }
                let glyphs = block.layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                block.layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs,
                                                     in: block.container) { rect, _ in
                    rects.append(rect.offsetBy(dx: block.frame.minX, dy: block.frame.minY))
                }
            }
        }
        let text = page.text
        for layer in page.layers {
            guard let slot = layer.slot, slot < text.length,
                  text.attribute(.link, at: slot, effectiveRange: nil) != nil else { continue }
            rects.append(layer.frame)
        }
        return rects
    }

    /// A block's text in page units.
    private func usedRect(of block: Block) -> CGRect {
        block.layout.ensureLayout(for: block.container)
        return block.layout.usedRect(for: block.container)
            .offsetBy(dx: block.frame.minX, dy: block.frame.minY)
    }

    /// The character drawn under a point in page units.
    func characterIndex(at point: CGPoint) -> Int? {
        for block in blocks where usedRect(of: block).contains(point) {
            let inside = CGPoint(x: point.x - block.frame.minX, y: point.y - block.frame.minY)
            var fraction: CGFloat = 0
            let glyph = block.layout.glyphIndex(for: inside, in: block.container, fractionOfDistanceThroughGlyph: &fraction)
            let rect = block.layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: block.container)
            if rect.contains(inside) { return block.range.location + block.layout.characterIndexForGlyph(at: glyph) }
        }
        return nil
    }

    /// The caret place nearest a point in page units; 0 on a page with no text.
    func insertionIndex(at point: CGPoint) -> Int {
        guard let block = nearestBlock(to: point) else { return 0 }
        let inside = CGPoint(x: point.x - block.frame.minX, y: point.y - block.frame.minY)
        var fraction: CGFloat = 0
        let glyph = block.layout.glyphIndex(for: inside, in: block.container, fractionOfDistanceThroughGlyph: &fraction)
        let character = block.layout.characterIndexForGlyph(at: glyph)
        return block.range.location + (fraction > 0.5 ? min(character + 1, block.storage.length) : character)
    }

    /// The block and glyph holding a character; a character between blocks
    /// has the next block's first.
    private func glyph(at index: Int) -> (block: Block, glyph: Int)? {
        guard let block = block(holding: index) ?? blocks.first(where: { $0.range.location > index }) ?? blocks.last else { return nil }
        block.layout.ensureLayout(for: block.container)
        let local = min(max(0, index - block.range.location), block.storage.length - 1)
        guard local >= 0 else { return nil }
        return (block, block.layout.glyphIndexForCharacter(at: local))
    }

    /// The line holding a character, in page units.
    func lineRect(at index: Int) -> CGRect? {
        guard let (block, glyph) = glyph(at: index) else { return nil }
        return block.layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            .offsetBy(dx: block.frame.minX, dy: block.frame.minY)
    }

    /// The characters of the line holding a character, in the page's offsets.
    func lineRange(at index: Int) -> NSRange? {
        guard let (block, glyph) = glyph(at: index) else { return nil }
        var glyphs = NSRange()
        _ = block.layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphs)
        let characters = block.layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        return NSRange(location: block.range.location + characters.location, length: characters.length)
    }
}
