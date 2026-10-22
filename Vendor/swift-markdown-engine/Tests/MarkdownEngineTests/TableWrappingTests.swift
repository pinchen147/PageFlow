import AppKit
import Testing
@testable import MarkdownEngine

/// the reference editor's wrapping cells (doc 24 §5.1.2–§5.1.3, §7.3.2–§7.3.5): auto
/// columns cap at 42 characters and wrap, rows have their own heights, `<br>`
/// is a line break, and the cell editor writes one.
@MainActor
@Suite("Table wrapping", .serialized)
struct TableWrappingTests {
    private func layout(_ source: String) throws -> MarkdownTableLayout {
        let model = try #require(MarkdownTableModel.parse(source))
        return MarkdownTableLayout(
            table: MarkdownStyler.parsedTable(from: model), font: .systemFont(ofSize: 16), theme: .default,
            codeBackground: .clear, latex: MarkdownEditorConfiguration.default.services.latex,
            appearance: try #require(NSAppearance(named: .aqua))
        )
    }

    private static let long = String(repeating: "wrapping words ", count: 40)

    @Test("a very long cell is capped at 42 characters and wraps; its row is taller than the others")
    func capAndWrap() throws {
        let table = try layout("| A | B |\n| --- | --- |\n| \(Self.long) | short |\n| x | y |")
        let cap = MarkdownTableLayout.maximumColumnWidth(for: table.cellFont)
        #expect(abs((table.cellRects[1][0].width + 1) - cap) < 1, "column box = 42 × advance of 0")
        #expect(table.cellRects[1][0].height > table.cellRects[2][0].height + table.lineHeight)
        #expect(table.cellRects[0][0].height == table.cellRects[2][0].height)
    }

    @Test("rows have independent heights; the hit test finds cells in tall rows")
    func independentHeights() throws {
        let table = try layout("| A | B |\n| --- | --- |\n| one<br>two<br>three | x |\n| y | z |")
        let tall = table.cellRects[1][0]
        #expect(abs(tall.height - (3 * table.lineHeight + 12)) < 0.5)
        #expect(table.cellRects[2][0].height < tall.height)
        #expect(table.cell(at: NSPoint(x: tall.midX, y: tall.maxY - 2))! == (1, 0))
        #expect(table.cell(at: NSPoint(x: table.cellRects[2][1].midX, y: table.cellRects[2][1].midY))! == (2, 1))
        #expect(table.cell(at: NSPoint(x: -5, y: tall.midY)) == nil)
    }

    @Test("<br> renders as a line break and stays literal inside code; links and bare URLs are styled")
    func inlineRendering() throws {
        let theme = MarkdownEditorTheme.default
        let latex = MarkdownEditorConfiguration.default.services.latex
        func cell(_ raw: String) -> NSAttributedString {
            MarkdownStyler.formattedCellString(raw, baseFont: .systemFont(ofSize: 15), header: false, theme: theme,
                                               codeBackgroundColor: .gray, latex: latex)
        }
        #expect(cell("a<br>b<br/>c<BR />d").string == "a\u{2028}b\u{2028}c\u{2028}d")
        #expect(cell("`a<br>b`").string == "a<br>b")
        #expect(cell("x\\<br>y").string == "x<br>y")
        let link = cell("see [docs](https://example.com) now")
        #expect(link.string == "see docs now")
        #expect(link.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor === theme.link)
        let bare = cell("go to https://example.com today")
        #expect(bare.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? NSColor === theme.link)
        #expect(bare.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor === theme.bodyText)
    }

    static let source = "Para above\n\n| A | B |\n| --- | --- |\n| one | two |\n| three | four |\n\nPara below"

    @Test("Return writes <br> and the caret lands on the new line; the editor shows a line break")
    func returnWritesBreak() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        await editor.settle()
        let cell = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        cell.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        cell.insertText("more", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.main.string == Self.source.replacingOccurrences(of: "| one |", with: "| one<br>more |"))
        #expect(cell.string == "one\nmore")
        #expect(cell.selectedRange() == NSRange(location: 8, length: 0))
        #expect(editor.coordinator.tableEditingSession.row == 1, "Return stays in the cell")
        // ↑ on the second line moves within the cell; on the first line it leaves.
        cell.doCommand(by: #selector(NSResponder.moveUp(_:)))
        #expect(editor.coordinator.tableEditingSession.row == 1)
        #expect(cell.selectedRange().location <= 3)
        cell.doCommand(by: #selector(NSResponder.moveUp(_:)))
        #expect(editor.coordinator.tableEditingSession.row == 0)
    }

    @Test("a typed <br> tag stays text; a table's <br/> spelling is kept")
    func breakSpellingAndLiteralTags() async throws {
        let source = "| A | B |\n| --- | --- |\n| x<br/>y | z |\n"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        await editor.settle()
        let cell = try editor.focusCell(inTableContaining: "| A", row: 1, column: 1)
        #expect(cell.string == "z")
        cell.insertText("<br>", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.main.string.contains("| z\\<br> |"))
        cell.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(editor.main.string.contains("| z\\<br><br/> |"))
        let first = try editor.focusCell(inTableContaining: "| A", row: 1, column: 0)
        #expect(first.string == "x\ny")
    }

    @Test("a keystroke that adds a line re-renders the table at once; the text above stays and the text below moves by the row delta")
    func rowGrowthRestylesNow() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        await editor.settle()
        let storage = try #require(editor.main.textStorage)
        let anchor = (Self.source as NSString).range(of: "| A").location
        func image() -> NSImage? { storage.attribute(.renderedBlockImage, at: anchor, effectiveRange: nil) as? NSImage }
        func top(_ needle: String) throws -> CGFloat {
            try #require(editor.main.lineFrame(at: (editor.main.string as NSString).range(of: needle).location)).minY
        }
        let before = try #require(image())
        let aboveBefore = try top("Para above")
        let belowBefore = try top("Para below")
        let cell = try editor.focusCell(inTableContaining: "| A", row: 1, column: 1)
        cell.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(image() === before, "a same-height keystroke waits for the deferred render")
        cell.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        let after = try #require(image())
        #expect(after.size.height > before.size.height, "the taller table rendered in the same turn")
        #expect(try top("Para above") == aboveBefore)
        await editor.settle()
        #expect(abs(try top("Para below") - belowBefore - (after.size.height - before.size.height)) < 1)
    }

    @Test("editing one cell keeps every other byte of the table")
    func byteExactRoundTrip() async throws {
        let source = "|a|  b  |\n|:-|--:|\n| one<br />two | \\|x |\n|three|four|\n"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        await editor.settle()
        let cell = try editor.focusCell(inTableContaining: "|a", row: 2, column: 1)
        cell.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.main.string == "|a|  b  |\n|:-|--:|\n| one<br />two | \\|x |\n|three|four!|\n")
        let other = try editor.focusCell(inTableContaining: "|a", row: 1, column: 0)
        #expect(other.string == "one\ntwo")
        other.insertText("?", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.main.string == "|a|  b  |\n|:-|--:|\n| one<br />two? | \\|x |\n|three|four!|\n")
    }
}
