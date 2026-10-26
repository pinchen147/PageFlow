import Foundation

/// Structural commands for the focused cell's table.
enum MarkdownTableEdit: Equatable {
    case insertRow(below: Bool)
    case deleteRow
    case insertColumn(right: Bool)
    case deleteColumn
    case align(MarkdownTableAlignment)

    var actionName: String {
        switch self {
        case .insertRow: "Insert Row"
        case .deleteRow: "Delete Row"
        case .insertColumn: "Insert Column"
        case .deleteColumn: "Delete Column"
        case .align: "Align Column"
        }
    }
}

/// A source-preserving rewrite of one table. Untouched cells keep their padding,
/// escapes, pipes and line endings byte for byte; only the edited structure changes.
struct MarkdownTableEditPlan {
    /// Replaces the table's whole source range as one Undo action.
    let replacement: String
    /// The logical cell to focus afterwards (row 0 is the header).
    let row: Int
    let column: Int

    /// One physical row split into verbatim pieces: `prefix + cells.joined("|") + suffix + lineEnding`.
    private struct Line {
        var prefix: String
        var cells: [String]
        var suffix: String
        var lineEnding: String
        var text: String { prefix + cells.joined(separator: "|") + suffix + lineEnding }
    }

    init?(_ edit: MarkdownTableEdit, table: MarkdownTableSource, row: Int, column: Int) {
        guard row >= 0, row < table.rowCount, column >= 0, column < table.columnCount else { return nil }
        var lines = Self.lines(of: table)
        let hasTrailingPipe = table.rows.map { $0.trailingPipeRange != nil }
        var focus = (row: row, column: column)

        switch edit {
        case .insertRow(let below):
            guard row > 0 || below else { return nil }
            // Logical body row r lives at physical line r + 1; the delimiter is line 1.
            let index = row + 1 + (below ? 1 : 0)
            let neighbor = lines[min(index, lines.count) - 1]
            var inserted = Line(
                prefix: neighbor.prefix,
                cells: lines[0].cells.indices.map { Self.blank(width: lines[0].cells[$0].utf16.count) },
                suffix: neighbor.suffix,
                lineEnding: Self.lineEnding(lines, near: index)
            )
            if index == lines.count, lines[index - 1].lineEnding.isEmpty {
                // Keep a document that ended without a final line break that way.
                lines[index - 1].lineEnding = inserted.lineEnding
                inserted.lineEnding = ""
            }
            lines.insert(inserted, at: index)
            focus.row = index - 1
        case .deleteRow:
            guard row > 0 else { return nil }
            let index = row + 1
            if index == lines.count - 1, lines[index].lineEnding.isEmpty {
                lines[index - 1].lineEnding = ""
            }
            lines.remove(at: index)
            focus.row = min(row, lines.count - 2)
        case .insertColumn(let right):
            let at = column + (right ? 1 : 0)
            let width = lines[0].cells[column].utf16.count
            for index in lines.indices {
                while lines[index].cells.count < at { lines[index].cells.append(Self.blank(width: 2)) }
                lines[index].cells.insert(index == 1 ? Self.delimiter(width: width) : Self.blank(width: width), at: at)
                // A blank first or last cell needs an outer pipe to count as a cell.
                if at == 0, table.rows[index].leadingPipeRange == nil {
                    lines[index].prefix += "|"
                }
                if at == lines[index].cells.count - 1, !hasTrailingPipe[index] {
                    lines[index].suffix = "|" + lines[index].suffix
                }
            }
            focus.column = at
        case .deleteColumn:
            guard table.columnCount > 1 else { return nil }
            for index in lines.indices where column < lines[index].cells.count {
                lines[index].cells.remove(at: column)
                // A blank edge cell, or a lone cell, needs its outer pipe to stay
                // a cell; without it the row's values shift a column.
                let cells = lines[index].cells
                func blank(_ cell: String?) -> Bool { cell?.trimmingCharacters(in: .whitespaces).isEmpty == true }
                if table.rows[index].leadingPipeRange == nil, cells.count == 1 || blank(cells.first) {
                    lines[index].prefix += "|"
                }
                if !hasTrailingPipe[index], cells.count == 1 || blank(cells.last) {
                    lines[index].suffix = "|" + lines[index].suffix
                }
            }
            focus.column = min(column, table.columnCount - 2)
        case .align(let alignment):
            let raw = lines[1].cells[column]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard let start = raw.range(of: trimmed) else { return nil }
            let dashes = String(repeating: "-", count: max(3, trimmed.filter { $0 == "-" }.count))
            // Align left is the reference editor's "none": plain dashes.
            let marker = switch alignment {
            case .left: dashes
            case .center: ":" + dashes + ":"
            case .right: dashes + ":"
            }
            lines[1].cells[column] = raw.replacingCharacters(in: start, with: marker)
        }

        replacement = lines.map(\.text).joined()
        self.row = focus.row
        self.column = focus.column
    }

