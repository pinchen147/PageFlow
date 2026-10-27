import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Protected reading position restore", .serialized)
struct ProtectedReadingPositionTests {
    @Test("Restore defers, reports execution-time departure and accepts equal positions")
    func deferredRestore() throws {
        guard #available(macOS 15.0, *) else { return }
        let editor = try MountedTableEditor(source: String(repeating: "paragraph\n\n", count: 100))
        defer { editor.close() }
        editor.main.ensureVisibleLayout()
        let controller = editor.state.controller
        let target = try #require(controller.readingPosition)
        var departures: [ReadingPosition] = []
        editor.coordinator.textViewWritingToolsWillBegin(editor.main)
        controller.restore(target, whileValid: { true }, didRestore: { departures.append($0) })
        #expect(departures.isEmpty)
        controller.scroll(toOffset: 600)
        let departure = try #require(controller.readingPosition)
        editor.coordinator.textViewWritingToolsDidEnd(editor.main)
        #expect(departures == [departure])
        controller.restore(target, whileValid: { true }, didRestore: { departures.append($0) })
        #expect(departures.count == 2)
    }

    @Test("Rejected or superseded restores do not report history", arguments: ["invalid", "cancel", "source", "undo", "find", "hide", "rebind"])
    func rejectedRestore(reason: String) throws {
        guard #available(macOS 15.0, *) else { return }
        let editor = try MountedTableEditor(source: String(repeating: "paragraph\n\n", count: 100))
        defer { editor.close() }
        editor.main.ensureVisibleLayout()
        let controller = editor.state.controller
        let target = ReadingPosition(anchorOffset: reason == "invalid" ? 100_000 : 600, offsetInViewport: 0)
        var departures = 0
        var valid = true
        editor.coordinator.textViewWritingToolsWillBegin(editor.main)
        controller.restore(target, whileValid: { valid }, didRestore: { _ in departures += 1 })
        switch reason {
        case "cancel": valid = false
        case "source", "undo":
            editor.state.undo.beginUndoGrouping()
            editor.main.insertText("x", replacementRange: NSRange(location: 0, length: 0))
            editor.main.breakUndoCoalescing()
            editor.state.undo.endUndoGrouping()
            if reason == "undo" { editor.state.undo.undo() }
        case "find": editor.coordinator.handleFindClearHighlights(Notification(name: .init("test"), object: editor.coordinator.documentId))
        case "hide":
            editor.wrapper.isDisplayed = false
            editor.wrapper.updateNativeView(editor.scroll, coordinator: editor.coordinator)
        case "rebind":
            editor.wrapper.editorController = MarkdownEditorController()
            editor.wrapper.updateNativeView(editor.scroll, coordinator: editor.coordinator)
        default: break
        }
        editor.coordinator.textViewWritingToolsDidEnd(editor.main)
        #expect(departures == 0)
    }

    @Test("The latest restore wins and predicates cannot change source ownership")
    func latestAndPredicate() throws {
        guard #available(macOS 15.0, *) else { return }
        let editor = try MountedTableEditor(source: String(repeating: "paragraph\n\n", count: 100))
        defer { editor.close() }
        editor.main.ensureVisibleLayout()
        let controller = editor.state.controller
        var calls: [Int] = []
        editor.coordinator.textViewWritingToolsWillBegin(editor.main)
        controller.restore(.init(anchorOffset: 200, offsetInViewport: 0), whileValid: { true }, didRestore: { _ in calls.append(1) })
        controller.restore(.init(anchorOffset: 400, offsetInViewport: 0), whileValid: { true }, didRestore: { _ in calls.append(2) })
        editor.coordinator.textViewWritingToolsDidEnd(editor.main)
        #expect(calls == [2])
        controller.restore(.init(anchorOffset: 100, offsetInViewport: 0), whileValid: {
            editor.state.undo.beginUndoGrouping()
            editor.main.insertText("new", replacementRange: NSRange(location: 0, length: 0))
            editor.state.undo.endUndoGrouping()
            return true
        }, didRestore: { _ in calls.append(3) })
        #expect(calls == [2])
    }

    @Test("Marked table input stays active and a commit retires its queued restore")
    func tableComposition() async throws {
        let editor = try MountedTableEditor(source: "| H |\n| --- |\n| cell |\n\n" + String(repeating: "tail\n", count: 100))
        defer { editor.close() }
        await editor.settle()
        let cell = try editor.focusCell(inTableContaining: "cell", row: 1, column: 0)
        cell.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
        var calls = 0
        editor.state.controller.restore(.init(anchorOffset: 200, offsetInViewport: 0), whileValid: { true }, didRestore: { _ in calls += 1 })
        #expect(cell.hasMarkedText())
        #expect(editor.window.firstResponder === cell)
        #expect(calls == 0)
        cell.insertText("你", replacementRange: cell.markedRange())
        #expect(calls == 0)
        #expect(editor.coordinator.tableEditingSession.isActive)
    }
}
