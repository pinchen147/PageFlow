import AppKit
import ObjectiveC

/// The raster preview and native hit targets use the same cell geometry.
/// The cell box is the reference editor's (doc 24 §5.1): 6 / 10 padding inside a 1 pt
/// grid, text at 0.94 of the body size on a 1.45 line, top-aligned, and a
/// header row in regular weight on its own fill.
struct MarkdownTableLayout {
    let cells: [[NSAttributedString]]
    let cellRects: [[NSRect]]
    let alignments: [MarkdownStyler.TableAlignment]
    let size: NSSize
    let border: NSColor
    /// The appearance the grid's colours were resolved in. The text draws in
    /// it too, so its dynamic colours can never mix with the other mode's grid.
    let appearance: NSAppearance
    let headerFill: NSColor
    /// The cell text's font and line box.
    let cellFont: NSFont
    let lineHeight: CGFloat
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 6
    static let fontScale: CGFloat = 0.94
    static let lineHeightMultiple: CGFloat = 1.45
    /// The narrowest column box, its padding and one border included.
    static let minimumColumnWidth: CGFloat = 48

    /// The font table cells set their text in, for a body `font`.
    static func cellFont(for font: NSFont) -> NSFont {
        NSFont(descriptor: font.fontDescriptor, size: font.pointSize * fontScale) ?? font
    }

    /// Raises the glyphs to the middle of the 1.45 line box (CSS half-leading).
    static func baselineOffset(for font: NSFont, lineHeight: CGFloat) -> CGFloat {
        max(0, lineHeight - ceil(font.ascender - font.descender + font.leading)) / 2
    }

    /// Formatted cells by source text, kept while one table is edited so a
    /// keystroke formats and measures only the cell it changed. A layout
    /// built from it leaves only its own entries, so edits never pile up.
    final class CellCache {
        fileprivate var context: [AnyHashable] = []
        fileprivate var theme: MarkdownEditorTheme?
        fileprivate(set) var cells: [String: (text: NSAttributedString, size: NSSize)] = [:]
        /// Wrapped heights by cell key and wrap width.
        fileprivate(set) var heights: [String: CGFloat] = [:]
        func removeAll() {
            cells.removeAll()
            heights.removeAll()
        }
        /// Drops every entry the latest layout did not use.
        fileprivate func keep(cells cellKeys: Set<String>, heights heightKeys: Set<String>) {
            if cells.count > cellKeys.count { cells = cells.filter { cellKeys.contains($0.key) } }
            if heights.count > heightKeys.count { heights = heights.filter { heightKeys.contains($0.key) } }
        }
    }

    /// the reference editor's auto column (doc 24 §5.1.2): as wide as its widest cell on
    /// one line plus padding and border, at least 48 and at most 42 × the
    /// width of "0" in the cell font; wider content wraps and the row grows.
    static func maximumColumnWidth(for cellFont: NSFont) -> CGFloat {
        42 * ("0" as NSString).size(withAttributes: [.font: cellFont]).width
    }

    /// The widest a set column may be (the reference editor clamps to 48…4000).
    static let maximumSetColumnWidth: CGFloat = 4000