    /// The table's physical lines, split into verbatim pieces.
    private static func lines(of table: MarkdownTableSource) -> [Line] {
        let source = table.source as NSString
        return table.rows.map { scanned -> Line in
            let first = scanned.cells[0].rawRange.location
            let last = NSMaxRange(scanned.cells[scanned.cells.count - 1].rawRange)
            return Line(
                prefix: source.substring(with: NSRange(location: scanned.lineRange.location, length: first - scanned.lineRange.location)),
                cells: scanned.cells.map { source.substring(with: $0.rawRange) },
                suffix: source.substring(with: NSRange(location: last, length: NSMaxRange(scanned.contentRange) - last)),
                lineEnding: source.substring(with: scanned.lineEndingRange)
            )
        }
    }

    /// `lines` reordered, each position keeping its own line ending (a table
    /// that ended without a final break still does).
    private static func joined(_ lines: [Line], endings: [String]) -> String {
        zip(lines, endings).map { line, ending in
            var line = line
            line.lineEnding = ending
            return line.text
        }.joined()
    }

    // MARK: - Moving and sorting (doc 24 §5.4.5, §5.7.5, §5.9.4)

    /// The table with body row `row` moved to `boundary` (before logical row
    /// `boundary`; `rowCount` is after the last). Nil for the header, a drop
    /// above the header, or a drop on the row's own boundaries.
    static func movingRow(_ row: Int, to boundary: Int, in table: MarkdownTableSource) -> String? {
        guard row >= 1, row < table.rowCount, boundary >= 1, boundary <= table.rowCount,
              boundary != row, boundary != row + 1 else { return nil }
        var lines = Self.lines(of: table)
        let endings = lines.map(\.lineEnding)
        let moved = lines.remove(at: row + 1)
        lines.insert(moved, at: (boundary > row ? boundary - 1 : boundary) + 1)
        return joined(lines, endings: endings)
    }

    /// The table with `column` moved to `boundary` (before column `boundary`;
    /// `columnCount` is after the last), alignment cell included. Nil for a
    /// drop on the column's own boundaries.
    static func movingColumn(_ column: Int, to boundary: Int, in table: MarkdownTableSource) -> String? {
        guard column >= 0, column < table.columnCount, boundary >= 0, boundary <= table.columnCount,
              boundary != column, boundary != column + 1 else { return nil }
        let destination = boundary > column ? boundary - 1 : boundary
        var lines = Self.lines(of: table)
        for index in lines.indices {
            // A row missing trailing cells gets blank ones up to the moved positions.
            while lines[index].cells.count <= max(column, destination) { lines[index].cells.append(Self.blank(width: 2)) }
            let cell = lines[index].cells.remove(at: column)
            lines[index].cells.insert(cell, at: destination)
            // A blank edge cell needs its outer pipe to stay a cell.
            func blank(_ cell: String?) -> Bool { cell?.trimmingCharacters(in: .whitespaces).isEmpty == true }
            if table.rows[index].leadingPipeRange == nil, blank(lines[index].cells.first) { lines[index].prefix += "|" }
            if table.rows[index].trailingPipeRange == nil, blank(lines[index].cells.last) {
                lines[index].suffix = "|" + lines[index].suffix
            }
        }
        return lines.map(\.text).joined()
    }

    /// The body rows sorted by `keys` (one per body row, the column's displayed
    /// text), number-aware and stable; the header and delimiter stay. Nil with
    /// fewer than two body rows or when the order would not change.
    static func sortingRows(by keys: [String], ascending: Bool, in table: MarkdownTableSource) -> String? {
        let bodyCount = table.rowCount - 1
        guard bodyCount >= 2, keys.count == bodyCount else { return nil }
        let order = keys.indices.sorted { a, b in
            let result = keys[a].localizedStandardCompare(keys[b])
            if result == .orderedSame { return a < b }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
        guard order != Array(keys.indices) else { return nil }
        var lines = Self.lines(of: table)
        let endings = lines.map(\.lineEnding)
        let body = order.map { lines[$0 + 2] }
        lines.replaceSubrange(2..., with: body)
        return joined(lines, endings: endings)
    }

    /// Match an existing column's raw width so aligned source stays aligned.
    private static func blank(width: Int) -> String { String(repeating: " ", count: max(2, width)) }

    private static func delimiter(width: Int) -> String { " " + String(repeating: "-", count: max(3, width - 2)) + " " }

    private static func lineEnding(_ lines: [Line], near index: Int) -> String {
        let candidates = [index - 1, index, 1].filter { lines.indices.contains($0) }
        return candidates.lazy.map { lines[$0].lineEnding }.first { !$0.isEmpty } ?? "\n"
    }
}
