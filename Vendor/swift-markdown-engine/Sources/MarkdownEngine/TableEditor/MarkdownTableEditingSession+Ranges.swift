import AppKit

/// the reference editor's cell ranges (doc 24 §7.5): a rectangular selection of cells
/// that lives only in the session. Every range command rewrites the table once,
/// as one Undo step, and leaves bytes outside the target cells unchanged.
extension MarkdownTableEditingSession {

    static let tableCellsPasteboardType = NSPasteboard.PasteboardType("com.pageflow.table-cells")

    var isRangeMode: Bool { cellSelection != nil }

    // MARK: - Entering and leaving

    /// Make `selection` the range (nil returns to caret mode in the current cell).
    func setCellSelection(_ selection: TableCellSelection?) {
        guard let table else { return }
        cellSelection = selection?.clamped(to: table)
        if let selection = cellSelection {
            finishInput()
            endTypingRun()
            rangeSnapshot = Dictionary(uniqueKeysWithValues: selection.cells.map { ($0, cellSource($0, in: table) ?? "") })
            // In range mode the cell editor keeps the keyboard but shows nothing.
            setEditorShown(false)
            editor.insertionPointColor = .clear
            editor.selectedTextAttributes = [:]
            refreshing = true
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            refreshing = false
        } else {
            rangeSnapshot = [:]
            setEditorShown(true)
            editor.insertionPointColor = coordinator?.configuration.theme.bodyText ?? .textColor
            editor.selectedTextAttributes = coordinator?.textView?.selectedTextAttributes ?? NSTextView().selectedTextAttributes
        }
        grid?.needsDisplay = true
        coordinator?.selectionBar?.setNeedsUpdate()
    }

    /// The cell's raw source, as the snapshot and the clipboard keep it.
    func cellSource(_ cell: CellCoord, in table: MarkdownTableSource) -> String? {
        guard cell.row < table.rowCount, cell.column < table.columnCount else { return nil }
        let cells = table.rows[cell.row == 0 ? 0 : cell.row + 1].cells
        guard cell.column < cells.count else { return "" }
        return (table.source as NSString).substring(with: cells[cell.column].contentRange)
    }

    /// Leave range mode for a caret in `cell`, at its start or end.
    func collapseRange(to cell: CellCoord, atEnd: Bool) {
        setCellSelection(nil)
        select(row: cell.row, column: cell.column)
        place(atEnd ? .end : .start)
    }

    // MARK: - Mouse

