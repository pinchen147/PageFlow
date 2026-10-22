import Foundation

/// A logical cell address; row 0 is the GFM header.
struct CellCoord: Hashable {
    var row: Int
    var column: Int
}

/// A rectangular range of cells owned by the table session (doc 24 §7.5). The
/// document's own selection never changes while it exists.
struct TableCellSelection: Equatable {
    /// Where the drag or extension started.
    var anchor: CellCoord
    /// Where it currently ends.
    var head: CellCoord

    var rows: ClosedRange<Int> { min(anchor.row, head.row)...max(anchor.row, head.row) }
    var columns: ClosedRange<Int> { min(anchor.column, head.column)...max(anchor.column, head.column) }
    var topLeft: CellCoord { CellCoord(row: rows.lowerBound, column: columns.lowerBound) }
    var bottomRight: CellCoord { CellCoord(row: rows.upperBound, column: columns.upperBound) }
    var count: Int { rows.count * columns.count }

    /// Every cell in the range, row by row.
    var cells: [CellCoord] { rows.flatMap { row in columns.map { CellCoord(row: row, column: $0) } } }

    /// Follow a structural edit to the nearest surviving cells, preserving drag direction.
    func clamped(to table: MarkdownTableSource) -> Self {
        func clamp(_ cell: CellCoord) -> CellCoord {
            CellCoord(row: min(max(0, cell.row), table.rowCount - 1),
                      column: min(max(0, cell.column), table.columnCount - 1))
        }
        return Self(anchor: clamp(anchor), head: clamp(head))
    }

    func contains(_ cell: CellCoord) -> Bool { rows.contains(cell.row) && columns.contains(cell.column) }
    func isFullRows(columnCount: Int) -> Bool { columns == 0...(columnCount - 1) }
    func isFullColumns(rowCount: Int) -> Bool { rows == 0...(rowCount - 1) }
}

extension MarkdownTableSource {
    /// The cells a document selection reaches into, in document order: a cell
    /// counts when the selection covers any of its text (doc 24 §7.5.7).
    func cells(coveredBy selection: NSRange) -> Set<CellCoord> {
        var covered: Set<CellCoord> = []
        for (physical, line) in rows.enumerated() where physical != 1 {
            if line.lineRange.location >= NSMaxRange(selection) { break }
            guard NSMaxRange(line.lineRange) > selection.location else { continue }
            let row = physical == 0 ? 0 : physical - 1
            for (column, cell) in line.cells.prefix(columnCount).enumerated()
            where NSIntersectionRange(selection, cell.contentRange).length > 0 {
                covered.insert(CellCoord(row: row, column: column))
            }
        }
        return covered
    }
}

/// the reference editor's drag-select machine (doc 24 §5.5.3) without events: each
/// pointer move says what the drag selects now.
struct TableDragTracker {
    enum Step: Equatable {
        /// Keep selecting text inside the anchor cell.
        case text
        /// The range is now this rectangle.
        case range(TableCellSelection)
        /// Nothing changes.
        case unchanged
    }

    let anchor: CellCoord
    private(set) var selection: TableCellSelection?

    init(anchor: CellCoord) { self.anchor = anchor }

    /// `cell` is the cell under the pointer in the same table (nil outside it);
    /// `outsideAnchor` is whether the pointer is more than 1 pt outside the anchor cell.
    mutating func move(to cell: CellCoord?, outsideAnchor: Bool) -> Step {
        let next: TableCellSelection
        if let current = selection {
            // A range follows the pointer cell by cell, back to the anchor too;
            // outside the table it stays as it was.
            guard let cell, cell != current.head else { return .unchanged }
            next = TableCellSelection(anchor: anchor, head: cell)
        } else if let cell, cell != anchor {
            // Entering another cell makes the range at once.
            next = TableCellSelection(anchor: anchor, head: cell)
        } else if cell == nil, outsideAnchor {
            // Out of the table before entering another cell: the anchor cell alone.
            next = TableCellSelection(anchor: anchor, head: anchor)
        } else {
            return .text
        }
        selection = next
        return .range(next)
    }
}

