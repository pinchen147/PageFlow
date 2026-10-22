import AppKit

/// The arrow key that is moving the document caret, and where the caret was.
struct TableEntryIntent {
    enum Direction { case up, down, left, right }
    let direction: Direction
    let fromLocation: Int

    init?(_ selector: Selector, from location: Int) {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): direction = .up
        case #selector(NSResponder.moveDown(_:)): direction = .down
        case #selector(NSResponder.moveLeft(_:)): direction = .left
        case #selector(NSResponder.moveRight(_:)): direction = .right
        default: return nil
        }
        fromLocation = location
    }
}

/// The keyboard never shows a rendered table's Markdown (the reference editor): a caret
/// the document puts in a table's hidden source edits a cell instead, and no
/// prose edit writes into that source. Only Edit Table Source reveals it.
extension NativeTextViewCoordinator {

    /// Move the caret with `selector` and remember the key, so a caret that
    /// lands in a table enters the cell the reference editor enters: ↓ the first row
    /// under the caret, ↑ the last row, → the first cell, ← the last cell's end.
    func moveCaretRememberingTableEntry(_ selector: Selector, in textView: NSTextView) -> Bool {
        let selection = textView.selectedRange()
        guard pendingTableEntry == nil, selection.length == 0,
              let intent = TableEntryIntent(selector, from: selection.location) else { return false }
        pendingTableEntry = intent
        defer { pendingTableEntry = nil }
        textView.perform(selector, with: nil)
        return true
    }

    // MARK: - Gap caret

    /// Whether the caret is in the gap after a table that ends the note.
    func isAtTableGapCaret(_ textView: NSTextView) -> Bool {
        guard tableGapCaret != nil else { return false }
        let selection = textView.selectedRange()
        return selection.length == 0 && selection.location == (textView.string as NSString).length
    }

