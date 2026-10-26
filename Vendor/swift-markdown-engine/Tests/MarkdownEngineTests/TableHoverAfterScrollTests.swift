import AppKit
import Testing
@testable import MarkdownEngine

/// The hover chrome's table index belongs to one laid-out viewport: a table
/// scrolled into view (below a wide one) takes hover chrome straight away.
@MainActor
@Suite("Table hover after scrolling", .serialized)
struct TableHoverAfterScrollTests {
    static let source = #"""
# Tables demo

Select any words in this sentence to see the selection bar, then try Bold, Highlight or Link.

| Feature | Try this | Expected |
| --- | --- | --- |
| Hover | Move the pointer over a cell | Handle on the left, row and column grips |
| Cell actions | Right-click a cell's blank space, or press ⇧F10 | Insert, Move, Set column width, Delete, Sort, Align |
| Ranges | Drag from one cell into another, or Shift-arrow past a cell's edge | Cells tinted; typing replaces them |
| Grips | Click or drag a grip | Selects or moves the column or row |
| Widths | Drag a column's right border | Column resizes; the file does not change |

Some text between the tables.

| Name | Qty | Price |
| :--- | ---: | ---: |
| Apples | 10 | 2.50 |
| Pears | 2 | 1.75 |
| Plums | 7 | 3.10 |

A wide table:

| Column one heading | Column two heading | Column three heading | Column four heading | Column five heading | Column six heading |
| --- | --- | --- | --- | --- | --- |
| a fairly long value | another long value | yet another value | still more text here | the fifth column | the sixth column |
| short | short | short | short | short | short |

The end.
"""#

    @Test("a narrow table scrolled into view under a wide one shows its chrome on hover")
    func hoverAfterScroll() async throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        configuration.readingWidth = 672
        let editor = try MountedTableEditor(source: Self.source, configuration: configuration)
        defer { editor.close() }
        editor.window.setContentSize(NSSize(width: 900, height: 450))
        await editor.settle()
        let chrome = try #require(editor.coordinator.tableChrome)
        // Build the index while only the top of the note is laid out.
        chrome.hover(at: NSPoint(x: 10, y: 10))
        let anchor = (editor.main.string as NSString).range(of: "| Name").location
        editor.main.scrollRangeToVisible(NSRange(location: anchor, length: 0))
        await editor.settle()
        let image = try #require(editor.main.tableImageRect(at: anchor))
        chrome.hover(at: NSPoint(x: image.minX + 20, y: image.minY + 10))
        #expect(!chrome.view.isHidden)
        #expect(chrome.view.hovered == CellCoord(row: 0, column: 0))
    }
}
