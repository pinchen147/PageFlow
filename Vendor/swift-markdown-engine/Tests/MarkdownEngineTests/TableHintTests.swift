import AppKit
import Testing
@testable import MarkdownEngine

/// the reference editor's one-time table hint (doc 24 §5.3.7).
@MainActor
@Suite("Table hint", .serialized)
struct TableHintTests {
    static let source = "Intro\n\n| A | B |\n| --- | --- |\n| a1 | b1 |\n\nAfter"

    private func mount() async throws -> MountedTableEditor {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        let editor = try MountedTableEditor(source: Self.source, configuration: configuration)
        await editor.settle()
        return editor
    }

    @Test("the first entry into a cell shows the hint above the table; a quick dismissal re-arms it, expiry latches it")
    func lifecycle() async throws {
        TableHintView.latched = false
        defer { TableHintView.latched = true }
        let editor = try await mount()
        defer { editor.close() }
        let hint = try #require(editor.coordinator.tableHint)
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        #expect(hint.isShowing)
        #expect(hint.superview === editor.scroll)
        let grid = try #require(editor.coordinator.tableEditingSession.grid)
        let table = grid.convert(grid.bounds, to: editor.scroll)
        if !editor.scroll.isFlipped { #expect(abs(hint.frame.minY - (table.maxY + 6)) < 1, "6 above the table's top") }
        hint.dismiss()
        #expect(!hint.isShowing)
        #expect(!TableHintView.latched, "dismissed within a second: it may show again")
        editor.coordinator.tableEditingSession.retire()
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 1)
        #expect(hint.isShowing)
        hint.expireNow()
        #expect(TableHintView.latched)
    }

    @Test("Cell actions latches the hint off for the session")
    func cellActionsLatch() async throws {
        TableHintView.latched = false
        defer { TableHintView.latched = true }
        let editor = try await mount()
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        session.showCellActions(at: nil, fromKeyboard: true)
        #expect(TableHintView.latched)
        #expect(!(editor.coordinator.tableHint?.isShowing ?? true))
        session.openMenu?.close(.dismissed)
    }
}
