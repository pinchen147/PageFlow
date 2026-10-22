import AppKit
import Testing
@testable import MarkdownEngine

/// Doc 24 §8.5 acceptance: hover redraws stay under 0.5 ms (Release), and an
/// input method's candidate window anchors inside the cell being edited.
@MainActor
@Suite("Table chrome cost and IME anchor", .serialized)
struct TableChromePerfAndIMETests {
    static let source: String = {
        let header = "| " + (0..<3).map { "Head \($0)" }.joined(separator: " | ") + " |"
        let delimiter = "|" + String(repeating: " --- |", count: 3)
        let rows = (0..<20).map { r in "| " + (0..<3).map { "r\(r)c\($0)" }.joined(separator: " | ") + " |" }
        return "Intro\n\n" + ([header, delimiter] + rows).joined(separator: "\n") + "\n\nAfter"
    }()

    @Test("drawing the hover chrome for a 21 × 3 table costs under 0.5 ms (Release)")
    func hoverRedrawCost() async throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        let editor = try MountedTableEditor(source: Self.source, configuration: configuration)
        defer { editor.close() }
        await editor.settle()
        let chrome = try #require(editor.coordinator.tableChrome)
        let anchor = (Self.source as NSString).range(of: "| Head 0").location
        let image = try #require(editor.main.tableImageRect(at: anchor))
        chrome.hover(at: NSPoint(x: image.minX + 12, y: image.minY + 50))
        let view = chrome.view
        try #require(!view.isHidden)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        // Hover over a grip: the active grip, its tint over a column, the handle, the bars.
        view.hoveredZone = .columnGrip
        let runs = 200
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<runs { view.draw(view.bounds) }
        let perDraw = (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(runs)
        print(String(format: "CHROME-DRAW %.3f ms per hover redraw", perDraw))
        #if DEBUG
        #expect(perDraw < 5, "Debug bound; the 0.5 ms bar is checked in Release")
        #else
        #expect(perDraw < 0.5)
        #endif
    }

    @Test("an input method's candidate window anchors inside the edited cell")
    func candidateWindowAnchor() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let cell = try editor.focusCell(inTableContaining: "| Head 0", row: 3, column: 2)
        cell.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let screen = cell.firstRect(forCharacterRange: cell.markedRange(), actualRange: nil)
        let grid = try #require(editor.coordinator.tableEditingSession.grid)
        let cellRect = grid.convert(grid.geometry.cellRects[3][2], to: nil)
        let cellOnScreen = editor.window.convertToScreen(cellRect)
        #expect(cellOnScreen.insetBy(dx: -1, dy: -1).contains(NSPoint(x: screen.minX, y: screen.midY)),
                "the marked text the IME draws its candidates under is inside the cell")
        cell.unmarkText()
    }
}
