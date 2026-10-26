//
//  HeadingHelpers.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Small helper values for heading size/spacing, plus shared text measurements.
import AppKit

enum HeadingHelpers {

    /// Use heading context to scale LaTeX font size consistently with surrounding text.
    static func latexFontSize(
        for token: MarkdownToken,
        headings: [MarkdownToken],
        baseFont: NSFont,
        configuration: HeadingStyle = .default
    ) -> CGFloat {
        if let headingToken = headings.first(where: { NSLocationInRange(token.contentRange.location, $0.contentRange) }) {
            let level = headingToken.markerRanges.first?.length ?? 1
            return baseFont.pointSize * configuration.fontMultiplier(for: level)
        }
        return baseFont.pointSize
    }

    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// The width to kern a HIDDEN run out of the line (a collapsed block's
    /// source, an inline formula's text): the sum of its characters' advances,
    /// never less than the run's laid-out width, from a per-font advance table.
    /// `textWidth` lays the text out (a 500-character table source is ~2 ms;
    /// the 500 KB owner note re-measured seventy of them per restyle), while the
    /// exact value is immaterial: the kern only has to pull every hidden glyph
    /// behind the anchor, and a larger pull is the same invisible result.
    static func hiddenRunWidth(_ text: String, font: NSFont) -> CGFloat {
        let key = FontKey(name: font.fontName, size: font.pointSize)
        advanceLock.lock()
        var table = advanceTables[key] ?? [:]
        advanceLock.unlock()
        let fallback = font.maximumAdvancement.width
        var width: CGFloat = 0
        var changed = false
        for unit in text.utf16 {
            if let known = table[unit] {
                width += known
                continue
            }
            var glyph: CGGlyph = 0
            var character = unit
            let mapped = CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
            var advance: CGFloat = fallback
            if mapped, glyph != 0 {
                var size = CGSize.zero
                CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &size, 1)
                advance = max(size.width, 0)
            }
            table[unit] = advance
            changed = true
            width += advance
        }
        if changed {
            advanceLock.lock()
            advanceTables[key] = table
            advanceLock.unlock()
        }
        return width
    }

    private struct FontKey: Hashable {
        let name: String
        let size: CGFloat
    }
    private static let advanceLock = NSLock()
    nonisolated(unsafe) private static var advanceTables: [FontKey: [UInt16: CGFloat]] = [:]

    static func checkboxExtraSpacing(
        font: NSFont,
        configuration: CheckboxStyle = .default
    ) -> CGFloat {
        max(
            configuration.minimumExtraSpacing,
            ceil(font.pointSize * configuration.extraSpacingPerFontPointFraction)
        )
    }
}
