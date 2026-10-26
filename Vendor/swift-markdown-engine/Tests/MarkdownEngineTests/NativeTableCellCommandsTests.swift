import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Native table cell commands", .serialized)
struct NativeTableCellCommandsTests {
    static let source = "Intro\n\n| A | B |\n| --- | --- |\n| hello world | 2 |\n\nAfter"

    private func command(_ cell: NSTextView, _ selector: Selector) { cell.doCommand(by: selector) }
    private func address(_ session: MarkdownTableEditingSession) -> [Int] { [session.row, session.column] }

    @Test("Tab walks across then down, and Tab past the last cell adds one row")
    func tabOrder() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        let cell = try editor.focusCell(inTableContaining: "| A", row: 0, column: 1)
        command(cell, #selector(NSResponder.insertTab(_:)))
        #expect(address(session) == [1, 0])
        #expect(cell.string == "hello world")
        #expect(cell.selectedRange() == NSRange(location: 0, length: 11))
        command(cell, #selector(NSResponder.insertBacktab(_:)))
        #expect(address(session) == [0, 1])
        command(cell, #selector(NSResponder.insertTab(_:)))
        command(cell, #selector(NSResponder.insertTab(_:)))
        command(cell, #selector(NSResponder.insertTab(_:)))
        let appended = "Intro\n\n| A | B |\n| --- | --- |\n| hello world | 2 |\n|   |   |\n\nAfter"
        #expect(editor.main.string == appended)
        #expect(address(session) == [2, 0])
        editor.replaceCell(cell, with: "x")
        #expect(editor.main.string == "Intro\n\n| A | B |\n| --- | --- |\n| hello world | 2 |\n| x  |   |\n\nAfter")
        #expect(editor.state.undo.undoActionName == "Edit Table Cell")
        editor.state.undo.undo()
        #expect(editor.main.string == appended)
        #expect(editor.state.undo.undoActionName == "Insert Row")
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
        #expect(session.isActive, "Undo keeps editing the nearest surviving cell")
        #expect(address(session) == [1, 0])
    }

    @Test("Return adds a line in the cell; Escape keeps the cell and its caret")
    func returnAndEscape() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        let cell = try editor.focusCell(inTableContaining: "| A", row: 0, column: 1)
        command(cell, #selector(NSResponder.insertNewline(_:)))
        #expect(address(session) == [0, 1])
        #expect(editor.main.string == Self.source.replacingOccurrences(of: "| A | B |", with: "| A | B<br> |"))
        let caret = cell.selectedRange()
        command(cell, #selector(NSResponder.cancelOperation(_:)))
        #expect(session.isActive)
        #expect(editor.window.firstResponder === cell)
        #expect(cell.selectedRange() == caret)
        #expect(address(session) == [0, 1])
    }

    @Test("←/→ cross cells in document order and leave after the last cell; ↑/↓ land at offset 0")
    func arrows() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        let cell = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        #expect(cell.selectedRange() == NSRange(location: 11, length: 0))
        command(cell, #selector(NSResponder.moveRight(_:)))
        #expect(address(session) == [1, 1])
        #expect(cell.selectedRange() == NSRange(location: 0, length: 0))
        command(cell, #selector(NSResponder.moveLeft(_:)))
        #expect(address(session) == [1, 0])
        #expect(cell.selectedRange() == NSRange(location: 11, length: 0))
        command(cell, #selector(NSResponder.moveUp(_:)))
        #expect(address(session) == [0, 0])
        #expect(cell.selectedRange() == NSRange(location: 0, length: 0))
        command(cell, #selector(NSResponder.moveDown(_:)))
        #expect(address(session) == [1, 0])
        #expect(cell.selectedRange() == NSRange(location: 0, length: 0))
        // ← at the start of a row wraps to the end of the row above.
        command(cell, #selector(NSResponder.moveLeft(_:)))
        #expect(address(session) == [0, 1])
        #expect(cell.selectedRange() == NSRange(location: 1, length: 0))
        command(cell, #selector(NSResponder.moveRight(_:)))
        #expect(address(session) == [1, 0])
        command(cell, #selector(NSResponder.moveUp(_:)))
        command(cell, #selector(NSResponder.moveUp(_:)))
        #expect(!session.isActive)
        #expect(editor.main.selectedRange() == NSRange(location: 6, length: 0))
        #expect(editor.main.string == Self.source)
    }

    @Test("→ after the last cell leaves the table; ← at the first cell's start leaves above it")
    func arrowsLeaveAtTheEnds() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        var cell = try editor.focusCell(inTableContaining: "| A", row: 1, column: 1)
        command(cell, #selector(NSResponder.moveRight(_:)))
        #expect(!session.isActive)
        #expect(editor.main.selectedRange() == NSRange(location: (Self.source as NSString).range(of: "\n\nAfter").location + 1, length: 0))
        cell = try editor.focusCell(inTableContaining: "| A", row: 0, column: 0)
        cell.setSelectedRange(NSRange(location: 0, length: 0))
        command(cell, #selector(NSResponder.moveLeft(_:)))
        #expect(!session.isActive)
        #expect(editor.main.selectedRange() == NSRange(location: 6, length: 0))
        #expect(editor.main.string == Self.source)
    }

    @Test("Tab selects the whole next-cell text; → on it goes to the next cell's start; Shift-Tab at (0,0) does nothing")
    func tabSelectsCellText() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        let cell = try editor.focusCell(inTableContaining: "| A", row: 0, column: 0)
        command(cell, #selector(NSResponder.insertBacktab(_:)))
        #expect(address(session) == [0, 0])
        command(cell, #selector(NSResponder.insertTab(_:)))
        command(cell, #selector(NSResponder.insertTab(_:)))
        #expect(address(session) == [1, 0])
        #expect(cell.selectedRange() == NSRange(location: 0, length: 11))
        command(cell, #selector(NSResponder.moveRight(_:)))
        #expect(address(session) == [1, 1])
        #expect(cell.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test("Tab in the last cell appends a row with the caret at offset 0 of its first cell")
    func tabPastTheEnd() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        let cell = try editor.focusCell(inTableContaining: "| A", row: 1, column: 1)
        command(cell, #selector(NSResponder.insertTab(_:)))
        #expect(address(session) == [2, 0])
        #expect(cell.selectedRange() == NSRange(location: 0, length: 0))
        #expect(editor.main.string == "Intro\n\n| A | B |\n| --- | --- |\n| hello world | 2 |\n|   |   |\n\nAfter")
    }

    @Test("typing hello is one Undo step and one Redo step")
    func typingRunUndo() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let cell = try editor.focusCell(inTableContaining: "| A", row: 1, column: 1)
        for character in "hello" {
            cell.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        let typed = Self.source.replacingOccurrences(of: "| 2 |", with: "| 2hello |")
        #expect(editor.main.string == typed)
        #expect(editor.state.undo.undoActionName == "Edit Table Cell")
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
        #expect(cell.string == "2")
        #expect(!editor.state.undo.canUndo)
        editor.state.undo.redo()
        #expect(editor.main.string == typed)
        #expect(cell.string == "2hello")
        #expect(!editor.state.undo.canRedo)
    }

    @Test("a typing run ends after 500 ms idle, on a cell change and on a non-adjacent edit")
    func typingRunBoundaries() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let cell = try editor.focusCell(inTableContaining: "| A", row: 1, column: 1)
        func type(_ text: String) {
            cell.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        type("a")
        try await Task.sleep(for: .milliseconds(650))
        type("b")
        command(cell, #selector(NSResponder.moveLeft(_:)))
        command(cell, #selector(NSResponder.moveRight(_:)))
        type("c")
        cell.setSelectedRange(NSRange(location: 0, length: 0))
        type("d")
        #expect(editor.main.string == Self.source.replacingOccurrences(of: "| 2 |", with: "| d2abc |"))
        // Moving away and back keeps "c" adjacent to "b": one run. "d" is not adjacent.
        for expected in ["| 2abc |", "| 2a |", "| 2 |"] {
            editor.state.undo.undo()
            #expect(editor.main.string == Self.source.replacingOccurrences(of: "| 2 |", with: expected))
        }
        #expect(!editor.state.undo.canUndo)
    }

    @Test("Delete Table is one Undo step that restores the exact bytes")
    func deleteTable() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        let items = session.cellActionItems(fromKeyboard: false)
        let titles = items.map(\.title)
        let delete = try #require(titles.firstIndex(of: "Delete table"))
        #expect(delete == (try #require(titles.firstIndex(of: "Delete column"))) + 1)
        #expect(items[delete].isDanger)
        items[delete].action?()
        #expect(editor.main.string == "Intro\n\nAfter")
        #expect(!session.isActive)
        #expect(editor.window.firstResponder === editor.main)
        #expect(editor.main.selectedRange() == NSRange(location: 7, length: 0))
        #expect(editor.state.undo.undoActionName == "Delete Table")
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
        #expect(!editor.state.undo.canUndo)
    }

    @Test("Delete Table at the end of a note leaves the preceding paragraph's end as the caret")
    func deleteTableAtTheEnd() async throws {
        let source = "Intro\n\n| A | B |\n| --- | --- |\n| 1 | 2 |"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        #expect(editor.coordinator.tableEditingSession.deleteTable())
        #expect(editor.main.string == "Intro\n")
        #expect(editor.main.selectedRange() == NSRange(location: 5, length: 0))
        editor.state.undo.undo()
        #expect(editor.main.string == source)
    }

    @Test("Bold in a cell formats the word at its caret as one Undo action")
    func boldInCell() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let cell = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        editor.coordinator.didMarkdownBold(nil)
        let bold = "Intro\n\n| A | B |\n| --- | --- |\n| hello **world** | 2 |\n\nAfter"
        #expect(editor.main.string == bold)
        #expect(cell.string == "hello **world**")
        #expect(editor.state.undo.undoActionName == "Bold")
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
        #expect(cell.string == "hello world")
        #expect(!editor.state.undo.canUndo)
    }

    @Test("Table menu commands rewrite only the table and follow the focused cell through Undo")
    func structuralMenu() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        let cell = try editor.focusCell(inTableContaining: "| A", row: 0, column: 0)
        var items = session.cellActionItems(fromKeyboard: false)
        func item(_ title: String) throws -> TableMenuView.Item { try #require(items.first { $0.title == title }) }
        #expect(try item("Insert row above").disabledReason == "Header rows stay at the top.", "Nothing goes above the header")
        #expect(try item("Delete row").isEnabled, "Deleting the header promotes the next row")
        try item("Insert column right").action?()
        let widened = "Intro\n\n| A | B |\n| --- | --- |\n| hello world | 2 |\n\nAfter"
            .replacingOccurrences(of: "| A | B |\n| --- | --- |\n| hello world | 2 |",
                                  with: "| A |   | B |\n| --- | --- | --- |\n| hello world |   | 2 |")
        #expect(editor.main.string == widened)
        #expect(address(session) == [0, 1])
        #expect(editor.window.firstResponder === cell)
        items = session.cellActionItems(fromKeyboard: false)
        try item("Align center").action?()
        #expect(editor.main.string == widened.replacingOccurrences(of: "| --- | --- | --- |", with: "| --- | :---: | --- |"))
        editor.state.undo.undo()
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
        #expect(session.isActive && session.column == 1)
    }

    @Test("A missing trailing cell is written with its separators on first input")
    func missingCell() async throws {
        let source = "| X | Y |\n| --- | --- |\n| missing |\n"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        let cell = try editor.focusCell(inTableContaining: "| X", row: 1, column: 1)
        #expect(cell.string.isEmpty)
        editor.replaceCell(cell, with: "y")
        #expect(editor.main.string == "| X | Y |\n| --- | --- |\n| missing | y |\n")
        editor.replaceCell(cell, with: "yz")
        #expect(editor.main.string == "| X | Y |\n| --- | --- |\n| missing | yz |\n")
        editor.state.undo.undo()
        editor.state.undo.undo()
        #expect(editor.main.string == source)
    }

    @Test("Native Undo of prose typing while a cell is focused neither locks the editor nor misplaces the cell")
    func proseUndoDoesNotLock() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        editor.main.setSelectedRange(NSRange(location: 0, length: 0))
        editor.state.undo.beginUndoGrouping()
        editor.main.insertText("Prose ", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.state.undo.endUndoGrouping()
        let cell = try editor.focusCell(inTableContaining: "| A", row: 1, column: 1)
        #expect(editor.state.undo.undoActionName == "Typing")
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
        // The cell follows its table to the shifted location on the next keystroke.
        editor.replaceCell(cell, with: "3")
        #expect(session.isActive)
        #expect(editor.main.string == Self.source.replacingOccurrences(of: "| 2 |", with: "| 3 |"))
        editor.window.makeFirstResponder(editor.main)
        editor.main.setSelectedRange(NSRange(location: 0, length: 0))
        editor.state.undo.beginUndoGrouping()
        editor.main.insertText("Typed ", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.state.undo.endUndoGrouping()
        #expect(editor.main.string.hasPrefix("Typed Intro"))
    }

    @Test("A read-only document ends cell editing, and editing resumes when it is writable again")
    func readOnlyDoesNotLock() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 1)
        editor.wrapper.isEditable = false
        editor.wrapper.updateNativeView(editor.scroll, coordinator: editor.coordinator)
        #expect(!session.isActive)
        editor.wrapper.isEditable = true
        editor.wrapper.updateNativeView(editor.scroll, coordinator: editor.coordinator)
        let cell = try editor.focusCell(inTableContaining: "| A", row: 1, column: 1)
        editor.replaceCell(cell, with: "3")
        #expect(editor.main.string == Self.source.replacingOccurrences(of: "| 2 |", with: "| 3 |"))
    }

    @Test("Composition finished after a host update still admits the next keystroke")
    func compositionAcrossHostUpdate() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let cell = try editor.focusCell(inTableContaining: "| A", row: 1, column: 1)
        cell.setSelectedRange(NSRange(location: 0, length: 1))
        cell.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.wrapper.updateNativeView(editor.scroll, coordinator: editor.coordinator)
        cell.insertText("二", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.main.string == Self.source.replacingOccurrences(of: "| 2 |", with: "| 二 |"))
        cell.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.main.string == Self.source.replacingOccurrences(of: "| 2 |", with: "| 二! |"))
    }

    @Test("A cell keystroke stays hidden in source and re-renders the table after a pause or on exit")
    func deferredRender() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let storage = try #require(editor.main.textStorage)
        let anchor = (Self.source as NSString).range(of: "| A").location
        func image() -> NSImage? { storage.attribute(.renderedBlockImage, at: anchor, effectiveRange: nil) as? NSImage }
        let original = try #require(image())
        let cell = try editor.focusCell(inTableContaining: "| A", row: 1, column: 1)
        cell.insertText("9", replacementRange: NSRange(location: NSNotFound, length: 0))
        let edited = Self.source.replacingOccurrences(of: "| 2 |", with: "| 29 |")
        #expect(editor.main.string == edited)
        let inserted = (edited as NSString).range(of: "29").location + 1
        #expect(storage.attribute(.foregroundColor, at: inserted, effectiveRange: nil) as? NSColor == .clear)
        #expect(image() === original, "The grid shows the keystroke; the image waits for a pause")
        try await Task.sleep(for: .milliseconds(450))
        let paused = try #require(image())
        #expect(paused !== original)
        #expect(paused.size.width >= original.size.width)

        cell.insertText("9", replacementRange: NSRange(location: NSNotFound, length: 0))
        cell.doCommand(by: #selector(NSResponder.moveDown(_:)))
        try await Task.sleep(for: .milliseconds(50))
        #expect(image() !== paused, "Ending cell editing renders the last keystroke at once")
        #expect(storage.attribute(.foregroundColor, at: inserted + 1, effectiveRange: nil) as? NSColor == .clear)
    }

    @Test("The host's key view is the focused cell while one is edited, otherwise the text view")
    func hostKeyView() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        #expect(editor.scroll.markdownEditorKeyView === editor.main)
        let cell = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        #expect(editor.scroll.markdownEditorKeyView === cell)
        cell.doCommand(by: #selector(NSResponder.moveDown(_:)))
        #expect(editor.scroll.markdownEditorKeyView === editor.main)
    }

    @Test("Switching tables right after typing re-renders the first table and its later edits stay exact")
    func switchTablesBeforeRender() async throws {
        let source = "Intro\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\nMiddle\n\n| C | D |\n| --- | --- |\n| 3 | 4 |\n"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        await editor.settle()
        let first = try editor.clickRenderedCell(inTableContaining: "| A", row: 1, column: 1)
        for _ in 0..<8 { first.insertText("9", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        _ = try editor.clickRenderedCell(inTableContaining: "| C", row: 1, column: 0)
        await editor.settle()
        let storage = try #require(editor.main.textStorage)
        let payload = try #require(storage.attribute(.markdownTableSourceRange, at: 7, effectiveRange: nil) as? NSValue)
        #expect(AnchorRelativeRange.decode(payload, anchorLocation: 7).length == ("| A | B |\n| --- | --- |\n| 1 | 299999999 |" as NSString).length,
                "The first table re-rendered when editing moved to the second")
        let again = try editor.clickRenderedCell(inTableContaining: "| A", row: 1, column: 1)
        #expect(again.string == "299999999")
        again.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.main.string == source.replacingOccurrences(of: "| 1 | 2 |", with: "| 1 | 299999999! |"))
    }

    @Test("A trailing backslash in an unpadded cell never escapes the closing pipe")
    func trailingBackslash() async throws {
        let source = "|A|B|\n|---|---|\n|1|2|\n"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        let cell = try editor.focusCell(inTableContaining: "|A", row: 1, column: 0)
        cell.insertText("\\", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.main.string == "|A|B|\n|---|---|\n|1\\ |2|\n")
        let table = try #require(editor.coordinator.tableEditingSession.table)
        #expect(table.rows[2].cells.count == 2)
    }

    @Test("Input substitutions in a cell follow the document editor's policy")
    func substitutionPolicy() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        editor.main.isAutomaticQuoteSubstitutionEnabled = false
        editor.main.isAutomaticDashSubstitutionEnabled = false
        editor.main.isAutomaticTextReplacementEnabled = false
        let cell = try editor.focusCell(inTableContaining: "| A", row: 1, column: 1)
        #expect(!cell.isAutomaticQuoteSubstitutionEnabled)
        #expect(!cell.isAutomaticDashSubstitutionEnabled)
        #expect(!cell.isAutomaticTextReplacementEnabled)
    }

    @Test("A revealed heading settles after cell edits that add Markdown tokens")
    func headingSettlesAfterTokenEdits() async throws {
        let source = "Intro\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n# Heading below\n\nAfter"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        await editor.settle()
        editor.main.setSelectedRange(NSRange(location: (source as NSString).range(of: "Heading").location, length: 0))
        await editor.settle()
        let storage = try #require(editor.main.textStorage)
        let revealed = try #require(storage.attribute(.font, at: (source as NSString).range(of: "# ").location, effectiveRange: nil) as? NSFont)
        let cell = try editor.focusCell(inTableContaining: "| A", row: 1, column: 1)
        editor.replaceCell(cell, with: "**x**")
        try await Task.sleep(for: .milliseconds(450))
        cell.doCommand(by: #selector(NSResponder.moveDown(_:)))
        try await Task.sleep(for: .milliseconds(100))
        await editor.settle()
        let hash = (editor.main.string as NSString).range(of: "# Heading").location
        let settled = try #require(storage.attribute(.font, at: hash, effectiveRange: nil) as? NSFont)
        #expect(settled.pointSize < revealed.pointSize, "The heading marker collapses once the caret leaves it")
    }

    @Test("Remounting a grid does not take the keyboard from another control")
    func remountKeepsOtherFocus() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 1)
        editor.coordinator.tableEditingSession.detachPresentation()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        editor.window.contentView?.addSubview(field)
        try #require(editor.window.makeFirstResponder(field))
        editor.main.refreshInlineTableEditor()
        let responder = editor.window.firstResponder
        #expect(responder === field || responder === field.currentEditor())
    }

    @Test("Leaving a CRLF table upward puts the caret before the line break, not inside it")
    func leaveUpwardKeepsCRLF() async throws {
        let source = "Intro\r\n| A | B |\r\n| --- | --- |\r\n| 1 | 2 |\r\n"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        let cell = try editor.focusCell(inTableContaining: "| A", row: 0, column: 0)
        cell.doCommand(by: #selector(NSResponder.moveUp(_:)))
        #expect(editor.main.selectedRange() == NSRange(location: 5, length: 0))
    }

    @Test("Clicking prose ends cell editing and removes the grid")
    func clickProse() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let session = editor.coordinator.tableEditingSession
        _ = try editor.focusCell(inTableContaining: "| A", row: 1, column: 1)
        #expect(try !editor.routeClick(at: editor.point(atSourceLocation: 1)))
        #expect(!session.isActive)
        #expect(editor.window.firstResponder === editor.main)
        #expect(!editor.main.subviews.contains { $0 is MarkdownTableGridView })
        #expect(editor.main.string == Self.source)
    }

}
