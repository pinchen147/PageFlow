import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Table structural edits preserve untouched source")
struct MarkdownTableEditPlanTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let source: String
        let edit: MarkdownTableEdit
        let row: Int
        let column: Int
        let expected: String?
        let focus: [Int]
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "row below keeps aligned widths and LF",
             source: "| Name  | B |\n| ----- | :---: |\n| x\\|y | 2 |\n",
             edit: .insertRow(below: true), row: 1, column: 1,
             expected: "| Name  | B |\n| ----- | :---: |\n| x\\|y | 2 |\n|       |   |\n", focus: [2, 1]),
        Case(name: "row above a body row",
             source: "| A | B |\n| --- | --- |\n| 1 | 2 |\n",
             edit: .insertRow(below: false), row: 1, column: 0,
             expected: "| A | B |\n| --- | --- |\n|   |   |\n| 1 | 2 |\n", focus: [1, 0]),
        Case(name: "row below the last row at EOF keeps CRLF and no final break",
             source: "| A | B |\r\n| --- | --- |\r\n| 1 | 2 |",
             edit: .insertRow(below: true), row: 1, column: 0,
             expected: "| A | B |\r\n| --- | --- |\r\n| 1 | 2 |\r\n|   |   |", focus: [2, 0]),
        Case(name: "row below the header starts the body",
             source: "| A |\n| --- |\n| 1 |",
             edit: .insertRow(below: true), row: 0, column: 0,
             expected: "| A |\n| --- |\n|   |\n| 1 |", focus: [1, 0]),
        Case(name: "no row above the header",
             source: "| A |\n| --- |\n| 1 |",
             edit: .insertRow(below: false), row: 0, column: 0, expected: nil, focus: []),
        Case(name: "delete a middle row",
             source: "| A |\r\n| --- |\r\n| 1 |\r\n| 2 |\r\n| 3 |",
             edit: .deleteRow, row: 2, column: 0,
             expected: "| A |\r\n| --- |\r\n| 1 |\r\n| 3 |", focus: [2, 0]),
        Case(name: "delete the last row at EOF drops the separating break",
             source: "| A |\n| --- |\n| 1 |\n| 2 |",
             edit: .deleteRow, row: 2, column: 0,
             expected: "| A |\n| --- |\n| 1 |", focus: [1, 0]),
        Case(name: "delete the only body row focuses the header",
             source: "| A |\n| --- |\n| 1 |\n",
             edit: .deleteRow, row: 1, column: 0,
             expected: "| A |\n| --- |\n", focus: [0, 0]),
        Case(name: "the header row is never deleted",
             source: "| A |\n| --- |\n| 1 |",
             edit: .deleteRow, row: 0, column: 0, expected: nil, focus: []),
        Case(name: "column right materializes a missing cell and keeps overflow",
             source: "| A | B |\n| --- | --- |\n| short |\n| a | b | extra |",
             edit: .insertColumn(right: true), row: 0, column: 1,
             expected: "| A | B |   |\n| --- | --- | --- |\n| short |  |   |\n| a | b |   | extra |", focus: [0, 2]),
        Case(name: "column left of the first column",
             source: "| A | B |\n| :--- | ---: |\n| 1 | 2 |",
             edit: .insertColumn(right: false), row: 1, column: 0,
             expected: "|   | A | B |\n| --- | :--- | ---: |\n|   | 1 | 2 |", focus: [1, 0]),
        Case(name: "appending a column to a borderless table adds trailing pipes",
             source: "A | B\n--- | ---\n1 | 2",
             edit: .insertColumn(right: true), row: 0, column: 1,
             expected: "A | B|  |\n--- | ---| --- |\n1 | 2|  |", focus: [0, 2]),
        Case(name: "column left of a borderless first column adds a leading pipe",
             source: "A | B\n--- | ---\n1 | 2",
             edit: .insertColumn(right: false), row: 1, column: 0,
             expected: "|  |A | B\n| --- |--- | ---\n|  |1 | 2", focus: [1, 0]),
        Case(name: "delete a column keeps the rest verbatim",
             source: "| A | B | C |\n| --- | :---: | ---: |\n| 1 | 2 |",
             edit: .deleteColumn, row: 1, column: 1,
             expected: "| A | C |\n| --- | ---: |\n| 1 |", focus: [1, 1]),
        Case(name: "deleting down to one borderless column adds pipes",
             source: "A | B\n--- | ---\n1 | 2",
             edit: .deleteColumn, row: 0, column: 1,
             expected: "|A |\n|--- |\n|1 |", focus: [0, 0]),
        Case(name: "deleting beside a blank borderless cell keeps the row's columns",
             source: "A | B | C\n--- | --- | ---\n1 |  | 3",
             edit: .deleteColumn, row: 0, column: 0,
             expected: " B | C\n --- | ---\n|  | 3", focus: [0, 0]),
        Case(name: "the last column is never deleted",
             source: "| A |\n| --- |",
             edit: .deleteColumn, row: 0, column: 0, expected: nil, focus: []),
        Case(name: "align center keeps dash count and padding",
             source: "| A | B |\n|  -----  | --- |\n| 1 | 2 |",
             edit: .align(.center), row: 1, column: 0,
             expected: "| A | B |\n|  :-----:  | --- |\n| 1 | 2 |", focus: [1, 0]),
        Case(name: "align right replaces an existing marker",
             source: "| A |\n| :---: |",
             edit: .align(.right), row: 0, column: 0,
             expected: "| A |\n| ---: |", focus: [0, 0]),
    ]

    @Test(arguments: cases)
    func plan(_ test: Case) throws {
        let source = test.source as NSString
        let table = try #require(MarkdownTableSource(
            source: test.source, range: NSRange(location: 0, length: source.length)
        ))
        let plan = MarkdownTableEditPlan(test.edit, table: table, row: test.row, column: test.column)
        guard let expected = test.expected else {
            #expect(plan == nil)
            return
        }
        let result = try #require(plan)
        #expect(result.replacement == expected)
        #expect([result.row, result.column] == test.focus)
        // The result is still one table with the focused cell present.
        let reparsed = try #require(MarkdownTableSource(
            source: result.replacement, range: NSRange(location: 0, length: (result.replacement as NSString).length)
        ))
        #expect(result.row < reparsed.rowCount && result.column < reparsed.columnCount)
    }
}
