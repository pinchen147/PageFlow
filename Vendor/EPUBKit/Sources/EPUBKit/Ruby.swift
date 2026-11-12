import AppKit

/// Ruby keeps only the base in the text, so offsets, Find, Copy and Read Aloud
/// never see the reading. The reading hangs on the base as an attribute and
/// ``EPUBPageLayoutManager`` draws it: TextKit 1 ignores `kCTRubyAnnotationAttributeName`.
public enum EPUBRuby {
    public static let attribute = NSAttributedString.Key("EPUBRubyText")
    /// A reading's size against its base, as in print.
    public static let sizeFactor: CGFloat = 0.5

    public static func font(over base: NSFont) -> NSFont {
        base.withSize(base.pointSize * sizeFactor)
    }
}

/// A reading on a base. Each is its own object, so two neighbouring bases
/// with the same reading stay two runs.
public final class EPUBRubyText: NSObject, @unchecked Sendable {
    public let text: String

    init(_ text: String) {
        self.text = text
    }
}

/// Draws the readings over their bases, after the text. The room above each
/// line comes from the paragraph's minimum line height, set when the chapter
/// is styled, so any text stack lays out the same lines. It also sets
/// tate-chu-yoko: a combined run's glyphs keep their place but aren't shown,
/// and its text draws upright in the space they hold.
public final class EPUBPageLayoutManager: NSLayoutManager {
    private lazy var readings = ReadingStack()

    public override func showCGGlyphs(_ glyphs: UnsafePointer<CGGlyph>, positions: UnsafePointer<CGPoint>, count: Int,
                                      font: NSFont, textMatrix: CGAffineTransform,
                                      attributes: [NSAttributedString.Key: Any] = [:], in context: CGContext) {
        guard attributes[EPUBWriting.combinedAttribute] == nil else { return }
        super.showCGGlyphs(glyphs, positions: positions, count: count, font: font, textMatrix: textMatrix,
                           attributes: attributes, in: context)
    }

