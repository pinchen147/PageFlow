import AppKit

/// the reference editor's table handle drag (doc 24 §5.7.6, §7.4.4): the table's source
/// block moves between top-level blocks as one Undo step, written as two span
/// edits (remove, then insert) so nothing between the two places restyles.
extension NativeTextViewCoordinator {

    /// The block boundary nearest `location`: the start of the block holding
    /// it, or of the next block when `after`. Blocks are separated by blank
    /// lines; the end of the text is a boundary too.
    static func blockBoundary(near location: Int, after: Bool, in text: NSString) -> Int {
        func isBlank(_ line: NSRange) -> Bool {
            text.substring(with: line).allSatisfy { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        }
        guard text.length > 0 else { return 0 }
        let here = text.lineRange(for: NSRange(location: min(location, text.length - 1), length: 0))
        /// The first non-blank line at or after `cursor`, past `skipping` non-blank lines first.
        func nextBlock(from cursor: Int, skippingBlock: Bool) -> Int {
            var cursor = cursor
            var inBlock = skippingBlock
            while cursor < text.length {
                let line = text.lineRange(for: NSRange(location: cursor, length: 0))
                if isBlank(line) {
                    inBlock = false
                } else if !inBlock {
                    return line.location
                }
                cursor = NSMaxRange(line)
            }
            return text.length
        }
        // On a blank line: the next block.
        if isBlank(here) { return nextBlock(from: here.location, skippingBlock: false) }
        if after { return nextBlock(from: here.location, skippingBlock: true) }
        // Back to the first line of this block.
        var start = here.location
        while start > 0 {
            let previous = text.lineRange(for: NSRange(location: start - 1, length: 0))
            if isBlank(previous) { break }
            start = previous.location
        }
        return start
    }

    /// Moves the table at `range` to the block boundary `target`. A drop on the
    /// table's own place, or inside a table, changes nothing.
    @discardableResult
    func moveTable(_ range: NSRange, to target: Int) -> Bool {
        guard let textView, textView.isEditable else { return false }
        let source = textView.string
        let text = source as NSString
        guard NSMaxRange(range) <= text.length, target >= 0, target <= text.length else { return false }
        let contentEnd = Self.contentEnd(of: range, in: text)
        // The block that leaves: the table's lines, plus one blank line after it
        // (or before it when it ends the note).
        var removed = text.lineRange(for: NSRange(location: range.location, length: contentEnd - range.location))
        let after = NSMaxRange(removed)
        if after < text.length, text.substring(with: text.lineRange(for: NSRange(location: after, length: 0)))
            .allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }) {
            removed.length += text.lineRange(for: NSRange(location: after, length: 0)).length
        } else if removed.location >= 2, text.substring(with: NSRange(location: removed.location - 2, length: 2)) == "\n\n" {
            removed = NSRange(location: removed.location - 1, length: removed.length + 1)
        }
        // Its own boundaries, or a point inside it: nothing to do.
        guard target < removed.location || target > NSMaxRange(removed) else { return false }
        if parsedDocument(for: source).tokens.contains(where: {
            $0.kind == .table && target > $0.range.location && target < Self.contentEnd(of: $0.range, in: text)
        }) { return false }
        var table = text.substring(with: NSRange(location: range.location, length: contentEnd - range.location))
        table += "\n\n"
        let undo = textView.undoManager
        let ownsGroup = undo.map { $0.groupingLevel == 0 && !$0.isUndoing && !$0.isRedoing } ?? false
        if ownsGroup { undo?.beginUndoGrouping() }
        defer { if ownsGroup { undo?.endUndoGrouping() } }
        tableEditingSession.retire()
        guard replaceSourceRanges([removed], with: "", expectedSource: source, actionName: "Move Table") else { return false }
        let updated = textView.string
        var insertAt = target > removed.location ? target - removed.length : target
        insertAt = min(insertAt, (updated as NSString).length)
        if insertAt == (updated as NSString).length {
            // At the end: the table follows the last block after one blank line.
            let tail = updated.hasSuffix("\n\n") ? "" : updated.hasSuffix("\n") ? "\n" : updated.isEmpty ? "" : "\n\n"
            table = tail + String(table.dropLast(2))
        }
        guard replaceSourceRanges([NSRange(location: insertAt, length: 0)], with: table, expectedSource: updated,
                                  actionName: "Move Table") else { return false }
        // The moved table comes back with every cell selected.
        let moved = insertAt + (table.hasPrefix("\n") ? (table.prefix { $0 == "\n" }.utf16.count) : 0)
        if let token = parsedDocument(for: textView.string).tokens.first(where: { $0.kind == .table && $0.range.location == moved }),
           let movedTable = MarkdownTableSource(source: textView.string, range: token.range),
           tableEditingSession.begin(range: token.range, row: 0, column: 0, selecting: .start) {
            tableEditingSession.setCellSelection(TableCellSelection(
                anchor: CellCoord(row: 0, column: 0), head: CellCoord(row: movedTable.rowCount - 1, column: movedTable.columnCount - 1)
            ))
        }
        return true
    }
}