    /// The drag that starts on a cell (doc 24 §7.5.2): inside the start cell it
    /// selects text; entering another cell makes a range at once; leaving the
    /// table before that makes a one-cell range.
    func trackSelection(from event: NSEvent) {
        // Only the press AppKit is dispatching is tracked; a synthesized click has no drag to follow.
        guard NSApp.currentEvent === event, NSEvent.pressedMouseButtons & 1 != 0,
              let grid, let window = grid.window, table != nil else { return }
        guard grid.geometry.cellRects.indices.contains(row), grid.geometry.cellRects[row].indices.contains(column) else { return }
        var tracker = TableDragTracker(anchor: CellCoord(row: row, column: column))
        let anchorRect = grid.geometry.cellRects[row][column].insetBy(dx: -1, dy: -1)
        let textStart = editor.characterIndexForInsertion(at: editor.convert(event.locationInWindow, from: nil))
        var last = event
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
            if next.type == .leftMouseUp { break }
            if next.type == .leftMouseDragged { last = next }
            if next.type == .periodic {
                // A release another window took ends the drag too.
                if NSEvent.pressedMouseButtons & 1 == 0 { break }
                _ = grid.autoscroll(with: last)
            }
            let point = grid.convert(last.locationInWindow, from: nil)
            let cell = grid.geometry.cell(at: point).map { CellCoord(row: $0.row, column: $0.column) }
            switch tracker.move(to: cell, outsideAnchor: !anchorRect.contains(point)) {
            case .text:
                let index = editor.characterIndexForInsertion(at: editor.convert(last.locationInWindow, from: nil))
                editor.setSelectedRange(NSRange(location: min(textStart, index), length: abs(index - textStart)))
            case .range(let selection):
                setCellSelection(selection)
            case .unchanged:
                break
            }
        }
    }

    /// Shift-click extends the range from its anchor, or from the caret's cell.
    func extendRange(to cell: CellCoord) {
        let anchor = cellSelection?.anchor ?? CellCoord(row: row, column: column)
        setCellSelection(TableCellSelection(anchor: anchor, head: cell))
    }

    // MARK: - Keys

    /// the reference editor's keys on a range; false hands the command to the cell editor.
    func handleRangeCommand(_ selector: Selector) -> Bool {
        guard let selection = cellSelection, let table else { return false }
        let columns = table.columnCount
        func cell(at index: Int) -> CellCoord { CellCoord(row: index / columns, column: index % columns) }
        let headIndex = selection.head.row * columns + selection.head.column
        switch selector {
        case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveDown(_:)):
            collapseRange(to: selection.head, atEnd: false)
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveUp(_:)):
            collapseRange(to: cell(at: max(0, headIndex - 1)), atEnd: true)
        case #selector(NSResponder.moveRightAndModifySelection(_:)):
            extendHead(by: 0, 1, in: table)
        case #selector(NSResponder.moveLeftAndModifySelection(_:)):
            extendHead(by: 0, -1, in: table)
        case #selector(NSResponder.moveDownAndModifySelection(_:)):
            extendHead(by: 1, 0, in: table)
        case #selector(NSResponder.moveUpAndModifySelection(_:)):
            extendHead(by: -1, 0, in: table)
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)),
             #selector(NSResponder.deleteToBeginningOfLine(_:)), #selector(NSResponder.deleteToEndOfLine(_:)),
             #selector(NSResponder.deleteWordBackward(_:)), #selector(NSResponder.deleteWordForward(_:)):
            deleteRange()
        case #selector(NSResponder.cancelOperation(_:)):
            // Escape never collapses a range; it only runs the Escape ladder.
            _ = coordinator?.selectionBar?.suppressForEscape()
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            // From the later of anchor and head in document order, as Tab from that cell.
            let anchorIndex = selection.anchor.row * columns + selection.anchor.column
            collapseRange(to: cell(at: max(anchorIndex, headIndex)), atEnd: true)
            return step(forward: selector == #selector(NSResponder.insertTab(_:)))
        case #selector(NSResponder.selectAll(_:)):
            selectWholeDocument()
        case #selector(NSResponder.moveToBeginningOfLine(_:)), #selector(NSResponder.moveToEndOfLine(_:)),
             #selector(NSResponder.moveToLeftEndOfLine(_:)), #selector(NSResponder.moveToRightEndOfLine(_:)),
             #selector(NSResponder.moveToBeginningOfDocument(_:)), #selector(NSResponder.moveToEndOfDocument(_:)),
             #selector(NSResponder.moveToBeginningOfParagraph(_:)), #selector(NSResponder.moveToEndOfParagraph(_:)),
             #selector(NSResponder.pageUp(_:)), #selector(NSResponder.pageDown(_:)):
            // Provisional (the reference editor leaves these native): a caret in the head cell, then the key.
            collapseRange(to: selection.head, atEnd: false)
            return false
        default:
            return true
        }
        return true
    }

    /// Shift-arrows at a text edge start or extend a range (the reference editor).
    func extendFromTextEdge(_ selector: Selector) -> Bool {
        guard cellSelection == nil, let table else { return false }
        let selection = editor.selectedRange()
        let length = (editor.string as NSString).length
        let start = CellCoord(row: row, column: column)
        switch selector {
        case #selector(NSResponder.moveRightAndModifySelection(_:)) where NSMaxRange(selection) == length && column + 1 < table.columnCount:
            setCellSelection(TableCellSelection(anchor: start, head: CellCoord(row: row, column: column + 1)))
        case #selector(NSResponder.moveLeftAndModifySelection(_:)) where selection.location == 0 && column > 0:
            setCellSelection(TableCellSelection(anchor: start, head: CellCoord(row: row, column: column - 1)))
        case #selector(NSResponder.moveDownAndModifySelection(_:)) where NSMaxRange(selection) == length && row + 1 < table.rowCount:
            setCellSelection(TableCellSelection(anchor: start, head: CellCoord(row: row + 1, column: column)))
        case #selector(NSResponder.moveUpAndModifySelection(_:)) where selection.location == 0 && row > 0:
            setCellSelection(TableCellSelection(anchor: start, head: CellCoord(row: row - 1, column: column)))
        default:
            return false
        }
        return true
    }

    private func extendHead(by rows: Int, _ columns: Int, in table: MarkdownTableSource) {
        guard let selection = cellSelection else { return }
        let head = CellCoord(row: min(max(0, selection.head.row + rows), table.rowCount - 1),
                             column: min(max(0, selection.head.column + columns), table.columnCount - 1))
        setCellSelection(TableCellSelection(anchor: selection.anchor, head: head))
    }

    /// ⌘A is the whole document (the reference editor scopes nothing to the table).
    func selectWholeDocument() {
        guard let main = coordinator?.textView else { return }
        setCellSelection(nil)
        end(selecting: 0)
        main.selectAll(nil)
    }

    // MARK: - Commands

    /// Rewrites the table as one source transaction; nil when it was refused.
    @discardableResult
    func rewriteTable(_ replacement: String, actionName: String,
                      columns reshape: ((inout [CGFloat?]) -> Void)? = nil) -> MarkdownTableSource? {
        finishInput()
        endTypingRun()
        guard let table, admittedSource() != nil, let coordinator, let main = coordinator.textView else { return nil }
        // One group holds the rewrite and the range's restore, so Undo brings both back.
        let undo = main.undoManager
        let ownsGroup = undo.map { $0.groupingLevel == 0 && !$0.isUndoing && !$0.isRedoing } ?? false
        if ownsGroup { undo?.beginUndoGrouping() }
        defer { if ownsGroup { undo?.endUndoGrouping() } }
        let selection = cellSelection
        applyingSource = true
        var accepted = false
        PerfTrace.time("range.replace") {
            accepted = coordinator.replaceSourceRanges([table.range], with: replacement, expectedSource: main.string,
                                                       actionName: actionName, selectionAfter: Self.documentCaret(in: table))
        }
        applyingSource = false
        guard accepted, let refreshed = MarkdownTableSource(
            source: main.string, range: NSRange(location: table.range.location, length: (replacement as NSString).length)
        ) else {
            retire()
            return nil
        }
        if let selection, let undo { registerRangeRestore(selection, tableAt: table.range.location, undo: undo) }
        adopt(refreshed)
        resyncFocusedCell()
        followWidths(reshape ?? { _ in })
        return refreshed
    }

    /// Undo runs this before the source edit it follows: the edit's
    /// notification then puts the range back (the reference editor keeps the range in
    /// each Undo step). Redo re-arms it for the next Undo.
    private func registerRangeRestore(_ selection: TableCellSelection, tableAt location: Int, undo: UndoManager) {
        guard let coordinator else { return }
        undo.registerUndo(withTarget: coordinator) { [weak self] _ in
            self?.pendingRangeRestore = (selection, location)
            undo.registerUndo(withTarget: coordinator) { [weak self] _ in
                self?.registerRangeRestore(selection, tableAt: location, undo: undo)
            }
        }
    }

    /// After an Undo's source edit: the range that edit replaced, if its table is still being edited.
    func applyPendingRangeRestore() {
        guard let restore = pendingRangeRestore else { return }
        pendingRangeRestore = nil
        let selection = restore.selection
        guard isActive, let table, table.range.location == restore.location,
              selection.rows.upperBound < table.rowCount, selection.columns.upperBound < table.columnCount else { return }
        select(row: selection.head.row, column: selection.head.column)
        setCellSelection(selection)
    }

    /// A file change under the range refuses destructive edits until reselection.
    private var rangeIsCurrent: Bool {
        guard let table, let selection = cellSelection else { return false }
        return selection.cells.allSatisfy { cellSource($0, in: table) == rangeSnapshot[$0] }
    }

    /// Backspace or Delete on a range: every cell deletes the table, full rows
    /// delete the rows, full columns delete the columns, anything else clears
    /// the cells and keeps the range.
    func deleteRange() {
        guard let selection = cellSelection, let table, rangeIsCurrent else { return }
        if selection.isFullRows(columnCount: table.columnCount), selection.isFullColumns(rowCount: table.rowCount) {
            let undo = coordinator?.textView?.undoManager
            let ownsGroup = undo.map { $0.groupingLevel == 0 && !$0.isUndoing && !$0.isRedoing } ?? false
            if ownsGroup { undo?.beginUndoGrouping() }
            defer { if ownsGroup { undo?.endUndoGrouping() } }
            let location = table.range.location
            setCellSelection(nil)
            if deleteTable(), let undo { registerRangeRestore(selection, tableAt: location, undo: undo) }
            return
        }
        if selection.isFullRows(columnCount: table.columnCount) {
            guard let text = MarkdownTableEditPlan.deletingRows(selection.rows, in: table),
                  let refreshed = rewriteTable(text, actionName: "Delete Rows") else { return }
            let target = CellCoord(row: min(selection.rows.lowerBound, refreshed.rowCount - 1), column: selection.columns.lowerBound)
            setCellSelection(nil)
            select(row: target.row, column: target.column)
            place(.start)
            remount()
            return
        }
        if selection.isFullColumns(rowCount: table.rowCount) {
            guard let text = MarkdownTableEditPlan.deletingColumns(selection.columns, in: table),
                  let refreshed = rewriteTable(text, actionName: "Delete Columns", columns: { widths in
                      widths.removeSubrange(min(selection.columns.lowerBound, widths.count)..<min(selection.columns.upperBound + 1, widths.count))
                  }) else { return }
            // A caret in the column that slid in, as after deleting rows (the
            // owner's call over the reference editor, which selects that column).
            let target = CellCoord(row: selection.rows.lowerBound, column: min(selection.columns.lowerBound, refreshed.columnCount - 1))
            setCellSelection(nil)
            select(row: target.row, column: target.column)
            place(.start)
            remount()
            return
        }
        let cleared = Dictionary(uniqueKeysWithValues: selection.cells.map { ($0, "") })
        guard rewriteTable(MarkdownTableEditPlan.replacingCells(cleared, in: table), actionName: "Clear Cells") != nil else { return }
        setCellSelection(selection)
        remount()
    }

    /// Typing over a range clears every selected cell and writes into the
    /// top-left one, as one Undo step (deviation b: the reference editor writes the head cell).
    func typeOverRange(_ text: String) {
        guard let selection = cellSelection, let table, rangeIsCurrent else { return }
        let encoded = Self.encodedCell(text, selection: NSRange(location: (text as NSString).length, length: 0),
                                       lineBreak: lineBreakSpelling()).text
        var values = Dictionary(uniqueKeysWithValues: selection.cells.map { ($0, "") })
        values[selection.topLeft] = encoded
        guard rewriteTable(MarkdownTableEditPlan.replacingCells(values, in: table), actionName: "Typing") != nil else { return }
        PerfTrace.time("range.collapse") { collapseRange(to: selection.topLeft, atEnd: true) }
        PerfTrace.time("range.remount") { remount() }
    }

    /// An input method composing over a range: clear the range and compose in its top-left cell.
    func prepareRangeForComposition() {
        guard let selection = cellSelection, let table, rangeIsCurrent else { return }
        let cleared = Dictionary(uniqueKeysWithValues: selection.cells.map { ($0, "") })
        guard rewriteTable(MarkdownTableEditPlan.replacingCells(cleared, in: table), actionName: "Typing") != nil else { return }
        collapseRange(to: selection.topLeft, atEnd: false)
        remount()
    }

    /// ⌘B, ⌘I, ⌘U, ⇧⌘X, Highlight over a range: the all-of rule across every
    /// selected cell, one rewrite (doc 24 §7.5.4).
    func formatRange(_ style: MarkdownInlineStyle) {
        guard let selection = cellSelection, let table, rangeIsCurrent else { return }
        var texts: [CellCoord: String] = [:]
        for cell in selection.cells {
            guard let source = cellSource(cell, in: table) else { continue }
            texts[cell] = source
        }
        func isCovered(_ text: String) -> Bool {
            let tokens = MarkdownTokenizer.parseTokensViaAST(in: text, memoizing: false)
            let state = MarkdownFormatStateCalculator.state(text: text as NSString, tokens: tokens, codeTokens: [],
                                                            selection: NSRange(location: 0, length: (text as NSString).length), isEditable: true)
            switch style {
            case .bold: return state.bold
            case .italic: return state.italic
            case .underline: return state.underline
            case .strikethrough: return state.strikethrough
            case .highlight: return state.highlight
            }
        }
        let filled = texts.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        let removing = !filled.isEmpty && filled.values.allSatisfy(isCovered)
        var values: [CellCoord: String] = [:]
        for (cell, text) in filled where isCovered(text) == removing {
            let ns = text as NSString
            guard let plan = MarkdownInlineFormatter.plan(text: ns, targetRange: NSRange(location: 0, length: ns.length), style: style,
                                                          tokens: MarkdownTokenizer.parseTokensViaAST(in: text, memoizing: false)) else { continue }
            values[cell] = ns.replacingCharacters(in: plan.replacementRange, with: plan.replacement)
        }
        guard !values.isEmpty,
              rewriteTable(MarkdownTableEditPlan.replacingCells(values, in: table), actionName: style.actionName) != nil else { return }
        setCellSelection(selection)
        remount()
    }

    // MARK: - Clipboard

    /// Export Markdown for other editors, retaining exact cell values for an
    /// internal grid paste. A whole-table selection preserves its literal source.
    func copyRange(cut: Bool) {
        guard let selection = cellSelection, let table else { return }
        let source = table.source as NSString
        let raw = selection.rows.map { row in
            selection.columns.map { column in
                cellSource(CellCoord(row: row, column: column), in: table) ?? ""
            }
        }
        let markdown: String
        if selection.isFullRows(columnCount: table.columnCount), selection.isFullColumns(rowCount: table.rowCount) {
            markdown = source.substring(with: table.range)
        } else {
            func line(_ physicalRow: Int) -> String {
                let cells = table.rows[physicalRow].cells
                return "|" + selection.columns.map { column in
                    var value = column < cells.count ? source.substring(with: cells[column].rawRange) : " "
                    // A borderless final cell can end in an unpaired escape.
                    // Separate it from the structural pipe we introduce.
                    if value.utf16.reversed().prefix(while: { $0 == 0x5C }).count % 2 != 0 {
                        value += " "
                    }
                    return value
                }.joined(separator: "|") + "|"
            }
            var lines = selection.rows.map { line($0 == 0 ? 0 : $0 + 1) }
            // The first selected row is the copied table's header. Keep the
            // selected columns' original delimiter/alignment spellings.
            lines.insert(line(1), at: 1)
            let newline = table.rows.first(where: { $0.lineEndingRange.length > 0 })
                .map { source.substring(with: $0.lineEndingRange) } ?? "\n"
            markdown = lines.joined(separator: newline)
        }
        let board = NSPasteboard.general
        board.clearContents()
        board.declareTypes([.string, Self.tableCellsPasteboardType], owner: nil)
        board.setString(markdown, forType: .string)
        if let data = try? JSONSerialization.data(withJSONObject: ["version": 1, "rows": raw]) {
            board.setData(data, forType: Self.tableCellsPasteboardType)
        }
        if cut {
            let cleared = Dictionary(uniqueKeysWithValues: selection.cells.map { ($0, "") })
            guard rangeIsCurrent,
                  rewriteTable(MarkdownTableEditPlan.replacingCells(cleared, in: table), actionName: "Cut") != nil else { return }
            setCellSelection(selection)
            remount()
        }
    }

    /// Paste over a range: a grid (PageFlow cells, an HTML table or a pipe
    /// table) repeats or crops to fit; anything else is tiled into every cell,
    /// with the caret at the end of the last one (the reference editor).
    func pasteIntoRange() {
        guard let selection = cellSelection, let table, rangeIsCurrent else { return }
        let board = NSPasteboard.general
        var values: [CellCoord: String] = [:]
        if let grid = Self.pastedGrid(from: board), !grid.isEmpty, !grid[0].isEmpty {
            for (r, row) in selection.rows.enumerated() {
                for (c, column) in selection.columns.enumerated() {
                    let line = grid[r % grid.count]
                    values[CellCoord(row: row, column: column)] = line[c % line.count]
                }
            }
        } else if let text = board.string(forType: .string) {
            let encoded = Self.encodedCell(text, selection: NSRange(location: 0, length: 0), lineBreak: lineBreakSpelling()).text
            for cell in selection.cells { values[cell] = encoded }
        } else {
            return
        }
        guard rewriteTable(MarkdownTableEditPlan.replacingCells(values, in: table), actionName: "Paste") != nil else { return }
        collapseRange(to: selection.bottomRight, atEnd: true)
        remount()
    }

    /// Pasting a grid from a caret in a cell overwrites from that cell and grows the table.
    func pasteGridAtCaret() -> Bool {
        guard cellSelection == nil, let table, let grid = Self.pastedGrid(from: NSPasteboard.general),
              grid.count > 1 || (grid.first?.count ?? 0) > 1 else { return false }
        let origin = CellCoord(row: row, column: column)
        let width = grid.map(\.count).max() ?? 1
        guard let grown = MarkdownTableEditPlan.growing(table, toRows: origin.row + grid.count, columns: origin.column + width),
              let grownTable = MarkdownTableSource(source: grown, range: NSRange(location: 0, length: (grown as NSString).length)) else { return false }
        var values: [CellCoord: String] = [:]
        for (r, line) in grid.enumerated() {
            for (c, value) in line.enumerated() { values[CellCoord(row: origin.row + r, column: origin.column + c)] = value }
        }
        let replacement = MarkdownTableEditPlan.replacingCells(values, in: grownTable)
        guard rewriteTable(replacement, actionName: "Paste") != nil else { return true }
        let last = CellCoord(row: origin.row + grid.count - 1, column: origin.column + width - 1)
        collapseRange(to: last, atEnd: true)
        remount()
        return true
    }

    /// Encoded cell values from the pasteboard: PageFlow's cells, an HTML
    /// `<table>`, or a Markdown pipe table. Tab-separated text is not a grid.
    static func pastedGrid(from board: NSPasteboard) -> [[String]]? {
        if let data = board.data(forType: tableCellsPasteboardType),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rows = object["rows"] as? [[String]] {
            return rows
        }
        if let html = board.string(forType: .html), let grid = htmlTableCells(html) {
            return grid.map { $0.map { encodedCell($0, selection: NSRange(location: 0, length: 0)).text } }
        }
        if let text = board.string(forType: .string), text.contains("|"),
           let table = MarkdownTableSource(source: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            let ns = text as NSString
            return ([0] + Array(2..<table.rows.count)).map { index in table.rows[index].cells.map { ns.substring(with: $0.contentRange) } }
        }
        return nil
    }

    /// The cells of the first `<table>` in `html`, as plain text (strict: `<table>` only).
    static func htmlTableCells(_ html: String) -> [[String]]? {
        guard let start = html.range(of: "<table", options: .caseInsensitive),
              let end = html.range(of: "</table>", options: .caseInsensitive, range: start.upperBound..<html.endIndex) else { return nil }
        let body = String(html[start.lowerBound..<end.upperBound])
        guard let rowPattern = try? NSRegularExpression(pattern: "<tr[^>]*>(.*?)</tr>", options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let cellPattern = try? NSRegularExpression(pattern: "<t[hd][^>]*>(.*?)</t[hd]>", options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let tagPattern = try? NSRegularExpression(pattern: "<br\\s*/?>", options: .caseInsensitive),
              let anyTag = try? NSRegularExpression(pattern: "<[^>]+>") else { return nil }
        let ns = body as NSString
        var grid: [[String]] = []
        for rowMatch in rowPattern.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let rowText = ns.substring(with: rowMatch.range(at: 1))
            let rowNS = rowText as NSString
            let cells = cellPattern.matches(in: rowText, range: NSRange(location: 0, length: rowNS.length)).map { match -> String in
                var cell = rowNS.substring(with: match.range(at: 1))
                cell = tagPattern.stringByReplacingMatches(in: cell, range: NSRange(location: 0, length: (cell as NSString).length), withTemplate: "\n")
                cell = anyTag.stringByReplacingMatches(in: cell, range: NSRange(location: 0, length: (cell as NSString).length), withTemplate: "")
                return unescapeHTML(cell).trimmingCharacters(in: .whitespaces)
            }
            if !cells.isEmpty { grid.append(cells) }
        }
        return grid.isEmpty ? nil : grid
    }

    private static func unescapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - Selection bar

    /// The bar's state for a range: a mark is on only when every selected cell carries it.
    func rangeFormatState() -> MarkdownFormatState {
        var state = MarkdownFormatState()
        guard let selection = cellSelection, let table else { return state }
        state.context = .cellRange(cells: selection.count)
        state.textStyle = nil
        state.linkEnabled = selection.count == 1
        let texts = selection.cells.compactMap { cellSource($0, in: table) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !texts.isEmpty else { return state }
        let states = texts.map { text -> MarkdownFormatState in
            let tokens = MarkdownTokenizer.parseTokensViaAST(in: text, memoizing: false)
            return MarkdownFormatStateCalculator.state(text: text as NSString, tokens: tokens, codeTokens: tokens.filter { $0.kind == .inlineCode },
                                                       selection: NSRange(location: 0, length: (text as NSString).length), isEditable: true)
        }
        state.bold = states.allSatisfy(\.bold)
        state.italic = states.allSatisfy(\.italic)
        state.underline = states.allSatisfy(\.underline)
        state.strikethrough = states.allSatisfy(\.strikethrough)
        state.code = states.allSatisfy(\.code)
        state.highlight = states.allSatisfy(\.highlight)
        state.link = states.allSatisfy(\.link)
        return state
    }

    /// The first and last selected cells' union, for the bar's anchor.
    func rangeRect(in view: NSView) -> NSRect? {
        guard let selection = cellSelection, let grid, grid.window != nil,
              grid.geometry.cellRects.indices.contains(selection.rows.upperBound) else { return nil }
        let first = grid.geometry.cellRects[selection.rows.lowerBound][selection.columns.lowerBound]
        let last = grid.geometry.cellRects[selection.rows.upperBound][selection.columns.upperBound]
        return grid.convert(first.union(last), to: view)
    }
}
