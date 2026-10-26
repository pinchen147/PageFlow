import AppKit
import Testing
@testable import MarkdownEngine

/// Hovering a wide table (an unflipped image view in its own scroller)
/// shows its chrome over the hovered cell, as a narrow table does.
@MainActor
@Suite("Wide table hover", .serialized)
struct WideTableHoverTests {
    static let source = "Intro\n\n| Column one heading | Column two heading | Column three heading | Column four heading | Column five heading | Column six heading |\n| --- | --- | --- | --- | --- | --- |\n| a fairly long value | another long value | yet another value | still more text here | the fifth column | the sixth column |\n\nAfter"

    @Test("hovering a wide table's body cell shows the chrome on that cell, in page look")
    func wideTableHover() async throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        configuration.readingWidth = 500
        let editor = try MountedTableEditor(source: Self.source, configuration: configuration)
        defer { editor.close() }
        editor.window.setContentSize(NSSize(width: 800, height: 600))
        await editor.settle()
        let chrome = try #require(editor.coordinator.tableChrome)
        let overlay = try #require(editor.main.wideTableOverlays.values.first)
        let canvas = try #require(overlay.documentView)
        #expect(!canvas.isFlipped, "the case this covers")
        let token = try #require(editor.coordinator.parsedDocument(for: editor.main.string).tokens.first { $0.kind == .table })
        let geometry = try #require(editor.coordinator.tableEditingSession.geometry(forTableAt: token.range))
        let cell = editor.main.convertTableRect(geometry.cellRects[1][0], canvas: (canvas, .zero))
        // The body row sits below the header in the text view.
        #expect(cell.minY > editor.main.convertTableRect(geometry.cellRects[0][0], canvas: (canvas, .zero)).minY)
        chrome.hover(at: NSPoint(x: cell.midX, y: cell.midY))
        #expect(!chrome.view.isHidden)
        #expect(chrome.view.hovered == CellCoord(row: 1, column: 0))
        // Drawn over the wide table, which is the text view's sibling in page look.
        let container = try #require(editor.main.superview)
        let hostIndex = try #require(container.subviews.firstIndex { $0 === chrome.host })
        let overlayIndex = try #require(container.subviews.firstIndex { $0 === overlay })
        #expect(hostIndex > overlayIndex)
        #expect(chrome.view.superview === chrome.host && chrome.host.frame == editor.main.frame)
    }

    @Test("moving from a wide table's cell onto its column grip keeps the chrome on the grip")
    func gripMove() async throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        configuration.readingWidth = 500
        let editor = try MountedTableEditor(source: Self.source, configuration: configuration)
        defer { editor.close() }
        editor.window.setContentSize(NSSize(width: 800, height: 600))
        await editor.settle()
        let chrome = try #require(editor.coordinator.tableChrome)
        let overlay = try #require(editor.main.wideTableOverlays.values.first)
        let canvas = try #require(overlay.documentView)
        let token = try #require(editor.coordinator.parsedDocument(for: editor.main.string).tokens.first { $0.kind == .table })
        let geometry = try #require(editor.coordinator.tableEditingSession.geometry(forTableAt: token.range))
        let cell = editor.main.convertTableRect(geometry.cellRects[1][0], canvas: (canvas, .zero))
        chrome.hover(at: NSPoint(x: cell.midX, y: cell.midY))
        let grip = try #require(chrome.view.layout).columnGrip(0)
        chrome.hover(at: NSPoint(x: grip.midX, y: grip.midY))
        #expect(!chrome.view.isHidden)
        #expect(chrome.view.hoveredZone == .columnGrip)
    }
}
