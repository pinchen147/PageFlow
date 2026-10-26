import Foundation
import Testing
@testable import MarkdownEngine

/// the reference editor's Move row or column and Sort (doc 24 §5.4.5, §5.9.4): one
/// rewrite, the alignment cell travels with its column, line endings stay put.
@Suite("Table move and sort plans")
struct TableMoveSortPlanTests {
    private func table(_ text: String) throws -> MarkdownTableSource {
        try #require(MarkdownTableSource(source: text, range: NSRange(location: 0, length: (text as NSString).length)))
    }

    @Test("a body row moves to a boundary; the header and a drop on its own boundary refuse")
    func moveRow() throws {
        let t = try table("| A |\n| --- |\n| 1 |\n| 2 |\n| 3 |")
        #expect(MarkdownTableEditPlan.movingRow(1, to: 4, in: t) == "| A |\n| --- |\n| 2 |\n| 3 |\n| 1 |")
        #expect(MarkdownTableEditPlan.movingRow(3, to: 1, in: t) == "| A |\n| --- |\n| 3 |\n| 1 |\n| 2 |")
        #expect(MarkdownTableEditPlan.movingRow(2, to: 2, in: t) == nil)
        #expect(MarkdownTableEditPlan.movingRow(2, to: 3, in: t) == nil)
        #expect(MarkdownTableEditPlan.movingRow(0, to: 2, in: t) == nil, "header rows stay at the top")
        #expect(MarkdownTableEditPlan.movingRow(2, to: 0, in: t) == nil, "nothing goes above the header")
    }

    @Test("a column moves with its alignment cell; CRLF and padding stay")
    func moveColumn() throws {
        let t = try table("| A | B  | C |\r\n| :-- | :-: | --: |\r\n| 1 | 2  | 3 |\r\n")
        #expect(MarkdownTableEditPlan.movingColumn(0, to: 3, in: t) == "| B  | C | A |\r\n| :-: | --: | :-- |\r\n| 2  | 3 | 1 |\r\n")
        #expect(MarkdownTableEditPlan.movingColumn(2, to: 0, in: t) == "| C | A | B  |\r\n| --: | :-- | :-: |\r\n| 3 | 1 | 2  |\r\n")
        #expect(MarkdownTableEditPlan.movingColumn(1, to: 1, in: t) == nil)
    }

    @Test("sort keeps the header and padding, is number-aware and stable")
    func sort() throws {
        let t = try table("| N |\n| --- |\n| 10 |\n| 2 |\n|  b |\n| 2 |")
        let keys = ["10", "2", "b", "2"]
        #expect(MarkdownTableEditPlan.sortingRows(by: keys, ascending: true, in: t) == "| N |\n| --- |\n| 2 |\n| 2 |\n| 10 |\n|  b |")
        #expect(MarkdownTableEditPlan.sortingRows(by: keys, ascending: false, in: t) == "| N |\n| --- |\n|  b |\n| 10 |\n| 2 |\n| 2 |")
        let sorted = try table("| N |\n| --- |\n| 1 |\n| 2 |")
        #expect(MarkdownTableEditPlan.sortingRows(by: ["1", "2"], ascending: true, in: sorted) == nil)
    }

    @Test("Align left writes plain dashes, the reference editor's unaligned column")
    func alignLeft() throws {
        let t = try table("| A |\n| :-: |\n| 1 |")
        #expect(MarkdownTableEditPlan(.align(.left), table: t, row: 1, column: 0)?.replacement == "| A |\n| --- |\n| 1 |")
    }
}
