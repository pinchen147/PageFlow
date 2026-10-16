//
//  ASTPipelineTests.swift
//  MarkdownEngineTests
//
//  Phase 2.5 — end-to-end checks that the full AST pipeline (BlockParser +
//  InlineParser + adapter) fixes the bugs the characterization latch pinned.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Phase 2.5 — AST pipeline end-to-end")
struct ASTPipelineTests {

    @Test("bug 2: no inline markup tokens inside a fenced code block")
    func bug2InlineInsideCode() {
        let text = "```swift\n*not italic* `not code`\n```\n"
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        #expect(!tokens.isEmpty)
        #expect(tokens.allSatisfy { $0.kind == .codeBlock })
    }

    @Test("bug 4: a link with balanced parens in the URL is one whole link token")
    func bug4LinkParens() {
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: "see [w](a(b)) end")
        let link = tokens.first { $0.kind == .link }
        #expect(link?.range == NSRange(location: 4, length: 9))
    }

    @Test("bug 3: no spurious latex token across code spans")
    func bug3CrossCodeLatex() {
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: "the `$a` and `$b` vars")
        #expect(!tokens.contains { $0.kind == .inlineLatex })
        #expect(tokens.filter { $0.kind == .inlineCode }.count == 2)
    }

    @Test("block-level tokens are preserved (heading + emphasis in the title)")
    func headingPlusInline() {
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: "# Title *x*")
        #expect(tokens.contains { $0.kind == .heading })
        #expect(tokens.contains { $0.kind == .italic })
    }

    @Test("table recognition agrees across blocks, tokens and display model")
    func tableRecognitionAgrees() {
        let cases: [(String, Bool)] = [
            ("| A |\n| --- |\n| body |", true),
            ("A |\r\n--- |\r\nbody |", true),
            ("| A\r| ---\r| body", true),
            ("A | B\n--- | ---\none | two", true),
            ("| A | B |\n| --- |\n| body |", false),
            ("| A |\n| --- | --- |\n| body |", false),
            ("| A | B |\n| --- | --- | --- |\n| body |", false),
            ("| A | B | C |\n| --- | --- |\n| body |", false),
            ("| A |\n| - |", true),
            ("A | B\n- | -", false)
        ]
        for (source, expected) in cases {
            #expect(BlockParser.parse(source).contains { $0.kind == .table } == expected, "\(source)")
            #expect(MarkdownTokenizer.parseTokensViaAST(in: source).contains { $0.kind == .table } == expected, "\(source)")
            #expect((MarkdownTableModel.parse(source) != nil) == expected, "\(source)")
        }
    }

}