    public override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, glyphsToShow.length > 0 else { return }
        let shown = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(EPUBWriting.combinedAttribute, in: shown) { value, run, _ in
            if value != nil { drawCombined(run, at: origin) }
        }
        let all = NSRange(location: 0, length: storage.length)
        var seen: EPUBRubyText?
        storage.enumerateAttribute(EPUBRuby.attribute, in: shown) { value, run, _ in
            guard let reading = value as? EPUBRubyText, reading !== seen else { return }
            seen = reading
            // The whole base, though only part of it may be redrawn.
            var base = NSRange()
            _ = storage.attribute(EPUBRuby.attribute, at: run.location, longestEffectiveRange: &base, in: all)
            draw(reading.text, over: base, showing: glyphsToShow, at: origin)
        }
    }

    /// A combined run's text, shrunk to one character's space if it must,
    /// upright in the middle of the space its hidden glyphs hold.
    private func drawCombined(_ run: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, let container = textContainer(forGlyphAt: glyphIndexForCharacter(at: run.location), effectiveRange: nil),
              let font = storage.attribute(.font, at: run.location, effectiveRange: nil) as? NSFont else { return }
        let color = storage.attribute(.foregroundColor, at: run.location, effectiveRange: nil) as? NSColor ?? .labelColor
        let glyphs = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
        let box = boundingRect(forGlyphRange: glyphs, in: container)
        let line = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let baseline = line.minY + location(forGlyphAt: glyphs.location).y
        let string = (storage.string as NSString).substring(with: run)
        // Rotated Latin sits on its own baseline, not the column's middle line.
        let isRotated = string.unicodeScalars.first.map { $0.value < 0x2E80 } ?? false
        let middle = baseline - (isRotated ? (font.ascender + font.descender) / 2 : 0)
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let width = (string as NSString).size(withAttributes: attributes).width
        let fitted = width > font.pointSize ? font.withSize(font.pointSize * font.pointSize / width) : font
        attributes[.font] = fitted
        let size = (string as NSString).size(withAttributes: attributes)
        guard container.layoutOrientation == .vertical else {
            (string as NSString).draw(at: NSPoint(x: origin.x + box.midX - size.width / 2,
                                                  y: origin.y + baseline - fitted.ascender), withAttributes: attributes)
            return
        }
        drawUpright(in: NSRect(x: origin.x + box.midX - size.height / 2, y: origin.y + middle - size.width / 2,
                               width: size.height, height: size.width)) { rect in
            (string as NSString).draw(at: rect.origin, withAttributes: attributes)
        }
    }

    /// One piece of the reading per line the base runs on, shared out by
    /// how much of the base each line holds.
    private func draw(_ reading: String, over base: NSRange, showing shown: NSRange, at origin: NSPoint) {
        guard let storage = textStorage,
              let font = storage.attribute(.font, at: base.location, effectiveRange: nil) as? NSFont else { return }
        let color = storage.attribute(.foregroundColor, at: base.location, effectiveRange: nil) as? NSColor ?? .labelColor
        let baseGlyphs = glyphRange(forCharacterRange: base, actualCharacterRange: nil)
        let characters = Array(reading)
        var used = 0
        enumerateLineFragments(forGlyphRange: baseGlyphs) { [self] line, _, container, lineGlyphs, _ in
            let part = NSIntersectionRange(lineGlyphs, baseGlyphs)
            guard part.length > 0 else { return }
            let done = NSMaxRange(part) >= NSMaxRange(baseGlyphs)
            let share = done ? characters.count - used
                : characters.count * (NSMaxRange(part) - baseGlyphs.location) / baseGlyphs.length - used
            defer { used += share }
            guard share > 0, NSIntersectionRange(part, shown).length > 0 else { return }
            let piece = NSAttributedString(string: String(characters[used..<(used + share)]), attributes: [
                .font: EPUBRuby.font(over: font),
                .foregroundColor: color
            ])
            let vertical = container.layoutOrientation == .vertical
            let extent = boundingRect(forGlyphRange: part, in: container)
            let baseline = line.minY + location(forGlyphAt: part.location).y
            // A vertical line's baseline runs through the glyphs' middle.
            let top = baseline - (vertical ? font.pointSize / 2 : max(font.ascender, font.pointSize * 0.88))
            // The space a spread base leaves after its last character isn't under the reading.
            let last = characterIndexForGlyph(at: NSMaxRange(part) - 1)
            let trailing = storage.attribute(.kern, at: last, effectiveRange: nil) as? CGFloat ?? 0
            readings.draw(piece, vertical: vertical, centeredOn: extent.midX - trailing / 2, above: top,
                          within: container.size.width, offset: origin)
        }
    }
}

/// A small text stack for one reading at a time, so it draws exactly as text
/// drawn along the page's lines does, in either orientation.
private final class ReadingStack {
    private let storage = NSTextStorage()
    private let horizontal = NSLayoutManager()
    private let vertical = NSLayoutManager()
    private let horizontalContainer = NSTextContainer(size: CGSize(width: 4_000, height: 200))
    private let verticalContainer = EPUBVerticalTextContainer(size: CGSize(width: 4_000, height: 200))

    init() {
        horizontalContainer.lineFragmentPadding = 0
        verticalContainer.lineFragmentPadding = 0
        horizontal.addTextContainer(horizontalContainer)
        vertical.addTextContainer(verticalContainer)
    }

    func draw(_ text: NSAttributedString, vertical isVertical: Bool, centeredOn center: CGFloat, above top: CGFloat,
              within width: CGFloat, offset: NSPoint) {
        let layout = isVertical ? vertical : horizontal
        let container = isVertical ? verticalContainer : horizontalContainer
        if layout.textStorage !== storage {
            storage.layoutManagers.forEach { storage.removeLayoutManager($0) }
            storage.addLayoutManager(layout)
        }
        storage.setAttributedString(text)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        // Over the base, but never off the line's ends.
        let x = max(0, min(center - used.width / 2, width - used.width))
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container),
                          at: NSPoint(x: offset.x + x, y: offset.y + top - used.height))
    }
}
