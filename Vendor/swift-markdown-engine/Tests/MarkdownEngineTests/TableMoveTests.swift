import AppKit
import Testing
@testable import MarkdownEngine

/// The table handle's drag (doc 24 §5.7.6): the source block moves between
/// top-level blocks as one Undo step and comes back with every cell selected.
@MainActor
@Suite("Table block move", .serialized)
struct TableMoveTests {
    static let table = "| t | u |\n| - | - |\n| 1 | 2 |"

    private func range(_ editor: MountedTableEditor) throws -> NSRange {
        try #require(editor.coordinator.parsedDocument(for: editor.main.string).tokens.first { $0.kind == .table }).range
    }

    @Test("block boundaries: the start of the block under a location, or of the next one")
    func boundaries() {
        let text = "A\nA2\n\nB\n\n\nC" as NSString
        let a2 = text.range(of: "A2").location
        #expect(NativeTextViewCoordinator.blockBoundary(near: a2, after: false, in: text) == 0)
        #expect(NativeTextViewCoordinator.blockBoundary(near: a2, after: true, in: text) == text.range(of: "B").location)
        #expect(NativeTextViewCoordinator.blockBoundary(near: text.range(of: "B").location + 2, after: false, in: text) == text.range(of: "C").location)
        #expect(NativeTextViewCoordinator.blockBoundary(near: text.range(of: "C").location, after: true, in: text) == text.length)
    }

    @Test("a table moves down, up and to the end as one Undo step each, with every cell selected after")
    func moves() async throws {
        let source = "A\n\n" + Self.table + "\n\nB\n\nC"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        let ns = source as NSString
        #expect(editor.coordinator.moveTable(try range(editor), to: ns.range(of: "C").location))
        #expect(editor.main.string == "A\n\nB\n\n" + Self.table + "\n\nC")
        let session = editor.coordinator.tableEditingSession
        #expect(session.cellSelection == TableCellSelection(anchor: CellCoord(row: 0, column: 0), head: CellCoord(row: 1, column: 1)))
        editor.state.undo.undo()
        #expect(editor.main.string == source)
        #expect(editor.coordinator.moveTable(try range(editor), to: 0))
        #expect(editor.main.string == Self.table + "\n\nA\n\nB\n\nC")
        editor.state.undo.undo()
        #expect(editor.main.string == source)
        #expect(editor.coordinator.moveTable(try range(editor), to: ns.length))
        #expect(editor.main.string == "A\n\nB\n\nC\n\n" + Self.table)
        editor.state.undo.undo()
        #expect(editor.main.string == source)
    }

    @Test("a drop on the table's own place changes nothing and adds no Undo step")
    func ownPlace() async throws {
        let source = "A\n\n" + Self.table + "\n\nB"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        let table = try range(editor)
        #expect(!editor.coordinator.moveTable(table, to: table.location))
        #expect(!editor.coordinator.moveTable(table, to: (source as NSString).range(of: "B").location))
        #expect(editor.main.string == source)
        #expect(!editor.state.undo.canUndo)
    }

    @Test("the editor accepts the handle's drag and snaps a point to the nearest block start")
    func dropTarget() async throws {
        let source = "A\n\n" + Self.table + "\n\nB paragraph\n\nC"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        await editor.settle()
        #expect(editor.main.acceptableDragTypes.contains(TableChromeController.tableMoveType))
        let ns = source as NSString
        let b = ns.range(of: "B paragraph").location
        let screen = editor.main.firstRect(forCharacterRange: NSRange(location: b, length: 1), actualRange: nil)
        let rect = editor.main.convert(editor.window.convertFromScreen(screen), from: nil)
        #expect(editor.main.tableDropBoundary(at: NSPoint(x: rect.minX + 20, y: rect.minY + 1)) == b)
        #expect(editor.main.tableDropBoundary(at: NSPoint(x: rect.minX + 20, y: rect.maxY + 14)) == ns.range(of: "C").location)
    }

    @Test("a handle press without movement is a click: every cell selected")
    func handleClick() async throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        let source = "A\n\n" + Self.table + "\n\nB"
        let editor = try MountedTableEditor(source: source, configuration: configuration)
        defer { editor.close() }
        await editor.settle()
        let chrome = try #require(editor.coordinator.tableChrome)
        let anchor = (source as NSString).range(of: "| t").location
        let image = try #require(editor.main.tableImageRect(at: anchor))
        chrome.hover(at: NSPoint(x: image.minX + 10, y: image.minY + 10))
        try #require(chrome.table != nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: editor.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: editor.window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        var queue = [up]
        chrome.pressHandle(down) { queue.isEmpty ? nil : queue.removeFirst() }
        #expect(editor.coordinator.tableEditingSession.cellSelection
            == TableCellSelection(anchor: CellCoord(row: 0, column: 0), head: CellCoord(row: 1, column: 1)))
    }
}
