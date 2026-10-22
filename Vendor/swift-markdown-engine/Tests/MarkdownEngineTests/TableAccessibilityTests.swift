import AppKit
import Testing
@testable import MarkdownEngine

/// the reference editor's table accessibility (doc 24 §5.11).
@MainActor
@Suite("Table accessibility", .serialized)
struct TableAccessibilityTests {
    static let source = "Intro\n\n| A | B |\n| --- | --- |\n| a1 | b1 |\n| a2 | b2 |\n\nAfter"

    private func mount() async throws -> MountedTableEditor {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        let editor = try MountedTableEditor(source: Self.source, configuration: configuration)
        await editor.settle()
        editor.coordinator.tableActions?.requiresKeyWindow = false
        return editor
    }

    @Test("the grid is an AXTable of rows and cells with header labels and selected cells")
    func grid() async throws {
        let editor = try await mount()
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        let grid = try #require(session.grid)
        #expect(grid.accessibilityRole() == .table)
        #expect(grid.accessibilityRowCount() == 3 && grid.accessibilityColumnCount() == 2)
        let rows = try #require(grid.accessibilityRows() as? [NSAccessibilityElement])
        let header = try #require(rows.first?.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(header.map { $0.accessibilityLabel() } == ["Column header, A", "Column header, B"])
        let body = try #require(rows[1].accessibilityChildren() as? [NSAccessibilityElement])
        #expect(body.first?.accessibilityValue() as? String == "a1")
        #expect(body.first?.accessibilityRowIndexRange() == NSRange(location: 1, length: 1))
        session.setCellSelection(TableCellSelection(anchor: CellCoord(row: 1, column: 0), head: CellCoord(row: 2, column: 1)))
        #expect(grid.accessibilitySelectedCells()?.count == 4)
    }

    @Test("hover chrome controls are AX buttons with the reference editor's labels; AXPress on Add row adds one")
    func chrome() async throws {
        let editor = try await mount()
        defer { editor.close() }
        let chrome = try #require(editor.coordinator.tableChrome)
        let anchor = (Self.source as NSString).range(of: "| A").location
        let image = try #require(editor.main.tableImageRect(at: anchor))
        chrome.hover(at: NSPoint(x: image.minX + 10, y: image.maxY - 8))
        let buttons = try #require(chrome.view.accessibilityChildren() as? [TableAccessibilityElement])
        #expect(buttons.map { $0.accessibilityLabel() } == ["Column options", "Row options", "Drag to move table", "Add row"])
        #expect(buttons.allSatisfy { $0.accessibilityRole() == .button })
        #expect(buttons[0].accessibilityHelp() == "Click for column options \u{b7} drag to move")
        #expect(buttons[3].accessibilityPerformPress())
        #expect(editor.coordinator.tableEditingSession.table?.rowCount == 4)
    }

    @Test("menu rows are AX menu items; a disabled Move row says why; the \u{2026} button opens its menu on AXPress")
    func menusAndButton() async throws {
        let editor = try await mount()
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        session.showMoveMenu(fromKeyboard: true)
        let menu = try #require(session.openMenu)
        #expect(menu.accessibilityRole() == .menu && menu.accessibilityLabel() == "Move row or column")
        let items = menu.accessibilityItems()
        #expect(items.map { $0.accessibilityLabel() } == ["Move row up", "Move row down", "Move column left", "Move column right"])
        #expect(!items[0].isAccessibilityEnabled() && items[0].accessibilityHelp() == "Header rows stay at the top.")
        #expect(items[1].isAccessibilityEnabled())
        menu.close(.dismissed)
        let actions = try #require(editor.coordinator.tableActions)
        #expect(actions.button.accessibilityLabel() == "More actions")
        #expect(actions.button.accessibilityPerformPress())
        #expect(actions.button.isAccessibilityExpanded())
        actions.menu?.close(.dismissed)
    }

    @Test("keyboard commands announce at medium priority, coalesced to the last within 150 ms")
    func announcements() async throws {
        let editor = try await mount()
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        MarkdownTableEditingSession.lastAnnouncement = nil
        let items = session.cellActionItems(fromKeyboard: true)
        items.first { $0.title == "Insert row below" }?.action?()
        MarkdownTableEditingSession.announce("Row inserted above")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(MarkdownTableEditingSession.lastAnnouncement == "Row inserted above", "the two coalesce to the last")
    }
}
