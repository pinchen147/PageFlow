import AppKit
import Testing
@testable import MarkdownEngine

/// the reference editor's column widths, view-only in PageFlow (doc 24 §5.4.6, §7.3.6):
/// they never change the file, each change is one Undo step, and they follow
/// the table through its own edits.
@MainActor
@Suite("Table column widths", .serialized)
struct TableWidthTests {
    static let source = "Intro\n\n| A | B | C |\n| --- | --- | --- |\n| a1 | b1 | c1 |\n| a2 | b2 | c2 |\n\nAfter"

    private func widths(_ editor: MountedTableEditor) -> [CGFloat?] {
        editor.state.controller.tableColumnWidths.values.first ?? []
    }

    @Test("table keys are stable and count tables with the same header")
    func keys() {
        let text = "| A |\n| - |\n| 1 |\n\n| A |\n| - |\n| 2 |\n\n| B |\n| - |\n| 3 |" as NSString
        let ranges = [NSRange(location: 0, length: 17), NSRange(location: 19, length: 17), NSRange(location: 38, length: 17)]
        let keys = NativeTextViewCoordinator.tableKeys(for: ranges, in: text)
        #expect(keys[0]?.hasSuffix("-0") == true)
        #expect(keys[19]?.hasSuffix("-1") == true)
        #expect(keys[38]?.hasSuffix("-0") == true)
        #expect(keys[0]?.split(separator: "-").first == keys[19]?.split(separator: "-").first)
        #expect(NativeTextViewCoordinator.tableKeys(for: ranges, in: text) == keys, "deterministic")
    }

    @Test("Medium sets the column's box to 224 without touching the file; Undo and Redo; Auto clears")
    func setWidth() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 1)
        session.setColumnWidth(224, columns: 1...1, announce: nil)
        #expect(widths(editor) == [nil, 224, nil])
        #expect(editor.main.string == Self.source, "widths never reach the file")
        let header = try #require(session.grid?.geometry.cellRects[0])
        #expect(header[2].minX - header[1].minX == 224, "the column's box, border included, is 224")
        #expect(editor.state.undo.undoActionName == "Column Width")
        let steps = editor.state.undo.canUndo
        session.setColumnWidth(224, columns: 1...1, announce: nil)
        #expect(editor.state.undo.canUndo == steps, "the same width again adds nothing")
        editor.state.undo.undo()
        #expect(editor.state.controller.tableColumnWidths.isEmpty)
        editor.state.undo.redo()
        #expect(widths(editor) == [nil, 224, nil])
        session.setColumnWidth(nil, columns: 0...2, announce: nil)
        #expect(editor.state.controller.tableColumnWidths.isEmpty)
        session.setColumnWidth(10, columns: 0...0, announce: nil)
        #expect(widths(editor) == [48, nil, nil], "clamped at 48")
    }

    @Test("the widths follow a header edit, an inserted column and a column move")
    func followEdits() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        let cell = try editor.focusCell(inTableContaining: "| A", row: 1, column: 1)
        session.setColumnWidth(224, columns: 1...1, announce: nil)
        session.select(row: 0, column: 0)
        editor.state.undo.beginUndoGrouping()
        cell.insertText("Z", replacementRange: NSRange(location: cell.string.utf16.count, length: 0))
        _ = session.commitInput()
        editor.state.undo.endUndoGrouping()
        #expect(editor.main.string.contains("| AZ | B | C |"))
        #expect(widths(editor) == [nil, 224, nil], "a header edit keeps the widths")
        #expect(editor.state.controller.tableColumnWidths.count == 1)
        session.select(row: 1, column: 0)
        session.perform(.insertColumn(right: true))
        #expect(widths(editor) == [nil, nil, 224, nil])
        session.select(row: 1, column: 2)
        session.moveColumn(by: 1, announce: false)
        #expect(widths(editor) == [nil, nil, nil, 224])
        session.moveRow(by: 1, announce: false)
        #expect(widths(editor) == [nil, nil, nil, 224], "a row move keeps them")
    }

    @Test("the Column width menu checks the current width and focuses it from the keyboard")
    func menu() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 1)
        #expect(session.cellActionItems(fromKeyboard: false).map(\.title).prefix(6).last == "Set column width")
        session.setColumnWidth(336, columns: 1...1, announce: nil)
        // 336 makes the table wide: its overlay and the cell editor remount on the next turn.
        await editor.settle()
        try #require(session.grid != nil)
        session.showWidthMenu(fromKeyboard: true)
        let menu = try #require(editor.scroll.subviews.compactMap { $0 as? TableMenuView }.first)
        #expect(menu.titles == ["Narrow", "Medium", "Wide", "Extra wide", "Auto"])
        #expect(menu.focused == 2, "Wide is checked and focused")
        menu.activate(title: "Auto")
        #expect(editor.state.controller.tableColumnWidths.isEmpty)
    }
}
