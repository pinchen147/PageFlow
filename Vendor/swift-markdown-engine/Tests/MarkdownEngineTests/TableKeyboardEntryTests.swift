import AppKit
import Testing
@testable import MarkdownEngine

/// The keyboard never shows a rendered table's Markdown (the reference editor): arrows,
/// Find, Undo and programmatic carets land in a cell.
@MainActor
@Suite("Table keyboard entry", .serialized)
struct TableKeyboardEntryTests {
    static let source = "Para above sits over the table\n| Case | Source | Role |\n| --- | --- | --- |\n"
        + "| one | alpha | first |\n| two | beta | second |\n\nPara below"

    private func tableRange(_ editor: MountedTableEditor) throws -> NSRange {
        try #require(editor.coordinator.parsedDocument(for: editor.main.string).tokens.first { $0.kind == .table }).range
    }

    private func hasImage(_ editor: MountedTableEditor) throws -> Bool {
        let storage = try #require(editor.main.textStorage)
        let anchor = try tableRange(editor).location
        return storage.attribute(.renderedBlockImage, at: anchor, effectiveRange: nil) != nil
    }

    private func lineTop(_ editor: MountedTableEditor, of needle: String) throws -> CGFloat {
        let location = (editor.main.string as NSString).range(of: needle).location
        try #require(location != NSNotFound)
        return try #require(editor.main.lineFrame(at: location)).minY
    }

    private func address(_ editor: MountedTableEditor) -> [Int] {
        [editor.coordinator.tableEditingSession.row, editor.coordinator.tableEditingSession.column]
    }

