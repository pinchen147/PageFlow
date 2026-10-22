import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Block drag source lifecycle", .serialized)
struct BlockDragLifecycleTests {
    @Test("bounded moves and their undo keep the prepared index current")
    func boundedMoveRevision() async throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        let source = "First e\u{301} 😀\n\nSecond\n\nTail"
        let editor = try MountedTableEditor(source: source, configuration: configuration)
        defer { editor.close() }
        await editor.settle()
        let first = (source as NSString).range(of: "First e\u{301} 😀")
        let payload = try #require(editor.coordinator.blockMovePayload(range: first, kind: .paragraph))
        #expect(editor.coordinator.moveBlock(payload, to: (source as NSString).range(of: "Tail").location))
        #expect(editor.coordinator.cachedBlockParseRevision?.source == editor.coordinator.nativeSourceGeneration)
        await editor.settle()
        #expect(editor.coordinator.blockMover.currentBlocks(in: editor.main.string as NSString) != nil)
        editor.state.undo.undo()
        #expect(editor.main.string == source)
        #expect(editor.coordinator.cachedBlockParseRevision?.source == editor.coordinator.nativeSourceGeneration)
        await editor.settle()
        #expect(editor.coordinator.blockMover.currentBlocks(in: editor.main.string as NSString) != nil)
        editor.state.undo.redo()
        await editor.settle()
        #expect(editor.coordinator.blockMover.currentBlocks(in: editor.main.string as NSString) != nil)
    }

    @Test("a plain insertion retires the hovered source range immediately")
    func editRetiresHover() async throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        let editor = try MountedTableEditor(source: "First\n\nTail", configuration: configuration)
        defer { editor.close() }
        await editor.settle()
        let mover = editor.coordinator.blockMover
        mover.hover(at: NSPoint(x: editor.main.textContainerOrigin.x + 35, y: editor.main.textContainerOrigin.y + 8))
        _ = try #require(mover.hovered)
        editor.state.undo.beginUndoGrouping()
        editor.main.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        editor.state.undo.endUndoGrouping()
        #expect(mover.hovered == nil)
    }

    @Test("source changes during a pending grip press cannot select stale offsets")
    func editDuringPress() async throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        let editor = try MountedTableEditor(source: "First\n\nTail", configuration: configuration)
        defer { editor.close() }
        await editor.settle()
        let mover = editor.coordinator.blockMover
        mover.hover(at: NSPoint(x: editor.main.textContainerOrigin.x + 35, y: editor.main.textContainerOrigin.y + 8))
        let entry = try #require(mover.hovered)
        let point = editor.main.convert(NSPoint(x: entry.grip.midX, y: entry.grip.midY), to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: editor.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
            modifierFlags: [], timestamp: 1, windowNumber: editor.window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        var delivered = false
        mover.press(down, nextEvent: {
            guard !delivered else { return nil }
            delivered = true
            editor.state.undo.beginUndoGrouping()
            editor.main.insertText("X", replacementRange: NSRange(location: 0, length: 0))
            editor.state.undo.endUndoGrouping()
            return up
        })
        #expect(delivered)
        #expect(editor.main.string == "XFirst\n\nTail")
        #expect(editor.main.selectedRange().length == 0, "the stale original block must not become selected")
        #expect(mover.hovered == nil)
    }
}