    /// `columnWidths` are view-only box widths the user set (nil: Auto).
    init(table: MarkdownStyler.ParsedTable, font: NSFont, theme: MarkdownEditorTheme,
         codeBackground: NSColor, latex: any LatexRenderer, appearance: NSAppearance, cache: CellCache? = nil,
         columnWidths: [CGFloat?] = []) {
        alignments = table.alignments
        let columns = table.alignments.count
        let font = Self.cellFont(for: font)
        cellFont = font
        let lineHeight = font.pointSize * Self.lineHeightMultiple
        self.lineHeight = lineHeight
        let context: [AnyHashable] = [font.fontName, font.pointSize, appearance.name.rawValue]
        if let cache, cache.context != context || cache.theme != theme {
            cache.removeAll()
            cache.context = context
            cache.theme = theme
        }
        let baseline = Self.baselineOffset(for: font, lineHeight: lineHeight)
        // Pass 1: format every cell in its column's paragraph style and measure it on one line.
        let rows = [table.header] + table.rows
        let formatted = rows.enumerated().map { row, values in
            values.enumerated().map { column, value -> (key: String, text: NSAttributedString, size: NSSize) in
                let alignment = column < table.alignments.count ? table.alignments[column] : .left
                let key = (row == 0 ? "h" : "b") + "\(alignment)|" + value
                if let hit = cache?.cells[key] { return (key, hit.text, hit.size) }
                let text = NSMutableAttributedString(attributedString: MarkdownStyler.formattedCellString(
                    value, baseFont: font, header: row == 0, theme: theme,
                    codeBackgroundColor: codeBackground, latex: latex
                ))
                let whole = NSRange(location: 0, length: text.length)
                text.addAttribute(.paragraphStyle, value: Self.paragraphStyle(
                    alignment, direction: Self.writingDirection(of: text.string), lineHeight: lineHeight
                ), range: whole)
                text.addAttribute(.baselineOffset, value: baseline, range: whole)
                let size = text.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin]).size
                cache?.cells[key] = (text, size)
                return (key, text, size)
            }
        }
        cells = formatted.map { $0.map(\.text) }
        let padding = Self.horizontalPadding * 2 + 1
        let minimumContent = Self.minimumColumnWidth - padding
        let maximumContent = max(minimumContent, Self.maximumColumnWidth(for: font) - padding)
        var widths = Array(repeating: minimumContent, count: columns)
        for row in formatted {
            for (column, value) in row.enumerated() where column < columns {
                widths[column] = min(maximumContent, max(widths[column], ceil(value.size.width)))
            }
        }
        // A width the user set replaces Auto for its column; the text wraps inside it.
        for (column, width) in columnWidths.enumerated() where column < columns {
            if let width { widths[column] = min(Self.maximumSetColumnWidth, max(Self.minimumColumnWidth, width)) - padding }
        }
        // Pass 2: wrap each cell at its column's width; a row is as tall as its tallest cell.
        var y: CGFloat = 1
        var rects: [[NSRect]] = []
        var heightKeys = Set<String>()
        for row in formatted {
            var height = lineHeight
            for (column, value) in row.enumerated() where column < columns {
                let width = widths[column]
                guard value.size.width > width else {
                    height = max(height, value.size.height)
                    continue
                }
                let heightKey = "\(width)|" + value.key
                heightKeys.insert(heightKey)
                let wrapped = cache?.heights[heightKey] ?? value.text.boundingRect(
                    with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]
                ).height
                cache?.heights[heightKey] = wrapped
                height = max(height, wrapped)
            }
            height += Self.verticalPadding * 2
            var x: CGFloat = 1
            rects.append(widths.map { width in
                let rect = NSRect(x: x, y: y, width: width + Self.horizontalPadding * 2, height: height)
                x += rect.width + 1
                return rect
            })
            y += height + 1
        }
        cache?.keep(cells: Set(formatted.joined().map(\.key)), heights: heightKeys)
        cellRects = rects
        size = NSSize(width: widths.reduce(1) { $0 + $1 + Self.horizontalPadding * 2 + 1 }, height: y)
        var colors = (border: theme.tableBorder, header: theme.tableHeaderFill)
        appearance.performAsCurrentDrawingAppearance {
            colors = (theme.tableBorder.usingColorSpace(.sRGB) ?? theme.tableBorder,
                      theme.tableHeaderFill.usingColorSpace(.sRGB) ?? theme.tableHeaderFill)
        }
        border = colors.border
        headerFill = colors.header
        self.appearance = appearance
    }

    /// A cell's text: aligned to its column in its own writing direction,
    /// wrapped at word boundaries, on the 1.45 line. The cell editor sets its
    /// text with this style too.
    static func paragraphStyle(_ alignment: MarkdownStyler.TableAlignment, direction: NSWritingDirection,
                               lineHeight: CGFloat) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        switch alignment {
        // `---` and `:---` parse alike: natural, so right-to-left text
        // starts at the right edge while left-to-right text stays left.
        case .left: paragraph.alignment = .natural
        case .center: paragraph.alignment = .center
        case .right: paragraph.alignment = .right
        }
        paragraph.baseWritingDirection = direction
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        return paragraph
    }

    /// A cell's paragraph direction: that of its first strong character
    /// (Unicode bidi P2), else the app's. TextKit 1 resolves `.natural` from
    /// the app's language, which left a Hebrew or Arabic cell on the left.
    static func writingDirection(of text: String) -> NSWritingDirection {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            // Hebrew through Arabic Extended-A, their presentation forms, and the supplementary RTL scripts.
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
                return .rightToLeft
            default:
                if scalar.properties.isAlphabetic { return .leftToRight }
            }
        }
        return .natural
    }

    /// The cell under `point`: binary searches over the row and column edges.
    func cell(at point: NSPoint) -> (row: Int, column: Int)? {
        guard let firstRow = cellRects.first, !firstRow.isEmpty else { return nil }
        func search(_ count: Int, _ minEdge: (Int) -> CGFloat, _ maxEdge: (Int) -> CGFloat, _ value: CGFloat) -> Int? {
            var low = 0, high = count - 1
            while low <= high {
                let mid = (low + high) / 2
                if value < minEdge(mid) { high = mid - 1 } else if value >= maxEdge(mid) { low = mid + 1 } else { return mid }
            }
            return nil
        }
        guard let row = search(cellRects.count, { cellRects[$0][0].minY }, { cellRects[$0][0].maxY }, point.y),
              let column = search(firstRow.count, { firstRow[$0].minX }, { firstRow[$0].maxX }, point.x) else { return nil }
        return (row, column)
    }

    /// The table as an image. The editor draws it with ``draw(in:selection:)``
    /// from the layout behind it, never through NSImage: AppKit renders any
    /// image through a whole-image bitmap at the device scale, which for a
    /// 50 × 8 table was about 140 MiB at 2x and several times that under
    /// zoom. The image keeps no cached bitmap for any other drawer either.
    func image() -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in draw(); return true }
        image.cacheMode = .never
        objc_setAssociatedObject(image, &Self.rasterKey, Box(self), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return image
    }

    /// Draws the table scaled into `rect` of the current context, straight
    /// from the layout: no intermediate bitmap, and only the cells inside the
    /// clip, so memory and time follow the visible part of the table.
    func draw(in rect: NSRect, selection: SelectionPaint? = nil) {
        guard let current = NSGraphicsContext.current, size.width > 0, size.height > 0 else { return }
        let context = current.cgContext
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        if current.isFlipped {
            context.translateBy(x: rect.minX, y: rect.minY)
        } else {
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
        }
        context.scaleBy(x: rect.width / size.width, y: rect.height / size.height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // The layout draws top-down, as in the image's flipped space.
        if !current.isFlipped { NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true) }
        draw(selection: selection)
    }

    // MARK: - Text selection over the table

    /// What a document selection that covers some cells paints on them
    /// (doc 24 §7.5.7): the selection colour behind each line of their text,
    /// and the text in the selection's text colour.
    struct SelectionPaint: Hashable {
        var cells: Set<CellCoord>
        var background: NSColor
        var text: NSColor?
    }

    /// A raster's layout, alive as long as the raster: set on the image itself.
    /// A weak-to-strong NSMapTable kept every layout's cells after its image was
    /// gone, since it only drops values for dead keys when it next resizes.
    private final class Box {
        let layout: MarkdownTableLayout
        init(_ layout: MarkdownTableLayout) { self.layout = layout }
    }

    nonisolated(unsafe) private static var rasterKey: UInt8 = 0

    /// The layout `image` was drawn from, if it is a table raster: hover chrome
    /// hit-tests the exact cells the table shows, and the editor draws it.
    static func layout(ofRaster image: NSImage) -> MarkdownTableLayout? {
        (objc_getAssociatedObject(image, &rasterKey) as? Box)?.layout
    }

    /// One TextKit 1 stack set up as the cell editor's (no fragment padding,
    /// wrapping at the content width), which sets every cell the grid draws:
    /// entering a cell then moves no glyph and breaks no line differently.
    /// String drawing put the baseline 1 pt above the editor's, and with font
    /// leading it drew wrapped lines on a shorter pitch.
    private final class CellTypesetter {
        let lock = NSLock()
        private let storage = NSTextStorage()
        private let manager = NSLayoutManager()
        private let container = NSTextContainer()

        init() {
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
        }

        func set<T>(_ text: NSAttributedString, width: CGFloat,
                    _ body: (NSLayoutManager, NSTextContainer, NSRange) -> T) -> T {
            lock.lock()
            defer {
                storage.setAttributedString(NSAttributedString())
                lock.unlock()
            }
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
            storage.setAttributedString(text)
            return body(manager, container, manager.glyphRange(for: container))
        }
    }

    private static let typesetter = CellTypesetter()

    /// Each line of `text` set at `width`, in the cell's content coordinates.
    private static func lineRects(of text: NSAttributedString, width: CGFloat) -> [NSRect] {
        guard text.length > 0 else { return [] }
        return typesetter.set(text, width: width) { manager, _, glyphs in
            var rects: [NSRect] = []
            manager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
                if used.width > 0 { rects.append(used) }
            }
            return rects
        }
    }

    /// Draws `text` set at the width of `content`, from its top-left corner.
    private static func drawText(_ text: NSAttributedString, in content: NSRect) {
        guard text.length > 0 else { return }
        typesetter.set(text, width: content.width) { manager, _, glyphs in
            manager.drawBackground(forGlyphRange: glyphs, at: content.origin)
            manager.drawGlyphs(forGlyphRange: glyphs, at: content.origin)
        }
    }

    /// The link under `point` (top-down table coordinates) in a cell's drawn
    /// text, not in `omitting` (the cell the editor covers). Only a point on
    /// a glyph of the link's text counts, as for links in prose.
    func link(at point: NSPoint, omitting: CellCoord? = nil) -> TableLinkTarget? {
        guard let hit = cell(at: point), omitting != CellCoord(row: hit.row, column: hit.column),
              cells.indices.contains(hit.row), cells[hit.row].indices.contains(hit.column) else { return nil }
        let text = cells[hit.row][hit.column]
        var hasLink = false
        let whole = NSRange(location: 0, length: text.length)
        for key in [MarkdownStyler.tableCellLink, MarkdownStyler.tableCellWikiLink] where !hasLink {
            text.enumerateAttribute(key, in: whole) { value, _, stop in
                if value != nil { hasLink = true; stop.pointee = true }
            }
        }
        guard hasLink else { return nil }
        let content = cellRects[hit.row][hit.column].insetBy(dx: Self.horizontalPadding, dy: Self.verticalPadding)
        let local = NSPoint(x: point.x - content.minX, y: point.y - content.minY)
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: content.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        var fraction: CGFloat = 0
        let glyph = manager.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < manager.numberOfGlyphs,
              manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        if let target = text.attribute(MarkdownStyler.tableCellWikiLink, at: index, effectiveRange: nil) as? String {
            return .wikiLink(target)
        }
        guard let destination = text.attribute(MarkdownStyler.tableCellLink, at: index, effectiveRange: nil) as? String else { return nil }
        return Self.url(forLinkDestination: destination).map(TableLinkTarget.url)
    }

    /// A link destination as a URL: `www.` gets https, spaces are escaped.
    static func url(forLinkDestination destination: String) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let spelled = trimmed.lowercased().hasPrefix("www.") ? "https://" + trimmed : trimmed
        return URL(string: spelled) ?? spelled.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
    }

    /// The box of `cell`, if the table has it.
    func rect(of cell: CellCoord) -> NSRect? {
        guard cellRects.indices.contains(cell.row), cellRects[cell.row].indices.contains(cell.column) else { return nil }
        return cellRects[cell.row][cell.column]
    }

    /// The rows and columns whose cell boxes meet `rect`, by binary search.
    func cells(intersecting rect: NSRect) -> (rows: Range<Int>, columns: Range<Int>) {
        guard let firstRow = cellRects.first, !firstRow.isEmpty, !rect.isNull, !rect.isEmpty else { return (0..<0, 0..<0) }
        /// From the first box ending past `low` up to the first starting at or past `high`.
        func span(_ count: Int, _ minEdge: (Int) -> CGFloat, _ maxEdge: (Int) -> CGFloat,
                  _ low: CGFloat, _ high: CGFloat) -> Range<Int> {
            func partition(_ isBefore: (Int) -> Bool) -> Int {
                var lower = 0, upper = count
                while lower < upper {
                    let mid = (lower + upper) / 2
                    if isBefore(mid) { lower = mid + 1 } else { upper = mid }
                }
                return lower
            }
            let start = partition { maxEdge($0) <= low }
            return start..<max(start, partition { minEdge($0) < high })
        }
        return (span(cellRects.count, { cellRects[$0][0].minY }, { cellRects[$0][0].maxY }, rect.minY, rect.maxY),
                span(firstRow.count, { firstRow[$0].minX }, { firstRow[$0].maxX }, rect.minX, rect.maxX))
    }

    /// Draws the grid, and the text of only the cells inside the current
    /// clip: each cell's text is clipped to its own box, so the rest would
    /// add no pixels, only typesetting.
    func draw(selection: SelectionPaint? = nil, omittingTextIn editedCell: CellCoord? = nil) {
        let visible = NSGraphicsContext.current?.cgContext.boundingBoxOfClipPath ?? NSRect(origin: .zero, size: size)
        if let first = cellRects.first?.first, let last = cellRects.first?.last {
            headerFill.setFill()
            first.union(last).fill()
        }
        border.setStroke()
        let path = NSBezierPath(rect: NSRect(x: 0.5, y: 0.5, width: size.width - 1, height: size.height - 1))
        path.lineWidth = 1
        if let firstRow = cellRects.first {
            for rect in firstRow.dropFirst() {
                path.move(to: NSPoint(x: rect.minX - 0.5, y: 0))
                path.line(to: NSPoint(x: rect.minX - 0.5, y: size.height))
            }
        }
        for row in cellRects.dropFirst() {
            guard let first = row.first else { continue }
            path.move(to: NSPoint(x: 0, y: first.minY - 0.5))
            path.line(to: NSPoint(x: size.width, y: first.minY - 0.5))
        }
        path.stroke()
        let shown = cells(intersecting: visible)
        appearance.performAsCurrentDrawingAppearance { drawText(of: shown, selection: selection, omitting: editedCell) }
    }

    private func drawText(of shown: (rows: Range<Int>, columns: Range<Int>), selection: SelectionPaint?, omitting editedCell: CellCoord?) {
        for row in shown.rows {
            let values = cells[row]
            for column in shown.columns where column < values.count && column < alignments.count {
                guard editedCell != CellCoord(row: row, column: column) else { continue }
                let content = cellRects[row][column].insetBy(dx: Self.horizontalPadding, dy: Self.verticalPadding)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: cellRects[row][column]).addClip()
                var value = values[column]
                if let selection, selection.cells.contains(CellCoord(row: row, column: column)) {
                    selection.background.setFill()
                    for line in Self.lineRects(of: value, width: content.width) {
                        line.offsetBy(dx: content.minX, dy: content.minY).fill()
                    }
                    if let color = selection.text {
                        let recolored = NSMutableAttributedString(attributedString: value)
                        recolored.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: recolored.length))
                        value = recolored
                    }
                }
                Self.drawText(value, in: content)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
}