    @Test("↓ from the line above focuses row 0 under the caret and keeps the table rendered")
    func downEntersFirstRowUnderCaret() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        await editor.settle()
        let session = editor.coordinator.tableEditingSession
        let table = try tableRange(editor)
        let parsed = try #require(MarkdownTableSource(source: editor.main.string, range: table))
        let canvas = try #require(editor.main.tableCanvas(forTableAt: table))
        let geometry = try #require(session.geometry(for: parsed))
        // A caret above the middle of the Source column.
        let target = geometry.cellRects[0][1]
        let pointAbove = NSPoint(x: canvas.origin.x + target.midX, y: try #require(editor.main.lineFrame(at: 3)).midY)
        let caret = editor.main.characterIndexForInsertion(at: pointAbove)
        try #require(caret < table.location)
        editor.main.setSelectedRange(NSRange(location: caret, length: 0))
        let below = try lineTop(editor, of: "Para below")
        let undoable = editor.state.undo.canUndo
        editor.main.doCommand(by: #selector(NSResponder.moveDown(_:)))
        #expect(session.isActive)
        #expect(address(editor) == [0, 1])
        #expect(session.editor.selectedRange() == NSRange(location: 0, length: 0))
        #expect(editor.window.firstResponder === session.editor)
        #expect(try hasImage(editor))
        await editor.settle()
        #expect(try lineTop(editor, of: "Para below") == below)
        #expect(editor.state.undo.canUndo == undoable)
        #expect(editor.main.string == Self.source)
    }

    @Test("↑ from the line below focuses the last row")
    func upEntersLastRow() async throws {
        let source = Self.source.replacingOccurrences(of: "\n\nPara below", with: "\nPara below")
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        await editor.settle()
        let session = editor.coordinator.tableEditingSession
        editor.main.setSelectedRange(NSRange(location: (source as NSString).range(of: "Para below").location, length: 0))
        editor.main.doCommand(by: #selector(NSResponder.moveUp(_:)))
        #expect(session.isActive)
        #expect(session.row == 2)
        #expect(session.editor.selectedRange().location == 0)
        #expect(try hasImage(editor))
    }

    @Test("→ at the end of the line above enters (0, 0) at offset 0; ← from below enters the last cell's end")
    func horizontalEntry() async throws {
        let source = Self.source.replacingOccurrences(of: "\n\nPara below", with: "\nPara below")
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        await editor.settle()
        let session = editor.coordinator.tableEditingSession
        editor.main.setSelectedRange(NSRange(location: (source as NSString).range(of: "\n").location, length: 0))
        editor.main.doCommand(by: #selector(NSResponder.moveRight(_:)))
        #expect(session.isActive)
        #expect(address(editor) == [0, 0])
        #expect(session.editor.selectedRange() == NSRange(location: 0, length: 0))
        session.end(selecting: (source as NSString).range(of: "Para below").location)
        editor.main.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        #expect(session.isActive)
        #expect(address(editor) == [2, 2])
        #expect(session.editor.selectedRange() == NSRange(location: 6, length: 0))
    }

    @Test("a programmatic caret in hidden table source edits that cell, and typing reaches it")
    func programmaticCaretBeginsSession() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        await editor.settle()
        let session = editor.coordinator.tableEditingSession
        let beta = (Self.source as NSString).range(of: "beta").location
        editor.main.setSelectedRange(NSRange(location: beta + 2, length: 0))
        #expect(session.isActive)
        #expect(address(editor) == [2, 1])
        #expect(session.editor.selectedRange() == NSRange(location: 2, length: 0))
        #expect(try hasImage(editor))
        session.editor.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.main.string == Self.source.replacingOccurrences(of: "beta", with: "beXta"))
    }

    @Test("Edit Table Source reveals the pipes until the caret leaves the table")
    func editTableSourceReveals() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        await editor.settle()
        let session = editor.coordinator.tableEditingSession
        _ = try editor.focusCell(inTableContaining: "| Case", row: 1, column: 0)
        session.editTableSource(nil)
        await editor.settle()
        #expect(!session.isActive)
        #expect(try !hasImage(editor))
        // Moving within the revealed table keeps it revealed.
        editor.main.setSelectedRange(NSRange(location: (Self.source as NSString).range(of: "alpha").location, length: 0))
        await editor.settle()
        #expect(!session.isActive)
        #expect(try !hasImage(editor))
        editor.main.setSelectedRange(NSRange(location: (Self.source as NSString).range(of: "Para below").location, length: 0))
        await editor.settle()
        #expect(try hasImage(editor))
        // Back in the table, the caret edits a cell again.
        editor.main.setSelectedRange(NSRange(location: (Self.source as NSString).range(of: "alpha").location, length: 0))
        #expect(session.isActive)
        #expect(try hasImage(editor))
    }

