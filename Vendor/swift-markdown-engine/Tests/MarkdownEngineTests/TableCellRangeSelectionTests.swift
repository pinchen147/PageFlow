import AppKit
import Testing
@testable import MarkdownEngine

/// the reference editor's cell ranges (doc 24 §7.5, §8.4): the range lives in the
/// session, every command is one Undo step, and bytes outside the target
/// cells never change.
@MainActor
@Suite("Table cell ranges", .serialized)
struct TableCellRangeSelectionTests {
    static let source = "Intro\n\n| A | B | C |\n| --- | --- | --- |\n| a1 | b1 | c1 |\n| a2 | b2 | c2 |\n\nAfter"

    private func table(_ text: String) throws -> MarkdownTableSource {
        let start = (text as NSString).range(of: "|").location
        let end = (text as NSString).range(of: "|", options: .backwards).location + 1
        return try #require(MarkdownTableSource(source: text, range: NSRange(location: start, length: end - start)))
    }

    private func range(_ a: (Int, Int), _ b: (Int, Int)) -> TableCellSelection {
        TableCellSelection(anchor: CellCoord(row: a.0, column: a.1), head: CellCoord(row: b.0, column: b.1))
    }

    // MARK: - Plans

    @Test("replaceCells keeps every untouched byte: CRLF, escapes, uneven padding, missing cells")
    func replaceCellsIsByteExact() throws {
        let text = "|A|  B  |C|\r\n|:-|---:|---|\r\n| x\\|y |   q   |\r\n|  | w |z|"
        let t = try table(text)
        let result = MarkdownTableEditPlan.replacingCells([CellCoord(row: 1, column: 1): "Q", CellCoord(row: 2, column: 0): "e",
                                                          CellCoord(row: 1, column: 2): "new"], in: t)
        #expect(result == "|A|  B  |C|\r\n|:-|---:|---|\r\n| x\\|y |   Q   | new |\r\n| e | w |z|")
    }

    @Test("deleteRows on the header promotes the next row; the delimiter row stays")
    func deleteHeaderRow() throws {
        let t = try table("| A | B |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |")
        #expect(MarkdownTableEditPlan.deletingRows(0...0, in: t) == "| 1 | 2 |\n| --- | --- |\n| 3 | 4 |")
        #expect(MarkdownTableEditPlan.deletingRows(1...2, in: t) == "| A | B |\n| --- | --- |")
        // A table that does not start the text: ranges are relative to the table.
        let inside = "Intro\n\n| A | B |\n| --- | --- |\n| 1 | 2 |"
        let offset = try #require(MarkdownTableSource(source: inside, range: NSRange(location: 7, length: (inside as NSString).length - 7)))
        #expect(MarkdownTableEditPlan.deletingRows(0...0, in: offset) == "| 1 | 2 |\n| --- | --- |")
    }

    @Test("deleteColumns removes the alignment cells too")
    func deleteColumns() throws {
        let t = try table("| A | B | C |\n| :-- | :-: | --: |\n| 1 | 2 | 3 |")
        #expect(MarkdownTableEditPlan.deletingColumns(0...1, in: t) == "| C |\n| --: |\n| 3 |")
    }

    @Test("a table grows by whole rows and columns for a grid pasted past its edge")
    func growing() throws {
        let t = try table("| A | B |\n| --- | --- |\n| 1 | 2 |")
        let grown = try #require(MarkdownTableEditPlan.growing(t, toRows: 3, columns: 3))
        let g = try table(grown)
        #expect(g.rowCount == 3 && g.columnCount == 3)
    }

