import AppKit
import Testing
@testable import MarkdownEngine

/// the reference editor's hover chrome (doc 24 §5.3, §5.7, §7.4): grips, handle and add
/// bars from a pure layout; hover draws and never edits or lays out.
@MainActor
@Suite("Table hover chrome", .serialized)
struct TableChromeTests {
    static let source = "Intro\n\n| A | B | C |\n| --- | --- | --- |\n| a1 | b1 | c1 |\n| a2 | b2 | c2 |\n\nAfter"

    private func grid(_ rows: Int, _ columns: Int, origin: NSPoint = NSPoint(x: 100, y: 200)) -> TableChromeLayout {
        TableChromeLayout(cells: (0..<rows).map { row in
            (0..<columns).map { column in NSRect(x: origin.x + CGFloat(column) * 60, y: origin.y + CGFloat(row) * 30, width: 60, height: 30) }
        })
    }

    private func mount(_ source: String = Self.source) async throws -> (MountedTableEditor, TableChromeController) {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        let editor = try MountedTableEditor(source: source, configuration: configuration)
        await editor.settle()
        editor.coordinator.tableActions?.requiresKeyWindow = false
        return (editor, try #require(editor.coordinator.tableChrome))
    }

    /// The centre of a rendered cell, in the text view's coordinates.
    private func cellCenter(_ editor: MountedTableEditor, row: Int, column: Int) throws -> NSPoint {
        let anchor = (editor.main.string as NSString).range(of: "| A").location
        let image = try #require(editor.main.tableImageRect(at: anchor))
        let table = try #require(MarkdownTableSource(source: editor.main.string, range: NSRange(location: anchor, length: (editor.main.string as NSString).range(of: "c2 |").upperBound - anchor)))
        let layout = try #require(editor.coordinator.tableEditingSession.geometry(for: table))
        let cell = layout.cellRects[row][column]
        return NSPoint(x: image.minX + cell.midX, y: image.minY + cell.midY)
    }

    // MARK: - Layout

    @Test("grips, handle and add bars sit where the reference editor puts them")
    func geometry() {
        let layout = grid(3, 3)
        #expect(layout.columnGrip(1) == NSRect(x: 100 + 90 - 12, y: 200 - 7, width: 24, height: 14))
        #expect(layout.rowGrip(2) == NSRect(x: 100 - 7, y: 200 + 75 - 12, width: 14, height: 24))
        #expect(layout.handle == NSRect(x: 100 - 44, y: 200, width: 26, height: 26))
        #expect(layout.addRowBar == NSRect(x: 100, y: 290, width: 180, height: 18))
        #expect(layout.addColumnBar == NSRect(x: 280, y: 200, width: 18, height: 90))
        #expect(layout.cell(at: NSPoint(x: 161, y: 231)) == CellCoord(row: 1, column: 1))
        #expect(layout.cell(at: NSPoint(x: 99, y: 231)) == nil)
        #expect(layout.wrapper.contains(NSPoint(x: 60, y: 210)), "the left gutter keeps the chrome")
        #expect(layout.wrapper.contains(NSPoint(x: 330, y: 210)), "so does the bridge to the \u{2026} button")
    }

    @Test("a row never drops above the header; a column may drop at boundary 0")
    func boundaries() {
        let layout = grid(3, 3)
        #expect(layout.nearestBoundary(to: 190, rows: true) == 1)
        #expect(layout.nearestBoundary(to: 288, rows: true) == 3)
        #expect(layout.nearestBoundary(to: 95, rows: false) == 0)
        #expect(layout.nearestBoundary(to: 215, rows: false) == 2)
    }

    @Test("the add-column bar is absent while the table's right edge is clipped")
    func clippedRightEdge() {
        let clipped = TableChromeLayout(cells: grid(2, 5).cells, clip: NSRect(x: 100, y: 0, width: 200, height: 1000))
        #expect(clipped.addColumnBar == nil)
        #expect(clipped.visibleRight == 300)
        #expect(clipped.addRowBar.width == 200)
    }

    // MARK: - Hover

    @Test("hovering a cell shows its table's chrome; 50 moves edit nothing and lay nothing out")
    func hoverIsDrawOnly() async throws {
        let (editor, chrome) = try await mount()
        defer { editor.close() }
        // Hover chrome is intentionally suppressed during a physical drag,
        // including one in another app while this fixture runs behind it.
        for _ in 0..<100 where NSEvent.pressedMouseButtons & 1 != 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(NSEvent.pressedMouseButtons & 1 == 0, "hover qualification requires the mouse button to be up")
        let storage = try #require(editor.main.textStorage)
        var edits = 0
        let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage,
                                                              queue: nil) { _ in edits += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let tlm = try #require(editor.main.textLayoutManager)
        var before: [ObjectIdentifier] = []
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) { before.append(ObjectIdentifier($0)); return true }
        let starts = try [cellCenter(editor, row: 1, column: 0), cellCenter(editor, row: 2, column: 0)]
        let ends = try [cellCenter(editor, row: 1, column: 2), cellCenter(editor, row: 2, column: 2)]
        for step in 0..<50 {
            let row = step / 25
            let fraction = CGFloat(step % 25) / 24
            chrome.hover(at: NSPoint(x: starts[row].x + (ends[row].x - starts[row].x) * fraction,
                                     y: starts[row].y))
        }
        var after: [ObjectIdentifier] = []
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) { after.append(ObjectIdentifier($0)); return true }
        #expect(edits == 0)
        #expect(before == after, "no fragment was laid out again")
        #expect(!chrome.view.isHidden)
        #expect(chrome.view.hovered?.row == 2)
        #expect(chrome.view.showsAddRow, "a last-row cell shows the add-row bar")
        #expect(editor.coordinator.tableActions?.hoveredTable == chrome.table)
        chrome.hover(at: NSPoint(x: starts[0].x, y: 4))
        #expect(chrome.view.isHidden, "a point outside the wrapper removes it")
        #expect(editor.coordinator.tableActions?.hoveredTable == nil)
    }

    // MARK: - Grips and bars

    @Test("a grip click selects the whole column and opens its 188 pt menu; Insert acts on the hovered cell")
    func gripClick() async throws {
        let (editor, chrome) = try await mount()
        defer { editor.close() }
        chrome.hover(at: try cellCenter(editor, row: 1, column: 1))
        chrome.clickGrip(.columnGrip, index: 1)
        let session = editor.coordinator.tableEditingSession
        #expect(session.cellSelection == TableCellSelection(anchor: CellCoord(row: 0, column: 1), head: CellCoord(row: 2, column: 1)))
        let menu = try #require(chrome.gripMenu)
        #expect(menu.titles == ["Insert column left", "Insert column right", "Delete column"])
        #expect(menu.accessibilityLabel() == "Column actions")
        #expect(menu.frame.width >= 188)
        menu.activate(title: "Insert column right")
        #expect(editor.main.string.contains("| A | B |  | C |") || editor.main.string.contains("| A | B |   | C |"))
        #expect(session.table?.columnCount == 4)
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
    }

    @Test("a column drop moves it with its alignment cell as one Undo step; a drop on its own boundary does nothing")
    func columnDrop() async throws {
        let (editor, chrome) = try await mount()
        defer { editor.close() }
        chrome.hover(at: try cellCenter(editor, row: 1, column: 0))
        chrome.drop(rows: false, index: 0, boundary: 1)
        #expect(editor.main.string == Self.source)
        #expect(!editor.state.undo.canUndo)
        chrome.hover(at: try cellCenter(editor, row: 1, column: 0))
        chrome.drop(rows: false, index: 0, boundary: 3)
        #expect(editor.main.string.contains("| B | C | A |\n| --- | --- | --- |\n| b1 | c1 | a1 |"))
        #expect(editor.state.undo.undoActionName == "Move Column")
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
    }

    @Test("dragging the header row's grip is refused; a body row drag drops at the pointer's boundary")
    func gripDrag() async throws {
        let (editor, chrome) = try await mount()
        defer { editor.close() }
        let header = try cellCenter(editor, row: 0, column: 0)
        chrome.hover(at: header)
        func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: editor.main.convert(point, to: nil), modifierFlags: [],
                                            timestamp: 0, windowNumber: editor.window.windowNumber, context: nil,
                                            eventNumber: 5, clickCount: 1, pressure: 1))
        }
        func script(_ events: [NSEvent]) -> () -> NSEvent? {
            var queue = events
            return { queue.isEmpty ? nil : queue.removeFirst() }
        }
        let below = try cellCenter(editor, row: 2, column: 0)
        let headerDrop = NSPoint(x: header.x, y: below.y + 20)
        chrome.pressGrip(.rowGrip, event: try event(.leftMouseDown, at: header),
                         nextEvent: script([try event(.leftMouseDragged, at: headerDrop), try event(.leftMouseUp, at: headerDrop)]))
        #expect(editor.main.string == Self.source, "Header rows stay at the top.")
        let first = try cellCenter(editor, row: 1, column: 0)
        chrome.hover(at: first)
        let drop = NSPoint(x: first.x, y: below.y + 14)
        chrome.pressGrip(.rowGrip, event: try event(.leftMouseDown, at: first),
                         nextEvent: script([try event(.leftMouseDragged, at: drop), try event(.leftMouseUp, at: drop)]))
        #expect(editor.main.string.contains("| a2 | b2 | c2 |\n| a1 | b1 | c1 |"))
    }

    @Test("the add-row bar appends a row with the caret at the start of the cell under the pointer")
    func addRow() async throws {
        let (editor, chrome) = try await mount()
        defer { editor.close() }
        let last = try cellCenter(editor, row: 2, column: 1)
        chrome.hover(at: last)
        chrome.clickAddBar(.addRow, at: NSPoint(x: last.x, y: last.y + 30))
        let session = editor.coordinator.tableEditingSession
        #expect(session.table?.rowCount == 4)
        #expect(session.row == 3 && session.column == 1)
        #expect(session.editor.selectedRange() == NSRange(location: 0, length: 0))
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
    }

    @Test("the handle selects every cell")
    func handle() async throws {
        let (editor, chrome) = try await mount()
        defer { editor.close() }
        chrome.hover(at: try cellCenter(editor, row: 1, column: 2))
        chrome.clickHandle()
        #expect(editor.coordinator.tableEditingSession.cellSelection
            == TableCellSelection(anchor: CellCoord(row: 0, column: 0), head: CellCoord(row: 2, column: 2)))
    }

    // MARK: - Column resize

    @Test("the resize band runs −4…+5 pt around each column's right border, never the first column's left edge")
    func resizeZones() {
        let layout = grid(3, 3)
        #expect(layout.resizeColumn(at: NSPoint(x: 160 - 1, y: 220)) == 0, "on the border after column 0")
        #expect(layout.resizeColumn(at: NSPoint(x: 160 + 3, y: 220)) == 0)
        #expect(layout.resizeColumn(at: NSPoint(x: 280 - 2, y: 220)) == 2, "the last column's right edge resizes")
        #expect(layout.resizeColumn(at: NSPoint(x: 101, y: 220)) == nil)
        #expect(layout.resizeColumn(at: NSPoint(x: 190, y: 220)) == nil)
        #expect(layout.resizeColumn(at: NSPoint(x: 160, y: 150)) == nil, "outside the table's height")
    }

    @Test("a resize drag widens the column view-only as one Undo step and clamps at 48")
    func resizeDrag() async throws {
        let (editor, chrome) = try await mount()
        defer { editor.close() }
        let point = try cellCenter(editor, row: 1, column: 0)
        chrome.hover(at: point)
        let layout = try #require(chrome.view.layout)
        let border = NSPoint(x: layout.columnBoundaries[1] - 1, y: point.y)
        let before = layout.cells[0][0].width + 1
        func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: editor.main.convert(NSPoint(x: x, y: border.y), to: nil), modifierFlags: [],
                                            timestamp: 0, windowNumber: editor.window.windowNumber, context: nil, eventNumber: 9,
                                            clickCount: 1, pressure: 1))
        }
        func script(_ events: [NSEvent]) -> () -> NSEvent? {
            var queue = events
            return { queue.isEmpty ? nil : queue.removeFirst() }
        }
        chrome.pressResize(column: 0, event: try event(.leftMouseDown, x: border.x),
                           nextEvent: script([try event(.leftMouseDragged, x: border.x + 50), try event(.leftMouseUp, x: border.x + 50)]))
        let stored = try #require(editor.state.controller.tableColumnWidths.values.first)
        #expect(stored.first.flatMap { $0 }.map { abs($0 - (before + 50)) < 0.5 } == true)
        #expect(editor.main.string == Self.source, "the file never changes")
        #expect(editor.state.undo.undoActionName == "Column Width")
        editor.state.undo.undo()
        #expect(editor.state.controller.tableColumnWidths.isEmpty)
        editor.state.undo.redo()
        await editor.settle()
        // From the wider width, far to the left: it stops at 48.
        chrome.hover(at: point)
        let wider = try #require(chrome.view.layout).columnBoundaries[1] - 1
        chrome.pressResize(column: 0, event: try event(.leftMouseDown, x: wider),
                           nextEvent: script([try event(.leftMouseDragged, x: wider - 500), try event(.leftMouseUp, x: wider - 500)]))
        #expect(editor.state.controller.tableColumnWidths.values.first?.first == 48)
    }
}
