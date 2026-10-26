//
//  MarkdownTableModelTests.swift
//  MarkdownEngineTests
//
//  Table parsing and source serialization coverage.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Markdown table model")
struct MarkdownTableModelTests {
    @Test func parsesOuterPipeTable() throws {
        let model = try #require(MarkdownTableModel.parse("""
        | A | B |
        | --- | ---: |
        | one | two |
        """))

        #expect(model.header == ["A", "B"])
        #expect(model.alignments == [.left, .right])
        #expect(model.rows == [["one", "two"]])
    }

    @Test("cellContentRanges splits on unescaped pipes, respecting `\\|` and `\\\\|`")
    func cellContentRangesSplitsAndRespectsEscapes() {
        func cells(_ line: String) -> [String] {
            let ns = line as NSString
            return MarkdownTableScanner
                .cellContentRanges(inLine: NSRange(location: 0, length: ns.length), of: ns)
                .map { ns.substring(with: $0) }
        }
        #expect(cells("| a | bc |") == ["a", "bc"])
        #expect(cells("a | bc") == ["a", "bc"])                    // no outer pipes
        #expect(cells("|  spaced  |  cell |") == ["spaced", "cell"])   // per-cell trim
        // `\|` is an escaped pipe → stays inside the cell.
        #expect(cells(#"| a \| b | c |"#) == [#"a \| b"#, "c"])
        // `\\|` is an escaped backslash THEN a real delimiter → splits. (The hand-rolled
        // `character(at: k-1) != backslash` check this replaced got this case wrong.)
        #expect(cells(#"| a \\| b |"#) == [#"a \\"#, "b"])
    }

    @Test func parsesOptionalOuterPipeTable() throws {
        let model = try #require(MarkdownTableModel.parse("""
        A | B
        --- | :---:
        one | two
        """))

        #expect(model.header == ["A", "B"])
        #expect(model.alignments == [.left, .center])
        #expect(model.rows == [["one", "two"]])
    }

    @Test func escapedPipesStayInsideCells() throws {
        let model = try #require(MarkdownTableModel.parse("""
        | A | B |
        | --- | --- |
        | one\\|uno | two |
        """))

        #expect(model.cell(row: 1, column: 0) == "one|uno")
        #expect(model.cell(row: 1, column: 1) == "two")
    }

    @Test func rejectsDelimiterCellsWithoutHyphensAndListMarkerRows() {
        #expect(MarkdownTableModel.parse("""
        | A | B |
        | : | --- |
        """) == nil)
        #expect(MarkdownTableModel.parse("""
        A | B
        - | ---
        """) == nil)
    }

    @Test func serializesCanonicalPipeTableAndEscapesLiteralPipes() throws {
        var model = try #require(MarkdownTableModel.parse("""
        A | B
        --- | ---:
        one | two
        """))

        model.setCell(row: 1, column: 0, text: "one|uno")
        _ = model.insertColumn(after: 0)
        model.setCell(row: 0, column: 1, text: "Inserted")
        _ = model.insertBodyRow(after: 1)
        model.setCell(row: 2, column: 2, text: "tail")

        #expect(model.serialized() == """
        | A | Inserted | B |
        | --- | --- | ---: |
        | one\\|uno |  | two |
        |  |  | tail |
        """)
    }

    // MARK: - Row deletion

    @Test func deletesBodyRowAndClampsSelection() throws {
        var model = try #require(MarkdownTableModel.parse("""
        | A | B |
        | --- | --- |
        | one | two |
        | three | four |
        """))

        #expect(model.deleteRow(1) == 1)
        #expect(model.rows == [["three", "four"]])
        // Deleting the now-last body row clamps the selection back to the header.
        #expect(model.deleteRow(1) == 0)
        #expect(model.rows.isEmpty)
        #expect(model.rowCount == 1)
    }

    @Test func refusesToDeleteHeaderRow() throws {
        var model = try #require(MarkdownTableModel.parse("""
        | A | B |
        | --- | --- |
        | one | two |
        """))

        #expect(model.deleteRow(0) == nil)
        #expect(model.deleteRow(5) == nil)
        #expect(model.rowCount == 2)
    }

    // MARK: - Column deletion

    @Test func deletesColumnAcrossHeaderSeparatorAndRows() throws {
        var model = try #require(MarkdownTableModel.parse("""
        | A | B | C |
        | --- | :---: | ---: |
        | one | two | three |
        """))

        #expect(model.deleteColumn(1) == 1)
        #expect(model.header == ["A", "C"])
        #expect(model.alignments == [.left, .right])
        #expect(model.rows == [["one", "three"]])
        #expect(model.serialized() == """
        | A | C |
        | --- | ---: |
        | one | three |
        """)
    }

    @Test func refusesColumnDeletionBelowTwoColumns() throws {
        var model = try #require(MarkdownTableModel.parse("""
        | A | B |
        | --- | --- |
        | one | two |
        """))

        #expect(model.deleteColumn(0) == nil)
        #expect(model.deleteColumn(1) == nil)
        #expect(model.columnCount == 2)
    }

    @Test func deletedTrailingColumnClampsSelection() throws {
        var model = try #require(MarkdownTableModel.parse("""
        | A | B | C |
        | --- | --- | --- |
        | one | two | three |
        """))

        #expect(model.deleteColumn(2) == 1)
        #expect(model.columnCount == 2)
    }

    // MARK: - Alignment

    @Test func setsColumnAlignmentAndSerializesDelimiter() throws {
        var model = try #require(MarkdownTableModel.parse("""
        | A | B |
        | --- | --- |
        | one | two |
        """))

        model.setAlignment(.center, forColumn: 0)
        model.setAlignment(.right, forColumn: 1)
        model.setAlignment(.left, forColumn: 9)   // out of range → ignored

        #expect(model.alignments == [.center, .right])
        #expect(model.serialized() == """
        | A | B |
        | :---: | ---: |
        | one | two |
        """)
    }
}
