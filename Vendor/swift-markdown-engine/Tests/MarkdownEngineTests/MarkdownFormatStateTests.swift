import Foundation
import Testing
@testable import MarkdownEngine

/// the reference editor's pressed-state rules on Markdown source (doc 24 §6.4).
@Suite("Markdown format state")
struct MarkdownFormatStateTests {
    private func state(_ source: String, _ selected: String, occurrence: Int = 0) -> MarkdownFormatState {
        let ns = source as NSString
        var range = ns.range(of: selected)
        for _ in 0..<occurrence {
            range = ns.range(of: selected, range: NSRange(location: NSMaxRange(range), length: ns.length - NSMaxRange(range)))
        }
        return state(source, range)
    }

    private func state(_ source: String, _ range: NSRange) -> MarkdownFormatState {
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: source)
        let code = tokens.filter { $0.kind == .codeBlock || $0.kind == .inlineCode }
        return MarkdownFormatStateCalculator.state(text: source as NSString, tokens: tokens, codeTokens: code,
                                                   selection: range, isEditable: true)
    }

    @Test("'ost' in '## Post' gives H2 with Bold off")
    func headingLabel() {
        let s = state("Intro\n\n## Post\n\nTail", "ost")
        #expect(s.textStyle == .heading(2))
        #expect(!s.bold)
        #expect(s.context == .text)
    }

    @Test("a paragraph, a bold line, three bullets and a heading: Aa, List pressed")
    func multiBlock() {
        let source = "First paragraph\n**bold line**\n- one\n- two\n- three\n## Heading"
        let s = state(source, NSRange(location: 2, length: (source as NSString).length - 4))
        #expect(s.textStyle == nil)
        #expect(s.listPressed == .bulleted)
        #expect(s.listChecked == .bulleted)
        #expect(s.showsIndentRows)
        #expect(!s.bold)
    }

    @Test("the last touched block names the text style")
    func lastBlockRule() {
        let source = "Para\n## H"
        #expect(state(source, NSRange(location: 1, length: 7)).textStyle == .heading(2))
        #expect(state("## H\nPara", NSRange(location: 3, length: 4)).textStyle == .text)
    }

    @Test("marks are on only at full coverage of the visible text")
    func binaryMarks() {
        #expect(!state("**ab** cd", "**ab** cd").bold)
        #expect(state("**abcd**", "abcd").bold)
        #expect(state("x **abcd** y", "**abcd**").bold, "delimiters do not count")
        #expect(state("***both***", "both").bold && state("***both***", "both").italic)
        #expect(state("a ~~gone~~ b", "gone").strikethrough)
        #expect(state("a `code` b", "code").code)
        #expect(state("see [docs](https://e.com) now", "docs").link)
        #expect(!state("see [docs](https://e.com) now", "see docs").link)
        #expect(state("<u>under</u>", "under").underline)
        #expect(state("**ab** ", "**ab** ").bold, "edge whitespace is not required")
    }

    @Test("a selection starting in a list presses List; the menu ✓ needs one shared kind")
    func listRules() {
        let source = "- bullet\n1. number"
        let s = state(source, NSRange(location: 3, length: 12))
        #expect(s.listPressed == .bulleted)
        #expect(s.listChecked == nil)
        let tasks = state("- [ ] task\n- [x] done", NSRange(location: 7, length: 10))
        #expect(tasks.listPressed == .checklist)
        let mixed = state("plain\n1. one\n2. two", NSRange(location: 1, length: 15))
        #expect(mixed.listPressed == .numbered && mixed.listChecked == .numbered)
    }

    @Test("a selection in a fenced code block is a code context")
    func codeBlockContext() {
        let s = state("Text\n\n```swift\nlet x = 1\n```\n", "let x")
        #expect(s.context == .codeBlock)
    }

    @Test("a caret inside bold reads Bold on; a caret in prose reads off")
    func caretState() {
        let source = "plain **bold** text"
        #expect(state(source, NSRange(location: 9, length: 0)).bold)
        #expect(!state(source, NSRange(location: 2, length: 0)).bold)
        #expect(state(source, NSRange(location: 9, length: 0)).context == .none)
    }

    @Test("parsed tokens are sorted by location, which the binary search relies on")
    func tokensSorted() throws {
        var source = ""
        for i in 0..<400 {
            source += "Paragraph \(i) with **bold**, *it*, `code` and [l](u).\n\n"
            if i % 40 == 0 { source += "```\ncode \(i)\n```\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n- item\n- item\n\n" }
        }
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: source)
        #expect(zip(tokens, tokens.dropFirst()).allSatisfy { $0.range.location <= $1.range.location })
    }
}
