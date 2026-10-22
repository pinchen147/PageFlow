import AppKit

/// Comments in tables (doc 25 §1.3, §3.1): a range of selected cells is
/// anchored from its first cell's text to its last and each cell is filled;
/// text selected in a cell is anchored to that text and its line boxes are
/// painted. Both paint over the table's raster, blended so the ink keeps its
/// colour (multiply in light, screen in dark), as a `td` background does.
extension MarkdownCommentsController {

    /// What Comment would anchor to now.
    struct CommentTarget: Equatable {
        var range: NSRange
        var cells = false
    }

    /// The selection a comment would anchor to: a cell range, text in the
    /// focused cell, or document text with something besides space in it.
    var commentTarget: CommentTarget? {
        guard let main = textView, let session = coordinator?.tableEditingSession else { return nil }
        let text = main.string as NSString
        if session.isRangeMode, let selection = session.cellSelection, let table = session.table {
            return cellRangeTarget(rows: selection.rows, columns: selection.columns, in: table)
        }
        let range: NSRange
        if session.isActive {
            guard let mapped = session.sourceRange(ofEditorRange: session.editor.selectedRange()) else { return nil }
            range = mapped
        } else {
            range = main.selectedRange()
        }
        guard range.length > 0, NSMaxRange(range) <= text.length,
              !text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return CommentTarget(range: range)
    }

    /// From the top-left cell's text to the bottom-right cell's.
    private func cellRangeTarget(rows: ClosedRange<Int>, columns: ClosedRange<Int>, in table: MarkdownTableSource) -> CommentTarget? {
        func cell(_ row: Int, _ column: Int) -> MarkdownTableScanner.Cell? {
            let physical = row == 0 ? 0 : row + 1
            guard table.rows.indices.contains(physical), table.rows[physical].cells.indices.contains(column) else { return nil }
            return table.rows[physical].cells[column]
        }
        guard let first = cell(rows.lowerBound, columns.lowerBound) ?? cell(rows.lowerBound, 0),
              let last = cell(rows.upperBound, columns.upperBound) ?? table.rows[rows.upperBound == 0 ? 0 : rows.upperBound + 1].cells.last
        else { return nil }
        let start = first.contentRange.location
        let end = max(start + 1, NSMaxRange(last.contentRange))
        return CommentTarget(range: NSRange(location: start, length: end - start), cells: true)
    }

    // MARK: - Painting inside a table

    /// The rendered table holding `range`, if any.
    func table(holding range: NSRange, in main: NativeTextView) -> MarkdownTableSource? {
        guard let coordinator, let parsed = coordinator.parsedDocumentIfCached(for: main.string),
              let token = parsed.tokens.first(where: {
                  $0.kind == .table && range.location >= $0.range.location && NSMaxRange(range) <= NSMaxRange($0.range)
              }) else { return nil }
        return MarkdownTableSource(source: main.string, range: token.range)
    }

    /// The table's layout, kept until the next edit.
    private func geometry(for table: MarkdownTableSource) -> MarkdownTableLayout? {
        guard let coordinator else { return nil }
        let generation = coordinator.nativeSourceGeneration
        if let cached = tableGeometries[table.range.location], cached.generation == generation, cached.range == table.range {
            return cached.layout
        }
        guard let layout = coordinator.tableEditingSession.geometry(forTableAt: table.range) else { return nil }
        tableGeometries[table.range.location] = (generation, table.range, layout)
        return layout
    }

