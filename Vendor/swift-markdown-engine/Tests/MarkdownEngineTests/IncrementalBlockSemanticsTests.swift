import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Incremental block semantics", .serialized)
struct IncrementalBlockSemanticsTests {
    private func signature(_ tokens: [MarkdownToken]) -> [String] {
        tokens.map { "\($0.kind):\($0.range):\($0.contentRange):\($0.markerRanges)" }
    }

    private func compareEdit(in source: String, at offset: Int, deleting length: Int = 0) {
        let changed = (source as NSString).replacingCharacters(
            in: NSRange(location: offset, length: length), with: "\\"
        )
        _ = MarkdownTokenizer.parseTokensViaAST(in: "")
        _ = MarkdownTokenizer.parseTokensViaAST(in: source)
        let incremental = signature(MarkdownTokenizer.parseTokensViaAST(in: changed))
        _ = MarkdownTokenizer.parseTokensViaAST(in: "")
        let fresh = signature(MarkdownTokenizer.parseTokensViaAST(in: changed))
        #expect(incremental == fresh)
    }

    @Test("inline fence-looking runs do not force whole-document tokenization")
    func inlineRunsRemainLocal() {
        for source in ["before ```inline``` after", "before ~~~~inline~~~~ after", "    ```indented code"] {
            let units = Array(source.utf16)
            let range = (source as NSString).range(of: source.contains("~") ? "~~~" : "```")
            #expect(!BlockParser.hasBlockDelimiter(units, range.location, NSMaxRange(range)))
        }
        for source in ["```swift", "   ~~~~", "$$x$$"] {
            let units = Array(source.utf16)
            #expect(BlockParser.hasBlockDelimiter(units, 0, units.count))
        }
    }

    @Test("block math remains opaque to inline escape tokenization after an edit")
    func mathStaysOpaque() {
        compareEdit(in: "before\n\n$$\nx+y\n$$\n\nafter\n", at: 12)
    }

    @Test("table escape edits use cell boundaries in both incremental and fresh parses")
    func tableUsesCellBoundaries() {
        let source = "before\n\n| a | b |\n| --- | --- |\n| x | y |\n\nafter\n"
        for (offset, length) in [(15, 1), (16, 0), (39, 1), (40, 0)] {
            compareEdit(in: source, at: offset, deleting: length)
        }
    }
}
