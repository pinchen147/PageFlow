import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Table source spans")
struct MarkdownTableScannerTests {
    @Test("line endings, padding, Unicode and empty cells retain absolute source spans", arguments: ["\n", "\r\n", "\r", ""])
    func sourceSpans(lineEnding: String) throws {
        let prefix = "😀 before\r\n"
        let line = " \t|  e\u{301} 🧭  | \t | a\\|b |  " + lineEnding
        let source = (prefix + line + "after") as NSString
        let lineRange = NSRange(location: prefix.utf16.count, length: line.utf16.count)
        let row = try #require(MarkdownTableScanner.scan(inLine: lineRange, of: source))

        #expect(row.lineRange == lineRange)
        #expect(source.substring(with: row.contentRange) == " \t|  e\u{301} 🧭  | \t | a\\|b |  ")
        #expect(source.substring(with: row.lineEndingRange) == lineEnding)
        #expect(NSMaxRange(row.contentRange) == row.lineEndingRange.location)
        #expect(NSMaxRange(row.lineEndingRange) == NSMaxRange(lineRange))
        #expect(row.leadingPipeRange == NSRange(location: prefix.utf16.count + 2, length: 1))
        #expect(row.trailingPipeRange == NSRange(location: NSMaxRange(lineRange) - lineEnding.utf16.count - 3, length: 1))
        #expect(row.cells.map { source.substring(with: $0.rawRange) } == ["  e\u{301} 🧭  ", " \t ", " a\\|b "])
        #expect(row.cells.map { source.substring(with: $0.contentRange) } == ["e\u{301} 🧭", "", "a\\|b"])
        #expect(row.cells[0].contentRange == NSRange(location: prefix.utf16.count + 5, length: 5))
        #expect(row.cells[1].contentRange == NSRange(location: row.cells[1].rawRange.location + 3, length: 0))
    }

    @Test("structural pipes respect escape parity at both borders and inside cells")
    func escapedBordersAndEmptyColumns() {
        let cases: [(String, [String])] = [
            (#"| a | b\|"#, ["a", #"b\|"#]),
            (#"| a | b\\|"#, ["a", #"b\\"#]),
            (#"| a | b\\\|"#, ["a", #"b\\\|"#]),
            (#"\|a | b"#, [#"\|a"#, "b"]),
            (#"\\|a | b"#, [#"\\"#, "a", "b"]),
            ("| a || c |", ["a", "", "c"]),
            ("| a | |", ["a", ""]),
            ("| a |", ["a"]),
            ("a |", ["a"]),
            ("| a", ["a"]),
            ("||", [""]),
            ("|", [""])
        ]
        for (line, expected) in cases {
            let source = line as NSString
            let ranges = MarkdownTableScanner.cellContentRanges(inLine: NSRange(location: 0, length: source.length), of: source)
            #expect(ranges.map { source.substring(with: $0) } == expected, "\(line)")
        }
        #expect(MarkdownTableScanner.cellStrings(in: #"| a | b\|"#) == ["a", "b|"])
        #expect(!MarkdownTableScanner.isTableRow(#"a\|b"#))
    }

    @Test("explicit, missing and overflow body cells remain distinguishable")
    func raggedRowsKeepEverySourceCell() throws {
        let cases: [(String, [String])] = [
            ("one |", ["one"]),
            ("one | |", ["one", ""]),
            ("one || three | extra", ["one", "", "three", "extra"])
        ]
        for (line, expected) in cases {
            let source = line as NSString
            let row = try #require(MarkdownTableScanner.scan(inLine: NSRange(location: 0, length: source.length), of: source))
            #expect(row.cells.map { source.substring(with: $0.contentRange) } == expected)
        }
    }

    @Test("GFM delimiter cells need one hyphen with optional edge colons",
          arguments: ["|-|-|", "| :-: | -: |", "| -- | -- |", "-|-", "|:---|---:|"])
    func shortDelimitersStartATable(_ separator: String) {
        #expect(MarkdownTableScanner.isTableStart(header: "| h | i |", separator: separator))
        let blocks = BlockParser.parse("| h | i |\n\(separator)\n| 1 | 2 |")
        #expect(blocks.map(\.kind) == [.table])
    }

    @Test("an inner colon, a hyphenless cell or a list-marker row is not a delimiter", arguments: ["|-:-|---|", "|::|---|", "| : | --- |", "- | -", "  -\t| ---"])
    func malformedDelimitersAreRejected(_ separator: String) {
        #expect(!MarkdownTableScanner.isTableStart(header: "| h | i |", separator: separator))
    }
}
