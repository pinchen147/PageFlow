//
//  EPUBTextStyling.swift
//  PageFlow
//
//  Typography application for the EPUB reader's rendered chapters.
//

import AppKit
import CoreText
import EPUBKit
import Foundation

/// Applies the reader's typography choices to a rendered EPUB chapter. The
/// package renders semantic fonts and block spacing at a fixed base size
/// (18pt body); styling scales those rather than re-parsing XHTML, so a
/// typography change never touches the archive again.
nonisolated enum EPUBTextStyling {
    static let baseBodySize: CGFloat = 18

    /// `textWidth` is the page's text width: a table too wide for it gets
    /// smaller text, down to `smallestTables`.
    static func applying(_ typography: EPUBTypography, palette: EPUBPagePalette,
                         to text: NSAttributedString, textWidth: CGFloat? = nil,
                         smallestTables: TableFloor = .screen) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: result.length)
        let scale = CGFloat(typography.fontSize) / baseBodySize

        let fontName = typography.installedFontName
        result.enumerateAttribute(.font, in: full) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let styled = styledFont(font, family: typography.family, named: fontName,
                                    size: max(9, font.pointSize * scale))
            result.addAttribute(.font, value: styled, range: range)
            let italic = font.fontDescriptor.symbolicTraits.contains(.italic)
            if italic || ((typography.family == .serif || fontName != nil) && !styled.isFixedPitch) {
                pinFallbackFonts(in: result, range: range, primary: styled, slanted: italic)
            }
        }

        // Blocks share styles; scale each distinct one once.
        var scaled: [ObjectIdentifier: NSParagraphStyle] = [:]
        var tables = EPUBTextBlockStyler(scale: scale, borderColor: tableBorderColor(for: palette), textWidth: textWidth)
        result.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            guard let source = value as? NSParagraphStyle else { return }
            let key = ObjectIdentifier(source)
            let style = scaled[key] ?? scaledParagraph(source, scale: scale, typography: typography, tables: &tables)
            scaled[key] = style
            result.addAttribute(.paragraphStyle, value: style, range: range)
        }
        if let textWidth { shrinkWideTables(in: result, toFit: textWidth, scale: scale, floor: smallestTables) }
        fitCombinedRuns(in: result)
        reserveRubyRoom(in: result)

        // Superscripts and subscripts stay as far off the baseline, relatively.
        result.enumerateAttribute(.baselineOffset, in: full) { value, range, _ in
            guard let offset = value as? NSNumber else { return }
            result.addAttribute(.baselineOffset, value: CGFloat(offset.doubleValue) * scale, range: range)
        }

        let textColor = themeTextColor(for: palette)
        result.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            guard let color = value as? NSColor, color == NSColor.labelColor else { return }
            result.addAttribute(.foregroundColor, value: textColor, range: range)
        }

        // Links read as part of the text, marked only by a faint underline.
        let underline = linkUnderlineColor(for: palette)
        result.enumerateAttribute(.link, in: full) { value, range, _ in
            guard value != nil else { return }
            result.addAttributes([
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: underline
            ], range: range)
        }
        return result
    }

    /// Swaps one theme's text, link and table border colours for another's,
    /// leaving fonts and every page break untouched.
    static func recoloring(_ text: NSAttributedString, from old: EPUBPagePalette,
                           to new: EPUBPagePalette) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: result.length)
        for (key, oldColor, newColor) in [
            (NSAttributedString.Key.foregroundColor, themeTextColor(for: old), themeTextColor(for: new)),
            (.underlineColor, linkUnderlineColor(for: old), linkUnderlineColor(for: new))
        ] {
            result.enumerateAttribute(key, in: full) { value, range, _ in
                guard let color = value as? NSColor, color == oldColor else { return }
                result.addAttribute(key, value: newColor, range: range)
            }
        }
        // Table borders: same blocks and sizes, so the same page breaks.
        var tables = EPUBTextBlockStyler(scale: 1, borderColor: tableBorderColor(for: new))
        var recolored: [ObjectIdentifier: NSParagraphStyle] = [:]
        result.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            guard let source = value as? NSParagraphStyle, !source.textBlocks.isEmpty else { return }
            let key = ObjectIdentifier(source)
            let style = recolored[key] ?? {
                let copy = source.mutableCopy() as! NSMutableParagraphStyle
                copy.textBlocks = tables.restyled(source.textBlocks)
                return copy
            }()
            recolored[key] = style
            result.addAttribute(.paragraphStyle, value: style, range: range)
        }
        return result
    }

    /// The rules between table cells: the text colour, faint.
    static func tableBorderColor(for palette: EPUBPagePalette) -> NSColor {
        themeTextColor(for: palette).withAlphaComponent(0.3)
    }

    /// The smallest a wide table's text gets before its cells wrap instead.
    static let minimumTableScale: CGFloat = 0.7

    /// How far a table too wide for its page may shrink its text.
    struct TableFloor: Sendable {
        let scale: CGFloat
        let size: CGFloat
        /// Columns are set by the widest words as they set, so none breaks. The
        /// screen's shares of the page let a word break, with the zoom panel to read it in.
        var keepsWordsWhole = false

        static let screen = TableFloor(scale: minimumTableScale, size: 9)
        /// Paper has no zoom panel, and prints finer than a screen shows: words
        /// stay whole down to the smallest readable size.
        static let paper = TableFloor(scale: 0.35, size: 6, keepsWordsWhole: true)
    }

    /// Shrinks the text of each outermost table whose words can't fit
    /// `width`, by as much as fitting takes, down to the floor.
    private static func shrinkWideTables(in text: NSMutableAttributedString, toFit width: CGFloat, scale: CGFloat,
                                         floor: TableFloor) {
        var spans: [ObjectIdentifier: (table: EPUBTextTable, range: NSRange)] = [:]
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let table = ((value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock)?.table
                    as? EPUBTextTable else { return }
            let key = ObjectIdentifier(table)
            spans[key] = (table, spans[key].map { NSUnionRange($0.range, range) } ?? range)
        }
        for (table, range) in spans.values {
            let factor = max(floor.scale, table.shrinkFactor(toFit: width, scale: scale))
            guard factor < 0.99 else { continue }
            resizeFonts(in: text, range: range, by: factor, atLeast: floor.size)
            if floor.keepsWordsWhole {
                setWholeWordColumns(of: table, in: text, range: range, toFit: width, scale: scale, shrunk: factor, floor: floor)
            }
        }
    }

    private static func resizeFonts(in text: NSMutableAttributedString, range: NSRange, by factor: CGFloat, atLeast smallest: CGFloat) {
        text.enumerateAttribute(.font, in: range) { value, run, _ in
            guard let font = value as? NSFont else { return }
            let size = max(smallest, font.pointSize * factor)
            text.addAttribute(.font, value: CTFontCreateCopyWithAttributes(font, size, nil, nil) as NSFont, range: run)
        }
    }

    /// Sizes the columns to the widest words as they now set, shrinking further
    /// if those still don't fit: a face set small runs wider than it scales. A
    /// table that can't fit even so keeps its shares of the page.
    private static func setWholeWordColumns(of table: EPUBTextTable, in text: NSMutableAttributedString, range: NSRange,
                                            toFit width: CGFloat, scale: CGFloat, shrunk: CGFloat, floor: TableFloor) {
        // A cell's lines run a little short of its width.
        let lineShortfall: CGFloat = 3
        let room = width - table.fixedWidth * scale - lineShortfall * CGFloat(table.numberOfColumns)
        var shrunk = shrunk
        var words = table.widestWords(in: text, range: range)
        for _ in 0..<3 {
            let total = words.reduce(0, +)
            guard total > room, shrunk > floor.scale else { break }
            // A little under: words measure rounded up, so an exact step can fall short.
            let step = max(floor.scale / shrunk, room / total * 0.98)
            resizeFonts(in: text, range: range, by: step, atLeast: floor.size)
            shrunk *= step
            words = table.widestWords(in: text, range: range)
        }
        guard words.reduce(0, +) <= room else { return }
        text.enumerateAttribute(.paragraphStyle, in: range) { value, _, _ in
            guard let cell = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock, cell.table === table,
                  cell.columnSpan == 1, words.indices.contains(cell.startingColumn) else { return }
            cell.setValue(words[cell.startingColumn] + lineShortfall, type: .absoluteValueType, for: .width)
        }
    }

    static func themeTextColor(for palette: EPUBPagePalette) -> NSColor {
        switch palette {
        // Light pages are white paper with black text in either appearance, like PDF.
        case .light: return .black
        case .sepia: return NSColor(calibratedRed: 0.32, green: 0.24, blue: 0.14, alpha: 1)
        case .dark: return NSColor(calibratedWhite: 0.92, alpha: 1)
        }
    }

    /// The underline under links: the text colour, faint.
    static func linkUnderlineColor(for palette: EPUBPagePalette) -> NSColor {
        themeTextColor(for: palette).withAlphaComponent(0.35)
    }

    static func themeBackgroundColor(for palette: EPUBPagePalette) -> NSColor {
        switch palette {
        case .light: return .white
        case .sepia: return NSColor(calibratedRed: 0.96, green: 0.93, blue: 0.85, alpha: 1)
        case .dark: return NSColor(calibratedWhite: 0.13, alpha: 1)
        }
    }

    // MARK: - Fonts

    /// A rendered font in the reader's family (or the installed family
    /// `named`) and size. Code stays monospaced, and italic that the family
    /// lacks is slanted instead.
    static func styledFont(_ font: NSFont, family: EPUBFontFamily, named: String? = nil, size: CGFloat) -> NSFont {
        var descriptor = font.fontDescriptor
        let traits = descriptor.symbolicTraits
        let isCode = traits.contains(.monoSpace) || font.isFixedPitch
        if let named, !isCode {
            descriptor = namedFamily(named, like: descriptor)
        } else if family == .serif, !isCode, let serif = descriptor.withDesign(.serif) {
            descriptor = serif.addingAttributes([.cascadeList: serifCJKCascade(bold: traits.contains(.bold))])
        }
        var styled = NSFont(descriptor: descriptor, size: size) ?? font
        if traits.contains(.italic), !styled.fontDescriptor.symbolicTraits.contains(.italic) {
            styled = oblique(styled)
        }
        return styled
    }

    /// The installed families a reader can choose, as the Font panel lists them.
    static func installedFamilies() -> [String] {
        let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// A family chosen on another Mac may not be installed on this one;
    /// the text then keeps the preset.
    static func isInstalled(_ family: String) -> Bool {
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
        return !descriptor.matchingFontDescriptors(withMandatoryKeys: [.family]).isEmpty
    }

    /// `family` at the weight and slant of a rendered font, so bold and
    /// italic text stay bold and italic in it.
    private static func namedFamily(_ family: String, like source: NSFontDescriptor) -> NSFontDescriptor {
        var traits: [NSFontDescriptor.TraitKey: Any] = [:]
        if let weight = (source.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] {
            traits[.weight] = weight
        }
        if source.symbolicTraits.contains(.italic) {
            traits[.symbolic] = NSFontDescriptor.SymbolicTraits.italic.rawValue
        }
        return NSFontDescriptor(fontAttributes: [.family: family, .traits: traits])
    }

    /// The system serif has no CJK glyphs, so CJK would fall back to the
    /// sans PingFang; a Song face keeps it serif like the Latin around it.
    private static func serifCJKCascade(bold: Bool) -> [NSFontDescriptor] {
        ["Songti SC", "Songti TC"].map { family in
            let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
            return bold ? descriptor.withSymbolicTraits(.bold) : descriptor
        }
    }

    /// A slanted copy of a font that has no italic. A trait conversion
    /// would silently return the upright font; a skew matrix always slants.
    static func oblique(_ font: NSFont) -> NSFont {
        var skew = CGAffineTransform(a: 1, b: 0, c: tan(14 * .pi / 180), d: 1, tx: 0, ty: 0)
        return CTFontCreateCopyWithAttributes(font as CTFont, font.pointSize, &skew, nil) as NSFont
    }

    /// Pins the face for text the primary font can't draw (CJK beside
    /// Latin) instead of leaving it to TextKit's fallback. Under Serif, a
    /// fallback derived from the system serif sets a half-em gap after CJK
    /// punctuation; a plain copy of the same Song face doesn't. In italic
    /// runs the face is slanted, since CJK fonts have no italic.
    private static func pinFallbackFonts(in text: NSMutableAttributedString, range: NSRange,
                                         primary: NSFont, slanted: Bool) {
        guard range.length > 0 else { return }
        var characters = [UniChar](repeating: 0, count: range.length)
        text.mutableString.getCharacters(&characters, range: range)
        var glyphs = [CGGlyph](repeating: 0, count: range.length)
        if CTFontGetGlyphsForCharacters(primary, characters, &glyphs, range.length) { return }

        func missing(_ index: Int) -> Bool {
            let character = characters[index]
            if character < 0x20 || character == 0xFFFC { return false }
            // The second half of a surrogate pair shares the first half's glyph.
            if UTF16.isTrailSurrogate(character), index > 0 { return glyphs[index - 1] == 0 }
            return glyphs[index] == 0
        }
        var index = 0
        while index < range.length {
            guard missing(index) else { index += 1; continue }
            let start = index
            while index < range.length, missing(index) { index += 1 }
            let stretch = NSRange(location: range.location + start, length: index - start)
            let resolved = CTFontCreateForString(primary, text.mutableString as CFString,
                                                 CFRange(location: stretch.location, length: stretch.length))
            let name = CTFontCopyPostScriptName(resolved) as String
            var face = NSFont(name: name, size: primary.pointSize) ?? (resolved as NSFont)
            if slanted, !face.fontDescriptor.symbolicTraits.contains(.italic) { face = oblique(face) }
            text.addAttribute(.font, value: face, range: stretch)
        }
    }

    // MARK: - Tate-chu-yoko

    /// A combined run takes one character's space along its line, however
    /// long its text; the layout manager draws it upright there.
    private static func fitCombinedRuns(in text: NSMutableAttributedString) {
        text.enumerateAttribute(EPUBWriting.combinedAttribute, in: NSRange(location: 0, length: text.length)) { value, run, _ in
            guard value != nil, let font = text.attribute(.font, at: run.location, effectiveRange: nil) as? NSFont else { return }
            let width = text.attributedSubstring(from: run).size().width
            text.addAttribute(.kern, value: (font.pointSize - width) / CGFloat(run.length), range: run)
        }
    }

    // MARK: - Ruby

    /// A paragraph with ruby leaves room over every line, so its lines stay
    /// evenly spaced, and a base spreads to the width of a longer reading.
    /// Styles are per paragraph here: a block's are shared with text without ruby.
    private static func reserveRubyRoom(in text: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: text.length)
        var paragraphs: [NSRange] = []
        var heights: [NSFont: CGFloat] = [:]
        let vertical = EPUBWriting.isVertical(text)
        func natural(_ font: NSFont) -> CGFloat {
            if let known = heights[font] { return known }
            let height = naturalLineHeight(font, vertical: vertical)
            heights[font] = height
            return height
        }
        let string = text.mutableString
        text.enumerateAttribute(EPUBRuby.attribute, in: full) { value, base, _ in
            guard let reading = value as? EPUBRubyText else { return }
            if let font = text.attribute(.font, at: base.location, effectiveRange: nil) as? NSFont {
                spread(base, of: text, under: reading.text, font: font)
            }
            let paragraph = string.paragraphRange(for: base)
            if paragraphs.last != paragraph { paragraphs.append(paragraph) }
        }
        for paragraph in paragraphs {
            var line: CGFloat = 0
            var room: CGFloat = 0
            text.enumerateAttribute(.font, in: paragraph) { value, _, _ in
                guard let font = value as? NSFont else { return }
                line = max(line, natural(font))
                room = max(room, natural(EPUBRuby.font(over: font)))
            }
            guard let style = (text.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
                as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { continue }
            style.minimumLineHeight = ceil(line + room)
            text.addAttribute(.paragraphStyle, value: style, range: paragraph)
        }
    }

    /// Spaces a base out to meet a wider reading, up to an em a character:
    /// a full share between its characters, half a share at each end.
    private static func spread(_ base: NSRange, of text: NSMutableAttributedString, under reading: String, font: NSFont) {
        let wanted = (reading as NSString).size(withAttributes: [.font: EPUBRuby.font(over: font)]).width
        let width = text.attributedSubstring(from: base).size().width
        guard wanted > width else { return }
        let share = min((wanted - width) / CGFloat(base.length), font.pointSize)
        text.addAttribute(.kern, value: share, range: base)
        text.addAttribute(.kern, value: share / 2, range: NSRange(location: NSMaxRange(base) - 1, length: 1))
        let before = base.location - 1
        guard before >= 0, text.mutableString.character(at: before) != 0x0A else { return }
        let existing = text.attribute(.kern, at: before, effectiveRange: nil) as? CGFloat ?? 0
        text.addAttribute(.kern, value: existing + share / 2, range: NSRange(location: before, length: 1))
    }

    /// A line's height in `font` before any spacing, CJK fallback included.
    private static func naturalLineHeight(_ font: NSFont, vertical: Bool) -> CGFloat {
        let storage = NSTextStorage(string: "漢a", attributes: [.font: font])
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let size = CGSize(width: 1_000, height: 1_000)
        let container = vertical ? EPUBVerticalTextContainer(size: size) : NSTextContainer(size: size)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        return layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height
    }

    // MARK: - Paragraphs

    /// A rendered block's style at the reader's size: its spacing and indents
    /// scale with the body text; line spacing follows the line height setting.
    private static func scaledParagraph(_ source: NSParagraphStyle, scale: CGFloat, typography: EPUBTypography,
                                        tables: inout EPUBTextBlockStyler) -> NSParagraphStyle {
        // Copy: the cached chapter's style must never change under the reader.
        let style = source.mutableCopy() as! NSMutableParagraphStyle
        let body = CGFloat(typography.fontSize)
        style.lineSpacing = max(0, body * CGFloat(typography.lineHeight) - body)
        style.paragraphSpacing = source.paragraphSpacing * scale
        // The renderer justifies body text and nothing else; the reader's
        // choices for body text apply there.
        if source.alignment == .justified, source.headerLevel == 0, source.textBlocks.isEmpty {
            if !typography.isJustified { style.alignment = .natural }
            style.paragraphSpacing += typography.paragraphSpacing * body
        }
        if !typography.isHyphenated { style.hyphenationFactor = 0 }
        style.paragraphSpacingBefore = source.paragraphSpacingBefore * scale
        style.headIndent = source.headIndent * scale
        style.firstLineHeadIndent = source.firstLineHeadIndent * scale
        style.tailIndent = source.tailIndent * scale
        style.defaultTabInterval = source.defaultTabInterval * scale
        style.tabStops = source.tabStops.map {
            NSTextTab(textAlignment: $0.alignment, location: $0.location * scale, options: $0.options)
        }
        if !source.textBlocks.isEmpty { style.textBlocks = tables.restyled(source.textBlocks) }
        return style
    }
}
