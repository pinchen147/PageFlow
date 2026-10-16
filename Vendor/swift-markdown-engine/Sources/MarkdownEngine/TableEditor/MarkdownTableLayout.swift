import AppKit

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
    /// keystroke formats and measures only the cell it changed.
    final class CellCache {
        fileprivate var context: [AnyHashable] = []
        fileprivate var theme: MarkdownEditorTheme?
        fileprivate var cells: [String: (text: NSAttributedString, size: NSSize)] = [:]
        /// Wrapped heights by cell key and wrap width.
        fileprivate var heights: [String: CGFloat] = [:]
        func removeAll() {
            cells.removeAll()
            heights.removeAll()
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
                text.addAttribute(.paragraphStyle, value: Self.paragraphStyle(alignment, lineHeight: lineHeight), range: whole)
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
        for row in formatted {
            var height = lineHeight
            for (column, value) in row.enumerated() where column < columns {
                let width = widths[column]
                guard value.size.width > width else {
                    height = max(height, value.size.height)
                    continue
                }
                let heightKey = "\(width)|" + value.key
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
        cellRects = rects
        size = NSSize(width: widths.reduce(1) { $0 + $1 + Self.horizontalPadding * 2 + 1 }, height: y)
        var colors = (border: theme.tableBorder, header: theme.tableHeaderFill)
        appearance.performAsCurrentDrawingAppearance {
            colors = (theme.tableBorder.usingColorSpace(.sRGB) ?? theme.tableBorder,
                      theme.tableHeaderFill.usingColorSpace(.sRGB) ?? theme.tableHeaderFill)
        }
        border = colors.border
        headerFill = colors.header
    }

    /// A cell's text: aligned to its column, wrapped at word boundaries, on the 1.45 line.
    private static func paragraphStyle(_ alignment: MarkdownStyler.TableAlignment, lineHeight: CGFloat) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        switch alignment {
        case .left: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .right: paragraph.alignment = .right
        }
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        return paragraph
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

    func image() -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in draw(); return true }
        Self.rasters.lock.withLock { Self.rasters.layouts.setObject(Box(self), forKey: image) }
        return image
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

    /// A raster's layout and its one selection variant, alive as long as the raster.
    private final class Box {
        let layout: MarkdownTableLayout
        var variant: (paint: SelectionPaint, image: NSImage)?
        init(_ layout: MarkdownTableLayout) { self.layout = layout }
    }

    private static let rasters = (lock: NSLock(), layouts: NSMapTable<NSImage, Box>.weakToStrongObjects())

    /// The layout `image` was drawn from, if it is a table raster: hover chrome
    /// hit-tests the exact cells the table shows.
    static func layout(ofRaster image: NSImage) -> MarkdownTableLayout? {
        rasters.lock.withLock { rasters.layouts.object(forKey: image)?.layout }
    }

    /// `raster` with `paint` on its covered cells, if it is a table raster.
    static func image(painting paint: SelectionPaint, of raster: NSImage) -> NSImage? {
        rasters.lock.withLock {
            guard let box = rasters.layouts.object(forKey: raster) else { return nil }
            if let variant = box.variant, variant.paint == paint { return variant.image }
            let layout = box.layout
            let image = NSImage(size: layout.size, flipped: true) { _ in layout.draw(selection: paint); return true }
            box.variant = (paint, image)
            return image
        }
    }

    /// Each line of `text` set at `width`, in the cell's content coordinates.
    private static func lineRects(of text: NSAttributedString, width: CGFloat) -> [NSRect] {
        guard text.length > 0 else { return [] }
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        var rects: [NSRect] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, used, _, _, _ in
            if used.width > 0 { rects.append(used) }
        }
        return rects
    }

    func draw(selection: SelectionPaint? = nil) {
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
        for (row, values) in cells.enumerated() {
            for (column, value) in values.enumerated() where column < alignments.count {
                let content = cellRects[row][column].insetBy(dx: Self.horizontalPadding, dy: Self.verticalPadding)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: cellRects[row][column]).addClip()
                var value = value
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
                value.draw(with: content, options: [.usesLineFragmentOrigin], context: nil)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
}
