//
//  EPUBPaginator.swift
//  PageFlow
//
//  Page splitting for the EPUB reader's paged mode.
//

import AppKit
import EPUBKit
import Foundation

/// Splits a rendered chapter into page-sized character ranges using TextKit,
/// the same engine the reading surface draws with, so a page turn never
/// disagrees with what fits on screen.
nonisolated enum EPUBPaginator {
    static func pages(in text: NSAttributedString, pageSize: CGSize) -> [NSRange] {
        guard text.length > 0, pageSize.width > 20, pageSize.height > 20 else { return [] }
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)

        // A vertical chapter's lines run down the page and stack across it.
        let vertical = EPUBWriting.isVertical(text)
        let lineSize = vertical ? CGSize(width: pageSize.height, height: pageSize.width) : pageSize
        var ranges: [NSRange] = []
        while true {
            let container = vertical ? EPUBVerticalTextContainer(containerSize: lineSize)
                : NSTextContainer(containerSize: lineSize)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            var glyphs = layout.glyphRange(for: container)
            guard glyphs.length > 0 else { break }
            // A heading never ends a page: the page stops above it, so it
            // opens the next one with the text it introduces.
            if let cut = headingCut(on: layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil),
                                    in: storage, layout: layout) {
                container.size = CGSize(width: lineSize.width, height: cut)
                layout.ensureLayout(for: container)
                glyphs = layout.glyphRange(for: container)
            }
            ranges.append(layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
            if NSMaxRange(glyphs) >= layout.numberOfGlyphs { break }
        }
        return ranges
    }

    /// Where to end a page that would end on a heading (or a run of them,
    /// a chapter title over a section title): the top of its first line.
    /// Nil when the page doesn't end on one, the heading opens the page, or
    /// nothing follows it.
    private static func headingCut(on page: NSRange, in storage: NSTextStorage, layout: NSLayoutManager) -> CGFloat? {
        let end = NSMaxRange(page)
        guard end < storage.length, end > page.location else { return nil }
        let string = storage.string as NSString
        func isHeading(_ location: Int) -> Bool {
            ((storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?
                .headerLevel ?? 0) > 0
        }
        var start = string.paragraphRange(for: NSRange(location: end - 1, length: 0)).location
        guard isHeading(start) else { return nil }
        while start > page.location {
            let previous = string.paragraphRange(for: NSRange(location: start - 1, length: 0)).location
            guard isHeading(previous) else { break }
            start = previous
        }
        guard start > page.location else { return nil }
        let glyph = layout.glyphIndexForCharacter(at: start)
        let top = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
        return top > 0 ? top : nil
    }

    /// The page containing a character offset, so resume and search land on
    /// the page the reader expects rather than the chapter start.
    static func pageIndex(containing characterOffset: Int, in pages: [NSRange]) -> Int {
        for (index, range) in pages.enumerated() where NSLocationInRange(characterOffset, range) {
            return index
        }
        return characterOffset <= 0 ? 0 : max(0, pages.count - 1)
    }
}
