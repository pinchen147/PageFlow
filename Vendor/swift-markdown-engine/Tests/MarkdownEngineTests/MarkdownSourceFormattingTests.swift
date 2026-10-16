import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Source format commands")
struct MarkdownSourceFormattingTests {
    private func applying(_ edit: MarkdownSourceEdit?, to text: String) -> String {
        guard let edit else { return text }
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    private func range(of needle: String, in text: String) -> NSRange {
        (text as NSString).range(of: needle)
    }

    @Test("bullets toggle on every selected line, then off")
    func bulletsToggle() {
        let text = "one\ntwo\n\nafter"
        let selection = range(of: "one\ntwo", in: text)
        let on = applying(MarkdownSourceFormatting.toggle(.bullet, in: text as NSString, selection: selection), to: text)
        #expect(on == "- one\n- two\n\nafter")
        let off = applying(MarkdownSourceFormatting.toggle(.bullet, in: on as NSString,
                                                           selection: range(of: "- one\n- two", in: on)), to: on)
        #expect(off == text)
    }

    @Test("a list command on an empty line starts an empty item, the caret after its marker")
    func emptyLineStartsAnItem() {
        let text = "Intro\n\n\nAfter"
        let caret = NSRange(location: 7, length: 0)
        for (marker, prefix) in [(MarkdownSourceFormatting.LineMarker.task, "- [ ] "), (.bullet, "- "), (.number, "1. ")] {
            let edit = MarkdownSourceFormatting.toggle(marker, in: text as NSString, selection: caret)
            #expect(applying(edit, to: text) == "Intro\n\n\(prefix)\nAfter")
            #expect(edit?.selection == NSRange(location: 7 + prefix.utf16.count, length: 0))
        }
    }

    @Test("a list takes a heading's text and goes inside a quote; toggling off keeps the quote")
    func headingsAndQuotes() {
        let heading = "# Plan\n"
        #expect(applying(MarkdownSourceFormatting.toggle(.task, in: heading as NSString, selection: NSRange(location: 3, length: 0)),
                         to: heading) == "- [ ] Plan\n")
        let quote = "> Buy milk\n"
        let listed = applying(MarkdownSourceFormatting.toggle(.task, in: quote as NSString, selection: NSRange(location: 4, length: 0)),
                              to: quote)
        #expect(listed == "> - [ ] Buy milk\n")
        #expect(applying(MarkdownSourceFormatting.toggle(.task, in: listed as NSString, selection: NSRange(location: 9, length: 0)),
                         to: listed) == "> Buy milk\n")
    }

    @Test("numbering counts up, keeps indentation and replaces bullets")
    func numberingReplacesBullets() {
        let text = "- a\n  - b\nc"
        let result = applying(MarkdownSourceFormatting.toggle(.number, in: text as NSString,
                                                              selection: NSRange(location: 0, length: (text as NSString).length)), to: text)
        #expect(result == "1. a\n  2. b\n3. c")
    }

    @Test("quote marks blank lines too and toggles off")
    func quoteToggle() {
        let text = "a\n\nb"
        let all = NSRange(location: 0, length: (text as NSString).length)
        let on = applying(MarkdownSourceFormatting.toggle(.quote, in: text as NSString, selection: all), to: text)
        #expect(on == "> a\n>\n> b")
        let off = applying(MarkdownSourceFormatting.toggle(.quote, in: on as NSString,
                                                           selection: NSRange(location: 0, length: (on as NSString).length)), to: on)
        #expect(off == text)
    }

    @Test("a selection ending at a line start leaves that line alone")
    func selectionEndingAtLineStart() {
        let text = "one\ntwo"
        let result = applying(MarkdownSourceFormatting.toggle(.bullet, in: text as NSString,
                                                              selection: NSRange(location: 0, length: 4)), to: text)
        #expect(result == "- one\ntwo")
    }

    @Test("inline code wraps, widens around backticks, and unwraps")
    func inlineCode() {
        let text = "say hello now"
        let wrapped = applying(MarkdownSourceFormatting.toggleCode(in: text as NSString,
                                                                   selection: range(of: "hello", in: text)), to: text)
        #expect(wrapped == "say `hello` now")
        let unwrapped = applying(MarkdownSourceFormatting.toggleCode(in: wrapped as NSString,
                                                                     selection: range(of: "hello", in: wrapped)), to: wrapped)
        #expect(unwrapped == text)
        let ticks = "use a`b here"
        #expect(applying(MarkdownSourceFormatting.toggleCode(in: ticks as NSString,
                                                             selection: range(of: "a`b", in: ticks)), to: ticks) == "use ``a`b`` here")
    }

    @Test("several lines toggle a fenced block")
    func fencedBlock() {
        let text = "x\ny\nafter"
        let on = applying(MarkdownSourceFormatting.toggleCode(in: text as NSString,
                                                              selection: range(of: "x\ny", in: text)), to: text)
        #expect(on == "```\nx\ny\n```\nafter")
        let off = applying(MarkdownSourceFormatting.toggleCode(in: on as NSString,
                                                               selection: range(of: "```\nx\ny\n```", in: on)), to: on)
        #expect(off == text)
    }

    @Test("a link wraps text, or takes a selected URL as its destination")
    func link() {
        let text = "see docs here"
        let edit = MarkdownSourceFormatting.insertLink(in: text as NSString, selection: range(of: "docs", in: text))
        #expect(applying(edit, to: text) == "see [docs]() here")
        #expect(edit.selection == NSRange(location: 11, length: 0))
        let url = "go https://x.y now"
        let urlEdit = MarkdownSourceFormatting.insertLink(in: url as NSString, selection: range(of: "https://x.y", in: url))
        #expect(applying(urlEdit, to: url) == "go [](https://x.y) now")
        #expect(urlEdit.selection == NSRange(location: 4, length: 0))
        let empty = MarkdownSourceFormatting.insertLink(in: "" as NSString, selection: NSRange(location: 0, length: 0))
        #expect(empty.replacement == "[]()" && empty.selection == NSRange(location: 1, length: 0))
    }
}
