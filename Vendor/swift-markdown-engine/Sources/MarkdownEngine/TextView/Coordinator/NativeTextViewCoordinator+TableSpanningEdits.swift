import AppKit

/// the reference editor's edits over a selection that crosses a table's edge (doc 24
/// §5.5.6 item 3): the structure stays. Covered cells lose their covered text,
/// a table inside the selection goes, the text at either end is trimmed, and
/// typed text lands where the selection starts.
extension NativeTextViewCoordinator {

    /// Replaces `range`, which cuts a rendered table, with `text` the way
    /// the reference editor does. Returns false when no table's edge lies in `range`.
    @discardableResult
    func replaceAcrossTables(_ range: NSRange, with text: String, in textView: NSTextView) -> Bool {
        let source = textView.string
        let ns = source as NSString
        guard range.length > 0, NSMaxRange(range) <= ns.length else { return false }
        let start = range.location, end = NSMaxRange(range)
        let tokens = parsedDocument(for: source).tokens.filter { $0.kind == .table }
        // The table the selection starts in, and the one it ends in.
        let first = tokens.first { start >= $0.range.location && start < Self.contentEnd(of: $0.range, in: ns) }
            .flatMap { MarkdownTableSource(source: source, range: $0.range) }
        let last = tokens.first { end > $0.range.location && end <= Self.contentEnd(of: $0.range, in: ns) }
            .flatMap { MarkdownTableSource(source: source, range: $0.range) }
        guard first != nil || last != nil else { return false }
        let cellText = MarkdownTableEditingSession.encodedCell(text, selection: NSRange(location: 0, length: 0)).text

        var replaced: NSRange
        var replacement: String
        var caret: (cell: CellCoord, offset: Int)?
        if let first, let last, first.range.location == last.range.location {
            // Both ends in one table: only its covered cells change.
            let trimmed = Self.trimmedTable(first, removing: range, inserting: cellText, at: start)
            replaced = NSRange(location: first.range.location, length: Self.contentEnd(of: first.range, in: ns) - first.range.location)
            replacement = trimmed.text
            caret = trimmed.caret
        } else {
            var head = text
            var from = start
            if let first {
                let firstEnd = Self.contentEnd(of: first.range, in: ns)
                let trimmed = Self.trimmedTable(first, removing: NSRange(location: start, length: firstEnd - start),
                                                inserting: cellText, at: start)
                head = trimmed.text
                caret = trimmed.caret
                from = first.range.location
            }
            if let last {
                let lastEnd = Self.contentEnd(of: last.range, in: ns)
                let tail = Self.trimmedTable(last, removing: NSRange(location: last.range.location, length: end - last.range.location),
                                             inserting: nil, at: nil).text
                // Two blocks need a blank line between them.
                replaced = NSRange(location: from, length: lastEnd - from)
                replacement = head + "\n\n" + tail
            } else {
                // The text after the selection keeps its own line below the table.
                var lineEnd = 0
                ns.getLineStart(nil, end: nil, contentsEnd: &lineEnd, for: NSRange(location: end, length: 0))
                replaced = NSRange(location: from, length: end - from)
                replacement = head + (lineEnd > end ? "\n\n" : "\n")
            }
        }
        guard replaceSourceRanges([replaced], with: replacement, expectedSource: source,
                                  actionName: text.isEmpty ? "Delete" : "Typing") else { return true }
        // The caret: after the typed text, in the cell or the text where the selection started.
        guard let first else {
            textView.setSelectedRange(NSRange(location: start + (text as NSString).length, length: 0))
            return true
        }
        let updated = textView.string
        guard let caret,
              let token = parsedDocument(for: updated).tokens.first(where: { $0.kind == .table && $0.range.location == first.range.location }),
              let table = MarkdownTableSource(source: updated, range: token.range) else { return true }
        let cells = table.rows[caret.cell.row == 0 ? 0 : caret.cell.row + 1].cells
        guard caret.cell.column < cells.count else { return true }
        textView.setSelectedRange(NSRange(location: cells[caret.cell.column].contentRange.location + caret.offset, length: 0))
        enterTableCell(for: textView.selectedRange(), in: textView)
        return true
    }

    /// `table` without the text `cut` covers in its cells, with `text` (already
    /// encoded for a cell) at `location`, and where that text ends.
    static func trimmedTable(
        _ table: MarkdownTableSource, removing cut: NSRange, inserting text: String?, at location: Int?
    ) -> (text: String, caret: (cell: CellCoord, offset: Int)?) {
        let source = table.source as NSString
        var values: [CellCoord: String] = [:]
        var caret: (cell: CellCoord, offset: Int)?
        var firstCovered: (cell: CellCoord, range: NSRange)?
        for (physical, line) in table.rows.enumerated() where physical != 1 {
            let row = physical == 0 ? 0 : physical - 1
            for (column, cell) in line.cells.prefix(table.columnCount).enumerated() {
                let content = cell.contentRange
                let coord = CellCoord(row: row, column: column)
                let overlap = NSIntersectionRange(cut, content)
                if firstCovered == nil, let location, content.location >= location || overlap.length > 0 {
                    firstCovered = (coord, content)
                }
                let insertsHere = text != nil && caret == nil
                    && location.map { $0 >= content.location && $0 <= NSMaxRange(content) } == true
                guard overlap.length > 0 || insertsHere else { continue }
                var value = source.substring(with: content) as NSString
                if overlap.length > 0 {
                    value = value.replacingCharacters(in: NSRange(location: overlap.location - content.location, length: overlap.length),
                                                      with: "") as NSString
                }
                if insertsHere, let text, let location {
                    let index = min(max(0, location - content.location), value.length)
                    value = value.replacingCharacters(in: NSRange(location: index, length: 0), with: text) as NSString
                    caret = (coord, index + (text as NSString).length)
                }
                values[coord] = value as String
            }
        }
        // A selection that starts on a pipe or the delimiter row: the first cell after it takes the text.
        if caret == nil, let text, let target = firstCovered {
            let value = values[target.cell] ?? source.substring(with: target.range)
            values[target.cell] = text + value
            caret = (target.cell, (text as NSString).length)
        }
        return (MarkdownTableEditPlan.replacingCells(values, in: table), caret)
    }
}