    @Test("Find on a cell's text focuses that cell, selects the match and keeps the table rendered")
    func findSelectsInCell() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        await editor.settle()
        let session = editor.coordinator.tableEditingSession
        let match = (Self.source as NSString).range(of: "lph")
        editor.coordinator.handleFindScrollToRange(Notification(
            name: Notification.Name("test.findScroll"), object: editor.coordinator.documentId,
            userInfo: ["range": match, "currentIndex": 0, "allRanges": [match]]
        ))
        #expect(session.isActive)
        #expect(address(editor) == [1, 1])
        #expect(session.editor.selectedRange() == NSRange(location: 1, length: 3))
        #expect(try hasImage(editor))
        #expect(editor.main.string == Self.source)
    }

    @Test("prose input never writes a table's pipes: a caret in its source is refused, a range edits only cell text")
    func proseInputIsGuarded() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        await editor.settle()
        let table = try tableRange(editor)
        editor.main.insertText("Q", replacementRange: NSRange(location: table.location, length: 0))
        #expect(editor.main.string == Self.source)
        editor.main.insertText("Q", replacementRange: NSRange(location: table.location + 3, length: 2))
        #expect(editor.main.string == Self.source.replacingOccurrences(of: "| Case |", with: "| CQe |"))
        // Across the table's edge (the reference editor): the text is trimmed, the covered cell text goes, the table stays.
        editor.main.insertText("Q", replacementRange: NSRange(location: table.location - 4, length: 8))
        #expect(editor.main.string.hasPrefix("Para above sits over the taQ\n\n| e | Source | Role |\n| --- | --- | --- |\n"))
        // Replacing the whole table and more is ordinary editing.
        let now = try tableRange(editor)
        editor.state.undo.beginUndoGrouping()
        editor.main.insertText("Q", replacementRange: NSRange(location: now.location - 1, length: now.length + 1))
        editor.state.undo.endUndoGrouping()
        #expect(editor.main.string.hasPrefix("Para above sits over the taQ\nQ"))
    }

    @Test("Undo of a cell edit after leaving the table puts the caret back in that cell")
    func undoReentersCell() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        await editor.settle()
        let session = editor.coordinator.tableEditingSession
        let cell = try editor.focusCell(inTableContaining: "| Case", row: 2, column: 1)
        cell.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        session.end(selecting: (editor.main.string as NSString).range(of: "Para below").location)
        #expect(!session.isActive)
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
        #expect(session.isActive)
        #expect(address(editor) == [2, 1])
        #expect(try hasImage(editor))
        // The next keystroke reaches the cell, not the hidden source.
        session.editor.setSelectedRange(NSRange(location: 4, length: 0))
        session.editor.insertText("?", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.main.string.contains("| beta? |"))
    }

    @Test("a document selection moved out of the table ends cell editing there")
    func selectionLeavingEndsSession() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        await editor.settle()
        let session = editor.coordinator.tableEditingSession
        _ = try editor.focusCell(inTableContaining: "| Case", row: 1, column: 1)
        let below = (Self.source as NSString).range(of: "Para below").location + 2
        editor.main.setSelectedRange(NSRange(location: below, length: 0))
        #expect(!session.isActive)
        #expect(editor.main.selectedRange() == NSRange(location: below, length: 0))
        #expect(editor.window.firstResponder === editor.main)
    }

    @Test("↓ from the last row of a table that ends the note shows a gap caret; typing adds a paragraph")
    func gapCaretAfterFinalTable() async throws {
        let source = "Intro\n\n| A | B |\n| --- | --- |\n| 1 | 2 |"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        await editor.settle()
        let session = editor.coordinator.tableEditingSession
        let cell = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        cell.doCommand(by: #selector(NSResponder.moveDown(_:)))
        #expect(!session.isActive)
        #expect(editor.coordinator.tableGapCaret != nil)
        #expect(editor.window.firstResponder === editor.main)
        #expect(editor.main.selectedRange() == NSRange(location: (source as NSString).length, length: 0))
        #expect(try hasImage(editor))
        let gap = try #require(editor.coordinator.tableGapCaretRect(in: editor.main))
        let image = try #require(editor.main.tableImageRect(at: try tableRange(editor).location))
        #expect(gap.minY > image.maxY)
        editor.state.undo.beginUndoGrouping()
        editor.main.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.state.undo.endUndoGrouping()
        #expect(editor.main.string == source + "\n\nX")
        #expect(editor.coordinator.tableGapCaret == nil)
        editor.state.undo.undo()
        #expect(editor.main.string == source)
    }

    @Test("↑ at the gap caret returns to the table's last row")
    func gapCaretUpReturns() async throws {
        let source = "Intro\n\n| A | B |\n| --- | --- |\n| 1 | 2 |"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        await editor.settle()
        let session = editor.coordinator.tableEditingSession
        let cell = try editor.focusCell(inTableContaining: "| A", row: 1, column: 1)
        cell.doCommand(by: #selector(NSResponder.moveDown(_:)))
        try #require(editor.coordinator.tableGapCaret != nil)
        editor.main.doCommand(by: #selector(NSResponder.moveUp(_:)))
        #expect(session.isActive)
        #expect(address(editor) == [1, 0])
        #expect(editor.coordinator.tableGapCaret == nil)
        #expect(editor.main.string == source)
    }
}
