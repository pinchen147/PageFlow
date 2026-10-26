import AppKit
import Testing
@testable import MarkdownEngine

/// the reference editor's table menus (doc 24 §5.4): Cell actions on right-click or
/// ⇧F10, its Move replacement menu, and the "…" menu.
@MainActor
@Suite("Table menus", .serialized)
struct TableMenusTests {
    static let source = "Intro\n\n| A | B | C |\n| --- | --- | --- |\n| a1 | b1 | c1 |\n| 10 | b2 | c2 |\n| 2 | b3 | c3 |\n\nAfter"

    private func items(_ session: MarkdownTableEditingSession) -> [TableMenuView.Item] {
        session.cellActionItems(fromKeyboard: false)
    }

    private func run(_ title: String, _ items: [TableMenuView.Item]) throws {
        let item = try #require(items.first { $0.title == title })
        try #require(item.isEnabled)
        item.action?()
    }

    private func openMenus(_ editor: MountedTableEditor) -> [TableMenuView] {
        editor.scroll.subviews.compactMap { $0 as? TableMenuView }
    }

    private func rightClick(_ editor: MountedTableEditor, at windowPoint: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: windowPoint, modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: editor.window.windowNumber,
                                        context: nil, eventNumber: 91, clickCount: 1, pressure: 1))
    }

    @Test("Cell actions lists the reference editor's rows in order; Sort needs two body rows")
    func rows() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        let titles = TableMenuView.present(items(session), family: .float, label: "Cell actions", placement: .at(.zero), in: editor.scroll,
                                           fromKeyboard: false, returningFocusTo: session.editor) { _ in }
        #expect(titles.titles == ["Insert row above", "Insert row below", "Insert column left", "Insert column right", "Move row or column",
                                  "Set column width", "—",
                                  "Delete row", "Delete column", "Delete table", "—", "Sort column ascending", "Sort column descending", "—",
                                  "Align left", "Align center", "Align right"])
        // 4 + 14 rows × 32 + 3 separators × 9 + 4, as doc 24 §5.4.4 computes.
        let expectedHeight: CGFloat = 483
        #expect(titles.frame.height == expectedHeight)
        titles.close(.dismissed)
        let small = try MountedTableEditor(source: "| A |\n| --- |\n| x |")
        defer { small.close() }
        _ = try small.focusCell(inTableContaining: "| A", row: 1, column: 0)
        #expect(!items(small.coordinator.tableEditingSession).contains { $0.title.hasPrefix("Sort") })
    }

    @Test("a right-click on a cell's blank space opens Cell actions; on a glyph the native text menu")
    func rightClickRouting() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        let grid = try #require(session.grid)
        let cell = grid.geometry.cellRects[1][1]
        let blank = grid.convert(NSPoint(x: cell.maxX - 3, y: cell.midY), to: nil)
        let menu = session.contextMenu(for: try rightClick(editor, at: blank)) { NSMenu(title: "native") }
        #expect(menu == nil)
        #expect(session.row == 1 && session.column == 1, "the caret moved into the clicked cell")
        let open = try #require(openMenus(editor).first)
        #expect(open.accessibilityLabel() == "Cell actions")
        #expect(open.focused == nil, "from the mouse, the menu itself has focus")
        open.close(.dismissed)
        let glyph = session.editor.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        let onGlyph = editor.window.convertFromScreen(glyph)
        let native = session.contextMenu(for: try rightClick(editor, at: NSPoint(x: onGlyph.midX, y: onGlyph.midY))) { NSMenu(title: "native") }
        #expect(native?.title == "native")
        #expect(openMenus(editor).isEmpty)
    }

    @Test("⇧F10 opens Cell actions at the caret with its first row focused; Escape returns to the cell")
    func keyboardOpen() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        let cell = try editor.focusCell(inTableContaining: "| A", row: 2, column: 1)
        let f10 = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
                                                windowNumber: editor.window.windowNumber, context: nil, characters: "\u{F70D}",
                                                charactersIgnoringModifiers: "\u{F70D}", isARepeat: false, keyCode: 109))
        cell.keyDown(with: f10)
        let menu = try #require(openMenus(editor).first)
        #expect(menu.focused == 0, "the first row: Insert row above is enabled on a body row")
        #expect(editor.window.firstResponder === menu)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: editor.window.windowNumber, context: nil, characters: "\u{1b}",
                                                   charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        menu.keyDown(with: escape)
        #expect(openMenus(editor).isEmpty)
        #expect(editor.window.firstResponder === session.editor)
        #expect(session.isActive && session.row == 2 && session.column == 1)
    }

    @Test("Move row or column: the header rule and edges disable rows; a move is one Undo step and keeps the caret")
    func moveMenu() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        session.editor.setSelectedRange(NSRange(location: 1, length: 0))
        session.showMoveMenu(fromKeyboard: true)
        let menu = try #require(openMenus(editor).first)
        #expect(menu.disabledReason(of: "Move row up") == "Header rows stay at the top.")
        #expect(menu.disabledReason(of: "Move column left") == "This column is already at the far left.")
        #expect(menu.disabledReason(of: "Move row down") == nil)
        menu.activate(title: "Move row down")
        #expect(editor.main.string.contains("| 10 | b2 | c2 |\n| a1 | b1 | c1 |"))
        #expect(session.row == 2 && session.column == 0)
        #expect(session.editor.selectedRange() == NSRange(location: 1, length: 0))
        #expect(editor.state.undo.undoActionName == "Move Row")
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
    }

    @Test("Sort is number-aware and keeps the header; Delete row on the header promotes the next row")
    func sortAndHeaderDelete() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        try run("Sort column ascending", items(session))
        #expect(editor.main.string.contains("| --- | --- | --- |\n| 2 | b3 | c3 |\n| 10 | b2 | c2 |\n| a1 | b1 | c1 |"))
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
        session.select(row: 0, column: 0)
        try run("Delete row", items(session))
        #expect(editor.main.string.contains("Intro\n\n| a1 | b1 | c1 |\n| --- | --- | --- |\n| 10 | b2 | c2 |"))
    }

    @Test("Align on a range aligns every column it covers in one Undo step")
    func alignRange() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        session.setCellSelection(TableCellSelection(anchor: CellCoord(row: 1, column: 1), head: CellCoord(row: 2, column: 2)))
        try run("Align right", items(session))
        #expect(editor.main.string.contains("| --- | ---: | ---: |"))
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
    }

    @Test("the \u{2026} button shows for the caret's table; its menu offers Comment, Edit table source and Delete table")
    func tableActions() async throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        let editor = try MountedTableEditor(source: Self.source, configuration: configuration)
        defer { editor.close() }
        let actions = try #require(editor.coordinator.tableActions)
        actions.requiresKeyWindow = false
        actions.update()
        #expect(actions.button.isHidden)
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        #expect(!actions.button.isHidden)
        let grid = try #require(editor.coordinator.tableEditingSession.grid)
        let table = grid.convert(grid.bounds, to: editor.scroll)
        #expect(abs(actions.button.frame.minX - (ceil(table.maxX) + 22)) < 1, "22 pt right of the table's visible edge")
        actions.toggleMenu(fromKeyboard: true, lastRow: false)
        let menu = try #require(actions.menu)
        #expect(menu.titles == ["Comment", "—", "Edit table source", "—", "Delete table"])
        let expectedHeight: CGFloat = 122   // 4 + 32 × 3 + 9 × 2 + 4
        #expect(menu.frame.height == expectedHeight)
        #expect(menu.frame.width >= 160 && menu.frame.width <= 170, "min 160, the labels' natural width")
        menu.activate(title: "Delete table")
        #expect(editor.main.string == "Intro\n\nAfter")
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
    }
}