    /// Keys at the gap caret: ↑, ← and Backspace go back into the table;
    /// Return makes the paragraph the gap stands for; ↓ and → stay.
    func handleGapCaretCommand(_ selector: Selector, in textView: NSTextView) -> Bool? {
        guard isAtTableGapCaret(textView), let location = tableGapCaret else { return nil }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            makeParagraphAfterTableGap(in: textView)
            return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.deleteBackward(_:)):
            guard let token = parsedDocument(for: textView.string).tokens.first(where: {
                      $0.kind == .table && $0.range.location == location
                  }),
                  let table = MarkdownTableSource(source: textView.string, range: token.range) else { return nil }
            tableGapCaret = nil
            let up = selector == #selector(NSResponder.moveUp(_:))
            tableEditingSession.begin(range: token.range, row: table.rowCount - 1,
                                      column: up ? 0 : table.columnCount - 1, selecting: up ? .start : .end)
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveRight(_:)):
            return true
        default:
            return nil
        }
    }

    /// Backspace at the start of the line after a table (the reference editor): a
    /// non-empty line selects every cell, so a second Backspace deletes the
    /// table; an empty line goes away, or stays as the blank line that keeps
    /// the next paragraph out of the table, and the caret ends in the last cell.
    func handleBackspaceAfterTable(_ selector: Selector, in textView: NSTextView) -> Bool? {
        guard selector == #selector(NSResponder.deleteBackward(_:)), textView === self.textView, textView.isEditable,
              !isComposing(in: textView), let storage = textView.textStorage else { return nil }
        let selection = textView.selectedRange()
        let text = storage.mutableString
        guard selection.length == 0, selection.location > 0, selection.location <= text.length,
              text.character(at: selection.location - 1) == 0x0A else { return nil }
        func isBlank(_ line: NSRange) -> Bool {
            text.substring(with: line).allSatisfy { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        }
        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let lineIsBlank = isBlank(line)
        // The table's last line: the line just above, or above one blank line before non-empty text.
        var above = text.lineRange(for: NSRange(location: selection.location - 1, length: 0))
        if !lineIsBlank, isBlank(above), above.location > 0 {
            above = text.lineRange(for: NSRange(location: above.location - 1, length: 0))
        }
        guard let tableRange = Self.renderedTable(atLineOf: above.location, in: storage),
              Self.contentEnd(of: tableRange, in: text) <= NSMaxRange(above),
              let table = MarkdownTableSource(source: textView.string, range: tableRange) else { return nil }
        let session = tableEditingSession
        let last = CellCoord(row: table.rowCount - 1, column: table.columnCount - 1)
        if !lineIsBlank {
            guard session.begin(range: tableRange, row: last.row, column: last.column, selecting: .end) else { return nil }
            session.setCellSelection(TableCellSelection(anchor: CellCoord(row: 0, column: 0), head: last))
            return true
        }
        // An empty line after the table: remove it unless it is the blank line before more text.
        let next = NSMaxRange(line) < text.length ? text.lineRange(for: NSRange(location: NSMaxRange(line), length: 0)) : nil
        let removable = next.map(isBlank) ?? true
        if removable {
            let range = NSMaxRange(line) < text.length || line.length > 0
                ? line : NSRange(location: selection.location - 1, length: 1)
            guard replaceSourceRanges([range], with: "", expectedSource: textView.string, actionName: "Delete") else { return true }
        }
        guard let moved = parsedDocument(for: textView.string).tokens.first(where: {
                  $0.kind == .table && $0.range.location == tableRange.location
              }) else { return true }
        session.begin(range: moved.range, row: last.row, column: last.column, selecting: .end)
        return true
    }

    /// The first input at the gap caret makes a paragraph after the table:
    /// a blank line, then the caret on the new line.
    func makeParagraphAfterTableGap(in textView: NSTextView) {
        guard isAtTableGapCaret(textView) else { return }
        let end = (textView.string as NSString).length
        tableGapCaret = nil
        guard replaceSourceRanges([NSRange(location: end, length: 0)], with: "\n\n", expectedSource: textView.string,
                                  actionName: "Typing") else { return }
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    /// The caret indicator's frame at the gap caret: one line tall, at the
    /// start of the text column, just below the table.
    func tableGapCaretRect(in textView: NativeTextView) -> NSRect? {
        guard isAtTableGapCaret(textView), let location = tableGapCaret else { return nil }
        let bottom: CGFloat
        if let canvas = textView.tableCanvas(forTableAt: NSRange(location: location, length: 1)) {
            let table = canvas.view.bounds
            bottom = canvas.view === textView
                ? (textView.tableImageRect(at: location)?.maxY ?? table.maxY)
                : canvas.view.convert(NSPoint(x: 0, y: canvas.view.isFlipped ? table.maxY : table.minY), to: textView).y
        } else {
            return nil
        }
        let font = baseFontAndStyle().0
        let height = ceil(font.ascender - font.descender + font.leading)
        let x = textView.textContainerOrigin.x + (textView.textContainer?.lineFragmentPadding ?? 0)
        return NSRect(x: x, y: bottom + 6, width: 1, height: height)
    }

    /// Edit the cell that holds `selection` when it lies in one cell of a
    /// rendered table. Returns whether a cell took the selection.
    @discardableResult
    func enterTableCell(for selection: NSRange, in textView: NSTextView, parsed: ParsedDocument? = nil) -> Bool {
        let session = tableEditingSession
        if tableGapCaret != nil, isAtTableGapCaret(textView) { return false }
        guard textView === self.textView, textView.isEditable, textView.window != nil,
              !isWritingToolsActive, !isComposing(in: textView), selection.location != NSNotFound,
              let storage = textView.textStorage, NSMaxRange(selection) <= storage.length,
              Self.mayBeTableLine(storage.mutableString, at: selection.location) else { return false }
        let tokens = (parsed ?? parsedDocument(for: textView.string)).tokens
        guard let token = tokens.first(where: {
                  $0.kind == .table && selection.location >= $0.range.location
                      && NSMaxRange(selection) <= Self.contentEnd(of: $0.range, in: storage.mutableString)
              }),
              !session.owns(token.range), !session.isSourceRevealed(token.range),
              let table = MarkdownTableSource(source: textView.string, range: token.range) else { return false }
        if let intent = pendingTableEntry, intent.fromLocation < token.range.location || intent.fromLocation > NSMaxRange(token.range) {
            let last = table.rowCount - 1
            switch intent.direction {
            case .down, .up:
                let row = intent.direction == .down ? 0 : last
                let column = self.column(underCaretAt: intent.fromLocation, in: table, textView: textView) ?? 0
                return session.begin(range: token.range, row: row, column: column, selecting: .start)
            case .right:
                return session.begin(range: token.range, row: 0, column: 0, selecting: .start)
            case .left:
                return session.begin(range: token.range, row: last, column: table.columnCount - 1, selecting: .end)
            }
        }
        guard let target = Self.cell(containing: selection, in: table) else { return false }
        return session.begin(range: token.range, row: target.row, column: target.column, selecting: target.entry)
    }

    /// The cell holding `selection` and where its editor's selection goes. A
    /// selection that spans cells, or text outside them, is not a cell's.
    static func cell(
        containing selection: NSRange, in table: MarkdownTableSource
    ) -> (row: Int, column: Int, entry: MarkdownTableEditingSession.Entry)? {
        guard let physical = table.rows.firstIndex(where: {
            selection.location >= $0.lineRange.location && selection.location <= NSMaxRange($0.contentRange)
        }), NSMaxRange(selection) <= NSMaxRange(table.rows[physical].contentRange) else { return nil }
        // The delimiter row holds no cells: its caret goes to the first body row.
        guard physical != 1 else {
            return selection.length == 0 ? (min(1, table.rowCount - 1), 0, .start) : nil
        }
        let row = physical == 0 ? 0 : physical - 1
        let cells = table.rows[physical].cells
        guard let column = cells.firstIndex(where: { selection.location <= NSMaxRange($0.rawRange) }) else {
            // Past the row's last cell: the end of that cell, or a missing cell.
            guard selection.length == 0 else { return nil }
            return cells.count < table.columnCount ? (row, cells.count, .start) : (row, table.columnCount - 1, .end)
        }
        guard column < table.columnCount else { return selection.length == 0 ? (row, table.columnCount - 1, .end) : nil }
        let content = cells[column].contentRange
        if selection.length == 0 {
            if selection.location <= content.location { return (row, column, .start) }
            if selection.location >= NSMaxRange(content) { return (row, column, .end) }
            return (row, column, .range(NSRange(location: selection.location - content.location, length: 0)))
        }
        guard selection.location >= content.location, NSMaxRange(selection) <= NSMaxRange(content) else { return nil }
        return (row, column, .range(NSRange(location: selection.location - content.location, length: selection.length)))
    }

    /// The column whose rendered cell lies under the caret at `location`.
    private func column(underCaretAt location: Int, in table: MarkdownTableSource, textView: NSTextView) -> Int? {
        guard let native = textView as? NativeTextView, let window = textView.window,
              let canvas = native.tableCanvas(forTableAt: table.range),
              let geometry = tableEditingSession.geometry(for: table),
              let first = geometry.cellRects.first, !first.isEmpty else { return nil }
        let screen = textView.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
        guard !screen.isNull, screen.origin.x.isFinite else { return nil }
        let caretX = textView.convert(window.convertFromScreen(screen).origin, from: nil).x
        let edges = first.map { cell in
            canvas.view.convert(NSPoint(x: canvas.origin.x + cell.maxX, y: canvas.origin.y), to: textView).x
        }
        return edges.firstIndex(where: { caretX < $0 }) ?? first.count - 1
    }

    /// The rendered table whose hidden source a prose edit of `range` would
    /// write into without replacing the whole table. Rendered tables carry
    /// their anchor at their first line's start, so no parse is needed.
    func renderedTable(cutBy range: NSRange, in textView: NSTextView) -> NSRange? {
        guard let storage = textView.textStorage, range.location != NSNotFound,
              NSMaxRange(range) <= storage.length else { return nil }
        let text = storage.mutableString
        for endpoint in [range.location, NSMaxRange(range)] {
            guard let table = Self.renderedTable(atLineOf: endpoint, in: storage) else { continue }
            let end = Self.contentEnd(of: table, in: text)
            let cuts = range.length == 0
                ? range.location >= table.location && range.location <= end
                : range.location < end && NSMaxRange(range) > table.location
                    && !(range.location <= table.location && NSMaxRange(range) >= end)
            if cuts { return table }
        }
        return nil
    }

    /// The rendered table whose source holds the line at `location`.
    private static func renderedTable(atLineOf location: Int, in storage: NSTextStorage) -> NSRange? {
        let text = storage.mutableString
        guard location <= text.length else { return nil }
        var lineStart = text.lineRange(for: NSRange(location: location, length: 0)).location
        guard startsWithPipe(text, at: lineStart) else { return nil }
        while lineStart > 0 {
            let previous = text.lineRange(for: NSRange(location: lineStart - 1, length: 0)).location
            guard startsWithPipe(text, at: previous) else { break }
            lineStart = previous
        }
        guard lineStart < storage.length,
              let value = storage.attribute(.markdownTableSourceRange, at: lineStart, effectiveRange: nil) as? NSValue else {
            return nil
        }
        let table = AnchorRelativeRange.decode(value, anchorLocation: lineStart)
        return table.location <= location && location <= NSMaxRange(table) ? table : nil
    }

    /// The end of the table's last line, before its line break.
    static func contentEnd(of table: NSRange, in text: NSString) -> Int {
        var end = NSMaxRange(table)
        while end > table.location, [0x0A, 0x0D].contains(text.character(at: end - 1)) { end -= 1 }
        return end
    }

    /// Up to three spaces, then a pipe: how every table row this editor renders starts.
    private static func startsWithPipe(_ text: NSString, at lineStart: Int) -> Bool {
        var index = lineStart
        while index < text.length, index - lineStart <= 3 {
            let unit = text.character(at: index)
            if unit == 0x7C { return true }
            if unit != 0x20 { return false }
            index += 1
        }
        return false
    }

    /// A cheap filter before any parse: table lines start with a pipe, or are
    /// a delimiter row (`---|---`), which may omit its outer pipes.
    private static func mayBeTableLine(_ text: NSString, at location: Int) -> Bool {
        guard text.length > 0 else { return false }
        let lineStart = text.lineRange(for: NSRange(location: min(location, text.length - 1), length: 0)).location
        var index = lineStart
        while index < text.length, index - lineStart <= 3 {
            let unit = text.character(at: index)
            if unit == 0x7C || unit == 0x2D || unit == 0x3A { return true }
            if unit != 0x20 { return false }
            index += 1
        }
        return false
    }
}
