import Foundation
import Testing
@testable import MarkdownEngine

/// The parse layers keep one memo each for the document. A cell's or one
/// block's text must not replace it, or the document's next parse after an
/// edit takes the full path (2.4 s on a 5 MB note instead of a few ms).
@Suite("Fragment parses keep the document memo")
struct FragmentParseMemoTests {
    @Test("tokenizing a cell's text leaves the document's tokenizer, AST and block memos in place")
    func fragmentKeepsDocumentMemo() {
        let document = String(repeating: "Some **bold** text and a [link](https://e.com).\n\n", count: 200)
            + "| A | B |\n| --- | --- |\n| a | b |\n"
        let length = (document as NSString).length
        // The memos are process-wide and other suites parse in parallel: an
        // attempt counts only when nothing else parsed in between. A fragment
        // that replaced the memo would fail every attempt.
        var kept = false
        for _ in 0..<500 where !kept {
            _ = MarkdownTokenizer.parseTokensViaAST(in: document)
            let cell = MarkdownTokenizer.parseTokensViaAST(in: "**cell** text", memoizing: false)
            #expect(cell.contains { $0.kind == .bold })
            kept = MarkdownTokenizer.memoizedDocumentLength == length && DocumentAST.memoizedLength == length
                && BlockParser.memoizedLength == length
        }
        #expect(kept)
    }
}