    /// What a thread inside a table paints, in the text view: each cell of a
    /// cell range, or the line boxes of text in a cell. Nil when `range` is
    /// not inside a rendered table.
    func tableInteriorRects(for range: NSRange, cells: Bool, in main: NativeTextView) -> [NSRect]? {
        guard let table = table(holding: range, in: main), let geometry = geometry(for: table),
              let canvas = main.tableCanvas(forTableAt: table.range) else { return nil }
        var clip = NSRect.infinite
        if canvas.view !== main, let overlay = canvas.view.enclosingScrollView {
            clip = overlay.contentView.convert(overlay.contentView.bounds, to: main)
        }
        func toMain(_ rect: NSRect) -> NSRect? {
            let converted = main.convertTableRect(rect, canvas: canvas).intersection(clip)
            return converted.isEmpty ? nil : converted
        }
        let covered = table.cells(coveredBy: range)
        guard !covered.isEmpty else { return [] }
        if cells {
            // The rectangle between the cells holding the anchor's two ends
            // (the source between them crosses other columns).
            guard let first = Self.cell(at: range.location, in: table),
                  let last = Self.cell(at: NSMaxRange(range) - 1, in: table) ?? Self.cell(at: NSMaxRange(range), in: table)
            else { return [] }
            var rects: [NSRect] = []
            for row in min(first.row, last.row)...max(first.row, last.row) where geometry.cellRects.indices.contains(row) {
                for column in min(first.column, last.column)...max(first.column, last.column)
                where geometry.cellRects[row].indices.contains(column) {
                    if let rect = toMain(geometry.cellRects[row][column]) { rects.append(rect) }
                }
            }
            return rects
        }
        let text = main.string as NSString
        var rects: [NSRect] = []
        for coord in covered.sorted(by: { ($0.row, $0.column) < ($1.row, $1.column) }) {
            let physical = coord.row == 0 ? 0 : coord.row + 1
            guard table.rows.indices.contains(physical), table.rows[physical].cells.indices.contains(coord.column),
                  geometry.cells.indices.contains(coord.row), geometry.cells[coord.row].indices.contains(coord.column) else { continue }
            let cell = table.rows[physical].cells[coord.column]
            let display = geometry.cells[coord.row][coord.column]
            let content = geometry.cellRects[coord.row][coord.column]
                .insetBy(dx: MarkdownTableLayout.horizontalPadding, dy: MarkdownTableLayout.verticalPadding)
            // The cell's text maps 1:1 when it shows as written; otherwise the whole text is marked.
            var local = NSRange(location: 0, length: display.length)
            if display.string == text.substring(with: cell.contentRange) {
                let inCell = NSIntersectionRange(range, cell.contentRange)
                local = NSRange(location: inCell.location - cell.contentRange.location, length: inCell.length)
            }
            for line in Self.lineRects(of: display, range: local, width: content.width) {
                if let rect = toMain(line.offsetBy(dx: content.minX, dy: content.minY)) { rects.append(rect) }
            }
        }
        return rects
    }

    /// The cell whose text (or, when empty, whose place between pipes) holds `location`.
    static func cell(at location: Int, in table: MarkdownTableSource) -> CellCoord? {
        for (physical, line) in table.rows.enumerated() where physical != 1 && NSLocationInRange(location, line.lineRange) {
            let row = physical == 0 ? 0 : physical - 1
            for (column, cell) in line.cells.prefix(table.columnCount).enumerated()
            where NSLocationInRange(location, cell.rawRange) || location == cell.contentRange.location {
                return CellCoord(row: row, column: column)
            }
        }
        return nil
    }

    /// The line boxes `range` of `text` covers, wrapped at `width`, as the raster draws it.
    static func lineRects(of text: NSAttributedString, range: NSRange, width: CGFloat) -> [NSRect] {
        guard range.length > 0, width > 0 else { return [] }
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rects: [NSRect] = []
        manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                        in: container) { rect, _ in
            rects.append(rect)
        }
        return rects
    }

    // MARK: - The blended layer over tables

    /// Keeps the layer over tables at the top of the document, blending as the appearance asks.
    func placeTableHighlights(in container: NSView, main: NativeTextView) {
        if let container = container as? NativeTextViewContainer {
            container.keepAboveWideTables(tableHighlights)
        } else if tableHighlights.superview !== container {
            container.addSubview(tableHighlights, positioned: .above, relativeTo: nil)
        }
        if tableHighlights.frame != container.bounds { tableHighlights.frame = container.bounds }
        let dark = CommentPalette.isDark(main.effectiveAppearance)
        if tableHighlightsDark != dark {
            tableHighlightsDark = dark
            tableHighlights.compositingFilter = CIFilter(name: dark ? "CIScreenBlendMode" : "CIMultiplyBlendMode")
        }
    }
}