extension MarkdownTableEditPlan {
    /// The table with each listed cell's content replaced by an already
    /// encoded value. Padding, pipes, escapes, line endings and every other
    /// cell stay byte for byte; a missing trailing cell is written with its
    /// separators only when it gets text.
    static func replacingCells(_ values: [CellCoord: String], in table: MarkdownTableSource) -> String {
        let source = table.source as NSString
        var edits: [(range: NSRange, text: String)] = []
        for (cell, value) in values {
            guard cell.row >= 0, cell.row < table.rowCount, cell.column >= 0, cell.column < table.columnCount else { continue }
            let cells = table.rows[cell.row == 0 ? 0 : cell.row + 1].cells
            if cell.column < cells.count {
                let target = cells[cell.column]
                var range = target.contentRange
                var text = value
                if range.length == 0 {
                    // An empty cell gets one space of padding each side: `|   |` → `| x |`.
                    if value.isEmpty { continue }
                    range = target.rawRange
                    text = " " + value + " "
                }
                // A trailing backslash must not escape the cell's closing pipe.
                if text.reversed().prefix(while: { $0 == "\\" }).count % 2 == 1 { text += " " }
                edits.append((range, text))
            } else if !value.isEmpty, let last = cells.last {
                let missing = cell.column - cells.count
                let prefix = String(repeating: "|  ", count: missing) + "| "
                edits.append((NSRange(location: NSMaxRange(last.rawRange), length: 0), prefix + value + " "))
            }
        }
        var result = source.substring(with: table.range)
        let base = table.range.location
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            let local = NSRange(location: edit.range.location - base, length: edit.range.length)
            result = (result as NSString).replacingCharacters(in: local, with: edit.text)
        }
        return result
    }

    /// The table without the given logical rows. Deleting the header makes the
    /// next remaining row the header (deviation a: a GFM table needs one).
    static func deletingRows(_ rows: ClosedRange<Int>, in table: MarkdownTableSource) -> String? {
        var text = (table.source as NSString).substring(with: table.range)
        // Work on the table's own text, so every range below is relative to it.
        guard var current = MarkdownTableSource(source: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        for row in rows.reversed() where row > 0 {
            guard let plan = MarkdownTableEditPlan(.deleteRow, table: current, row: row, column: 0) else { return nil }
            text = plan.replacement
            guard let next = MarkdownTableSource(source: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
            current = next
        }
        if rows.contains(0) {
            // Promote the first body row: its line takes the header's place.
            guard current.rowCount >= 2 else { return nil }
            let ns = text as NSString
            let header = current.rows[0], promoted = current.rows[2]
            let promotedContent = ns.substring(with: promoted.contentRange)
            let endedWithoutBreak = promoted.lineEndingRange.length == 0
            var rebuilt = ns.replacingCharacters(in: promoted.lineRange, with: "")
            // The table kept no final line break; neither does its new last line.
            if endedWithoutBreak, rebuilt.hasSuffix("\n") { rebuilt.removeLast() }
            if endedWithoutBreak, rebuilt.hasSuffix("\r") { rebuilt.removeLast() }
            text = (rebuilt as NSString).replacingCharacters(in: header.contentRange, with: promotedContent)
        }
        return text
    }

    /// The table without the given columns, delimiter cells included.
    static func deletingColumns(_ columns: ClosedRange<Int>, in table: MarkdownTableSource) -> String? {
        var current = table
        var text = (table.source as NSString).substring(with: table.range)
        for column in columns.reversed() {
            guard let plan = MarkdownTableEditPlan(.deleteColumn, table: current, row: 0, column: column) else { return nil }
            text = plan.replacement
            guard let next = MarkdownTableSource(source: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
            current = next
        }
        return text
    }

    /// The table grown to at least `rows` × `columns`, by appending blank rows
    /// and columns with the structural plans (a grid pasted past the edge).
    static func growing(_ table: MarkdownTableSource, toRows rows: Int, columns: Int) -> String? {
        var current = table
        var text = (table.source as NSString).substring(with: table.range)
        while current.columnCount < columns {
            guard let plan = MarkdownTableEditPlan(.insertColumn(right: true), table: current, row: 0, column: current.columnCount - 1) else { return nil }
            text = plan.replacement
            guard let next = MarkdownTableSource(source: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
            current = next
        }
        while current.rowCount < rows {
            guard let plan = MarkdownTableEditPlan(.insertRow(below: true), table: current, row: current.rowCount - 1, column: 0) else { return nil }
            text = plan.replacement
            guard let next = MarkdownTableSource(source: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
            current = next
        }
        return text
    }
}