    @Test("random range edits leave every byte outside the target cells unchanged")
    func fuzz() throws {
        var seed: UInt64 = 7
        func random(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        for _ in 0..<60 {
            let columns = 2 + random(3), rows = 2 + random(3)
            var lines = ["|" + (0..<columns).map { " h\($0)" + String(repeating: " ", count: random(3)) + " " }.joined(separator: "|") + "|"]
            lines.append("|" + (0..<columns).map { _ in " --- " }.joined(separator: "|") + "|")
            for r in 0..<rows - 1 { lines.append("|" + (0..<columns).map { " v\(r)\($0)" + (random(4) == 0 ? "\\|" : "") + " " }.joined(separator: "|") + "|") }
            let text = lines.joined(separator: random(2) == 0 ? "\n" : "\r\n")
            let t = try table(text)
            let cell = CellCoord(row: random(rows), column: random(columns))
            let replaced = MarkdownTableEditPlan.replacingCells([cell: "NEW"], in: t)
            let after = try table(replaced)
            for r in 0..<rows {
                for c in 0..<columns where !(r == cell.row && c == cell.column) {
                    let physical = r == 0 ? 0 : r + 1
                    let before = (text as NSString).substring(with: t.rows[physical].cells[c].rawRange)
                    let now = (replaced as NSString).substring(with: after.rows[physical].cells[c].rawRange)
                    #expect(before == now)
                }
            }
        }
    }

    // MARK: - Session

    @Test("typing Z over a 2 × 2 range writes the top-left cell and empties the rest, as one Undo step")
    func typeOver() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        let cell = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        let mainSelection = editor.main.selectedRange()
        session.setCellSelection(range((1, 0), (2, 1)))
        #expect(editor.main.selectedRange() == mainSelection, "the document's selection never changes")
        cell.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.main.string == Self.source.replacingOccurrences(of: "| a1 | b1 |", with: "| Z |  |")
            .replacingOccurrences(of: "| a2 | b2 |", with: "|  |  |"))
        #expect(!session.isRangeMode)
        #expect(session.row == 1 && session.column == 0)
        #expect(cell.selectedRange() == NSRange(location: 1, length: 0))
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
    }

    @Test("pasting a word over a 2 × 2 range tiles it into all four cells; the caret ends in the last")
    func pasteTiles() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        let cell = try editor.focusCell(inTableContaining: "| A", row: 1, column: 1)
        session.setCellSelection(range((1, 1), (2, 2)))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("W", forType: .string)
        cell.paste(nil)
        #expect(editor.main.string.contains("| a1 | W | W |") && editor.main.string.contains("| a2 | W | W |"))
        #expect(session.row == 2 && session.column == 2)
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
    }

    @Test("Delete on full rows or full columns removes them as one Undo step and leaves a caret in what slid in")
    func deleteRowsAndColumns() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        let cell = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        session.setCellSelection(range((1, 0), (1, 2)))
        cell.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(!editor.main.string.contains("a1"))
        #expect(editor.state.undo.undoActionName == "Delete Rows")
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
        _ = try editor.focusCell(inTableContaining: "| A", row: 0, column: 1)
        session.setCellSelection(range((0, 1), (2, 1)))
        session.editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(editor.main.string.contains("| A | C |"))
        #expect(!session.isRangeMode, "a caret, not the column that slid in")
        #expect(session.row == 0 && session.column == 1)
        #expect(session.editor.selectedRange() == NSRange(location: 0, length: 0))
        #expect(session.editor.string == "C")
    }

    @Test("Delete on a partial range clears its cells and keeps the range; all cells delete the table")
    func clearAndDeleteTable() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        session.setCellSelection(range((1, 0), (2, 0)))
        session.editor.doCommand(by: #selector(NSResponder.deleteForward(_:)))
        #expect(editor.main.string.contains("|  | b1 | c1 |"))
        #expect(session.cellSelection == range((1, 0), (2, 0)))
        session.setCellSelection(range((0, 0), (2, 2)))
        session.editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(editor.main.string == "Intro\n\nAfter")
    }

    @Test("a range hides the anchor cell's editor so its tint shows; it keeps the keyboard")
    func rangeHidesTheAnchorEditor() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        let cell = try editor.focusCell(inTableContaining: "| A", row: 0, column: 0)
        let scroll = try #require(cell.enclosingScrollView)
        #expect(scroll.alphaValue == 1)
        session.setCellSelection(range((0, 0), (2, 0)))
        #expect(scroll.alphaValue == 0, "the editor's page-colour box would cover the tint")
        #expect(editor.window.firstResponder === cell)
        session.setCellSelection(nil)
        #expect(scroll.alphaValue == 1)
    }

    @Test("range and row/column rewrites leave the document a caret in the table, not the table selected")
    func rewritesLeaveACaret() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        func expectCaretInTable(_ label: String) throws {
            let table = try #require(session.table)
            let selection = editor.main.selectedRange()
            #expect(selection.length == 0, "\(label): TextKit greys a document selection around the table")
            #expect(NSLocationInRange(selection.location, table.range), "\(label)")
        }
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        session.setCellSelection(range((1, 0), (2, 0)))
        session.editor.doCommand(by: #selector(NSResponder.deleteForward(_:)))
        try expectCaretInTable("Clear Cells")
        session.setCellSelection(range((0, 1), (2, 1)))
        session.editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(editor.main.string.contains("| A | C |"))
        try expectCaretInTable("Delete Columns")
        session.setCellSelection(nil)
        session.perform(.deleteRow)
        try expectCaretInTable("Delete Row")
        session.perform(.insertColumn(right: true))
        try expectCaretInTable("Insert Column")
        editor.state.undo.undo()
        editor.state.undo.redo()
        try expectCaretInTable("Redo")
    }

    @Test("→ collapses to the start of the head; ← to the end of the cell before it; Escape keeps the range")
    func arrowsAndEscape() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        session.setCellSelection(range((1, 0), (2, 1)))
        session.editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        session.editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(session.cellSelection == range((1, 0), (2, 1)))
        session.editor.doCommand(by: #selector(NSResponder.moveRight(_:)))
        #expect(session.row == 2 && session.column == 1)
        #expect(session.editor.selectedRange().location == 0)
        session.setCellSelection(range((1, 0), (2, 1)))
        session.editor.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        #expect(session.row == 2 && session.column == 0)
        #expect(session.editor.selectedRange().location == 2)
    }

    @Test("Shift-→ at a cell's end starts a range; Shift-↓ extends it")
    func shiftArrows() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        let cell = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        cell.doCommand(by: #selector(NSResponder.moveRightAndModifySelection(_:)))
        #expect(session.cellSelection == range((1, 0), (1, 1)))
        cell.doCommand(by: #selector(NSResponder.moveDownAndModifySelection(_:)))
        #expect(session.cellSelection == range((1, 0), (2, 1)))
    }

    @Test("copy writes an HTML table and one plain line per cell; cut clears the cells")
    func copyAndCut() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        let cell = try editor.focusCell(inTableContaining: "| A", row: 0, column: 0)
        session.setCellSelection(range((0, 0), (1, 1)))
        cell.copy(nil)
        let board = NSPasteboard.general
        #expect(board.string(forType: .html) == "<table><tr><th>A</th><th>B</th></tr><tr><td>a1</td><td>b1</td></tr></table>")
        #expect(board.string(forType: .string) == "A\nB\na1\nb1")
        cell.cut(nil)
        #expect(editor.main.string.contains("|  |  | C |"))
        #expect(editor.state.undo.undoActionName == "Cut")
    }

    @Test("copied cells paste back with their exact Markdown, growing the table from a caret")
    func copyPasteRoundTrip() async throws {
        let editor = try MountedTableEditor(source: "| A | B |\n| --- | --- |\n| **x** | y\\|z |\n")
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        let cell = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        session.setCellSelection(range((1, 0), (1, 1)))
        cell.copy(nil)
        session.collapseRange(to: CellCoord(row: 1, column: 1), atEnd: true)
        session.editor.paste(nil)
        let table = try #require(session.table)
        #expect(table.columnCount == 3)
        #expect(editor.main.string.contains("| **x** | **x** | y\\|z |"))
    }

    @Test("Bold on a range follows the all-of rule as one Undo step")
    func boldRange() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        session.setCellSelection(range((1, 0), (1, 1)))
        editor.coordinator.didMarkdownBold(nil)
        #expect(editor.main.string.contains("| **a1** | **b1** | c1 |"))
        #expect(editor.state.undo.undoActionName == "Bold")
        #expect(session.rangeFormatState().bold)
        editor.coordinator.didMarkdownBold(nil)
        #expect(editor.main.string == Self.source)
    }

    @Test("a file change under a selected cell refuses the next destructive edit")
    func externalChangeGuard() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        session.setCellSelection(range((1, 0), (2, 0)))
        session.rangeSnapshot[CellCoord(row: 1, column: 0)] = "something else"
        session.editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(editor.main.string == Self.source)
        session.setCellSelection(range((1, 0), (2, 0)))
        session.editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(editor.main.string != Self.source, "reselecting clears the guard")
    }

    @Test("the bar's cell variant: a multi-cell range disables Link")
    func barCellVariant() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        session.setCellSelection(range((1, 0), (2, 1)))
        let state = session.rangeFormatState()
        #expect(state.context == .cellRange(cells: 4))
        #expect(!state.linkEnabled)
        session.setCellSelection(range((1, 0), (1, 0)))
        #expect(session.rangeFormatState().linkEnabled)
    }

    // MARK: - Drag

    @Test("a drag that stays in its cell selects text; entering a neighbour makes a range at once")
    func dragMachine() {
        var tracker = TableDragTracker(anchor: CellCoord(row: 1, column: 1))
        #expect(tracker.move(to: CellCoord(row: 1, column: 1), outsideAnchor: false) == .text)
        #expect(tracker.move(to: nil, outsideAnchor: false) == .text, "within 1 pt of the anchor: still text")
        #expect(tracker.move(to: CellCoord(row: 2, column: 1), outsideAnchor: true) == .range(range((1, 1), (2, 1))))
        #expect(tracker.move(to: CellCoord(row: 3, column: 1), outsideAnchor: true) == .range(range((1, 1), (3, 1))))
        #expect(tracker.selection == range((1, 1), (3, 1)), "rows 1–3 of column 1")
        #expect(tracker.move(to: nil, outsideAnchor: true) == .unchanged, "outside the table the range stays")
        #expect(tracker.move(to: CellCoord(row: 1, column: 1), outsideAnchor: false) == .range(range((1, 1), (1, 1))),
                "back on the anchor: one cell")
    }

    @Test("leaving the table before another cell selects the anchor cell; later moves outside change nothing")
    func dragOutOfTable() {
        var tracker = TableDragTracker(anchor: CellCoord(row: 0, column: 0))
        #expect(tracker.move(to: nil, outsideAnchor: true) == .range(range((0, 0), (0, 0))))
        #expect(tracker.move(to: nil, outsideAnchor: true) == .unchanged)
    }

    @Test("a pointer 0.5 pt into the neighbouring cell is in that cell")
    func neighbourHit() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        let geometry = try #require(session.grid?.geometry)
        let rect = geometry.cellRects[1][1]
        let hit = geometry.cell(at: NSPoint(x: rect.minX + 0.5, y: rect.midY))
        #expect(hit?.row == 1 && hit?.column == 1)
        var tracker = TableDragTracker(anchor: CellCoord(row: 1, column: 0))
        #expect(tracker.move(to: hit.map { CellCoord(row: $0.row, column: $0.column) }, outsideAnchor: false)
            == .range(range((1, 0), (1, 1))))
    }

    // MARK: - Undo and keys

    @Test("Undo of a range command brings the range back")
    func undoRestoresRange() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        let cell = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        session.setCellSelection(range((1, 0), (2, 1)))
        cell.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!session.isRangeMode)
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
        #expect(session.cellSelection == range((1, 0), (2, 1)))
        editor.state.undo.redo()
        #expect(editor.main.string.contains("| Z |  | c1 |"))
        editor.state.undo.undo()
        #expect(session.cellSelection == range((1, 0), (2, 1)), "Undo after Redo restores it again")
        session.setCellSelection(range((0, 0), (2, 2)))
        session.editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(editor.main.string == "Intro\n\nAfter")
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
        #expect(session.cellSelection == range((0, 0), (2, 2)), "a deleted table comes back with every cell selected")
    }

    @Test("Tab on a range goes to the cell after the later of anchor and head; Shift-Tab before it")
    func tabOnRange() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        session.setCellSelection(range((2, 1), (1, 0)))
        session.editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(!session.isRangeMode)
        #expect(session.row == 2 && session.column == 2)
        #expect(session.editor.selectedRange() == NSRange(location: 0, length: 2), "the cell's text is selected")
        session.setCellSelection(range((1, 0), (2, 1)))
        session.editor.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        #expect(session.row == 2 && session.column == 0)
        #expect(editor.main.string == Self.source)
    }

    // MARK: - Backspace after a table

    @Test("Backspace at the start of the paragraph after a table selects every cell; a second deletes the table")
    func backspaceAfterTable() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        editor.main.setSelectedRange(NSRange(location: (Self.source as NSString).range(of: "After").location, length: 0))
        editor.main.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(session.isActive)
        #expect(session.cellSelection == range((0, 0), (2, 2)))
        #expect(editor.main.string == Self.source)
        session.editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(editor.main.string == "Intro\n\nAfter")
    }

    @Test("Backspace on an empty line after a table removes it and puts the caret at the end of the last cell")
    func backspaceOnEmptyLineAfterTable() async throws {
        let extra = Self.source.replacingOccurrences(of: "\n\nAfter", with: "\n\n\nAfter")
        let editor = try MountedTableEditor(source: extra)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        let blank = (extra as NSString).range(of: "| a2 | b2 | c2 |\n").upperBound
        editor.main.setSelectedRange(NSRange(location: blank, length: 0))
        editor.main.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(editor.main.string == Self.source)
        #expect(session.isActive && !session.isRangeMode)
        #expect(session.row == 2 && session.column == 2)
        #expect(session.editor.selectedRange() == NSRange(location: 2, length: 0))
        // The one blank line before the next paragraph stays: without it the paragraph would join the table.
        session.retire()
        editor.main.setSelectedRange(NSRange(location: blank, length: 0))
        editor.main.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(editor.main.string == Self.source)
        #expect(session.isActive && session.row == 2 && session.column == 2)
    }

    // MARK: - A document selection over a table

    @Test("a document selection covers the cells it reaches, in document order")
    func coveredCells() throws {
        let source = Self.source as NSString
        let t = try table(Self.source)
        let intoB1 = NSRange(location: 0, length: source.range(of: "b1").location + 1)
        #expect(t.cells(coveredBy: intoB1) == [CellCoord(row: 0, column: 0), CellCoord(row: 0, column: 1), CellCoord(row: 0, column: 2),
                                              CellCoord(row: 1, column: 0), CellCoord(row: 1, column: 1)])
        let fromC2 = NSRange(location: source.range(of: "c2").location, length: source.length - source.range(of: "c2").location)
        #expect(t.cells(coveredBy: fromC2) == [CellCoord(row: 2, column: 2)])
        #expect(t.cells(coveredBy: NSRange(location: 0, length: source.length)).count == 9)
        #expect(t.cells(coveredBy: NSRange(location: 0, length: 3)).isEmpty)
    }

    @Test("the selection variant paints only the covered cells' text")
    func selectionVariantPaintsCoveredCells() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        let t = try table(Self.source)
        let layout = try #require(session.geometry(for: t))
        let raster = layout.image()
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let paint = MarkdownTableLayout.SelectionPaint(cells: [CellCoord(row: 1, column: 0)], background: red, text: nil)
        let variant = try #require(MarkdownTableLayout.image(painting: paint, of: raster))
        #expect(MarkdownTableLayout.image(painting: paint, of: raster) === variant, "cached per raster")
        let width = Int(ceil(layout.size.width)), height = Int(ceil(layout.size.height))
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        variant.draw(in: NSRect(x: 0, y: 0, width: layout.size.width, height: layout.size.height))
        NSGraphicsContext.restoreGraphicsState()
        func redPixels(in rect: NSRect) -> Int {
            var count = 0
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                    if color.redComponent > 0.9, color.greenComponent < 0.25, color.blueComponent < 0.25 { count += 1 }
                }
            }
            return count
        }
        let covered = redPixels(in: layout.cellRects[1][0])
        #expect(covered > 50, "the covered cell's text sits on the selection colour")
        #expect(redPixels(in: layout.cellRects[1][1]) == 0)
        #expect(redPixels(in: layout.cellRects[0][0]) == 0)
    }

    @Test("a selection from the text above into the table paints only the cells it covers, in the band's colour")
    func proseSelectionIntoTable() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        await editor.settle()
        let source = Self.source as NSString
        let anchor = source.range(of: "| A").location
        let imageRect = try #require(editor.main.tableImageRect(at: anchor))
        let layout = try #require(editor.coordinator.tableEditingSession.geometry(for: try table(Self.source)))
        editor.main.setSelectedRange(NSRange(location: 0, length: source.range(of: "b1").location + 1))
        #expect(!editor.coordinator.tableEditingSession.isActive, "a selection that starts in prose edits no cell")
        let visible = editor.main.visibleRect
        let bitmap = try #require(editor.main.bitmapImageRepForCachingDisplay(in: visible))
        editor.main.cacheDisplay(in: visible, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / visible.width
        // The band TextKit paints right of the selected first line (inactive: the test window is never key).
        let band = try #require(bitmap.colorAt(x: Int((visible.maxX - 10) * scale), y: Int(8 * scale))?.usingColorSpace(.sRGB))
        try #require(band.brightnessComponent < 0.95, "the first line is selected")
        func bandPixels(in cell: NSRect) -> Int {
            let rect = cell.offsetBy(dx: imageRect.minX - visible.minX, dy: imageRect.minY - visible.minY)
            var count = 0
            for y in Int(rect.minY * scale) + 2 ..< Int(rect.maxY * scale) - 2 {
                for x in Int(rect.minX * scale) + 2 ..< Int(rect.maxX * scale) - 2 {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if abs(color.redComponent - band.redComponent) < 0.02, abs(color.greenComponent - band.greenComponent) < 0.02,
                       abs(color.blueComponent - band.blueComponent) < 0.02 { count += 1 }
                }
            }
            return count
        }
        // A covered cell's highlight is hundreds of pixels; an uncovered one only has glyph edges.
        #expect(bandPixels(in: layout.cellRects[1][0]) > 300, "a1 is covered")
        #expect(bandPixels(in: layout.cellRects[1][1]) > 300, "b1 is partly covered")
        #expect(bandPixels(in: layout.cellRects[1][2]) < 60, "c1 is not, and the band does not show through")
        #expect(bandPixels(in: layout.cellRects[2][0]) < 60, "nor the row below")
        // A focus change repaints the table so its cells follow the band's colour.
        editor.window.displayIfNeeded()
        // TextKit draws the table's fragment in its own layer-backed view.
        let fragment = try #require(editor.main.subviews.flatMap(\.subviews).first {
            abs($0.frame.minY - imageRect.minY) < 2 && $0.frame.height >= imageRect.height
        })
        func pending(_ view: NSView) -> Bool { view.layer?.needsDisplay() == true }
        #expect(!pending(fragment))
        editor.main.redisplayTablesUnderSelection()
        #expect(pending(fragment), "the table's fragment redraws")
    }

    @Test("a wide table in its overlay gets the same paint, and repaints when the selection moves")
    func wideTableSelectionPaint() async throws {
        let header = "| " + (0..<8).map { "Column heading \($0)" }.joined(separator: " | ") + " |"
        let delimiter = "|" + String(repeating: " --- |", count: 8)
        let body = "| " + (0..<8).map { "value number \($0)" }.joined(separator: " | ") + " |"
        let source = "Intro\n\n" + [header, delimiter, body].joined(separator: "\n") + "\n\nAfter"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        await editor.settle()
        let overlay = try #require(editor.main.wideTableOverlays.values.first)
        let imageView = try #require(overlay.documentView as? WideTableImageView)
        let raster = try #require(imageView.image)
        #expect(editor.main.selectionPaintedTable(raster, tableRange: overlay.sourceRange) == nil)
        imageView.needsDisplay = false
        editor.main.setSelectedRange(NSRange(location: 0, length: (source as NSString).range(of: "value number 0").location + 3))
        #expect(editor.main.selectionPaintedTable(raster, tableRange: overlay.sourceRange) != nil)
        #expect(imageView.needsDisplay || imageView.layer?.needsDisplay() == true, "the overlay repaints for the new selection")
    }

    // MARK: - Edits over a selection across a table's edge

    static let edgeSource = "Intro text\n\n| A | B |\n| --- | --- |\n| a1 | b1 |\n\nAfter"

    @Test("typing over prose and the start of a table trims both and keeps the table, as one Undo step")
    func typeAcrossTableTop() async throws {
        let editor = try MountedTableEditor(source: Self.edgeSource)
        defer { editor.close() }
        let source = Self.edgeSource as NSString
        let start = source.range(of: "text").location
        editor.main.setSelectedRange(NSRange(location: start, length: source.range(of: "a1").location + 1 - start))
        editor.main.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.main.string == "Intro Z\n\n|  |  |\n| --- | --- |\n| 1 | b1 |\n\nAfter")
        #expect(editor.main.selectedRange() == NSRange(location: 7, length: 0))
        #expect(!editor.coordinator.tableEditingSession.isActive)
        editor.state.undo.undo()
        #expect(editor.main.string == Self.edgeSource)
    }

    @Test("Delete from inside a cell to the text below trims the cell and the text; the caret stays in the cell")
    func deleteAcrossTableBottom() async throws {
        let editor = try MountedTableEditor(source: Self.edgeSource)
        defer { editor.close() }
        let source = Self.edgeSource as NSString
        let start = source.range(of: "b1").location + 1
        editor.main.setSelectedRange(NSRange(location: start, length: source.range(of: "After").location + 2 - start))
        editor.main.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(editor.main.string == "Intro text\n\n| A | B |\n| --- | --- |\n| a1 | b |\n\nter")
        let session = editor.coordinator.tableEditingSession
        #expect(session.isActive && session.row == 1 && session.column == 1)
        #expect(session.editor.selectedRange() == NSRange(location: 1, length: 0))
    }

    @Test("typing over cells of one table changes only the covered text")
    func typeOverCellsOfOneTable() async throws {
        let editor = try MountedTableEditor(source: Self.edgeSource)
        defer { editor.close() }
        let source = Self.edgeSource as NSString
        let start = source.range(of: "a1").location + 1
        editor.main.setSelectedRange(NSRange(location: start, length: source.range(of: "b1").location + 1 - start))
        editor.main.insertText("Q", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.main.string == "Intro text\n\n| A | B |\n| --- | --- |\n| aQ | 1 |\n\nAfter")
        let session = editor.coordinator.tableEditingSession
        #expect(session.isActive && session.row == 1 && session.column == 0)
        #expect(session.editor.selectedRange() == NSRange(location: 2, length: 0))
    }

    @Test("a selection from one table into the next keeps both, trimmed, with a blank line between")
    func deleteBetweenTables() async throws {
        let text = "| A |\n| --- |\n| a1 |\n\nMiddle\n\n| B |\n| --- |\n| b1 |"
        let editor = try MountedTableEditor(source: text)
        defer { editor.close() }
        let source = text as NSString
        let start = source.range(of: "a1").location
        editor.main.setSelectedRange(NSRange(location: start, length: source.range(of: "B").location + 1 - start))
        editor.main.doCommand(by: #selector(NSResponder.deleteForward(_:)))
        #expect(editor.main.string == "| A |\n| --- |\n|  |\n\n|  |\n| --- |\n| b1 |")
    }
}
