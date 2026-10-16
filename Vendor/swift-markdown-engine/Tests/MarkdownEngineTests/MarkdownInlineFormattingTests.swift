//
//  MarkdownInlineFormattingTests.swift
//  MarkdownEngineTests
//
//  Source-level formatting commands used by the native text view.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Markdown inline formatting commands")
struct MarkdownInlineFormattingTests {

    private func r(_ location: Int, _ length: Int) -> NSRange {
        NSRange(location: location, length: length)
    }

    private func plan(_ text: String, _ range: NSRange, _ style: MarkdownInlineStyle) -> MarkdownInlineFormatPlan? {
        MarkdownInlineFormatter.plan(
            text: text as NSString,
            targetRange: range,
            style: style,
            tokens: MarkdownTokenizer.parseTokensViaAST(in: text)
        )
    }

    @Test("bold wraps selected text")
    func boldWrapsSelection() {
        #expect(plan("hello", r(0, 5), .bold) == MarkdownInlineFormatPlan(
            replacementRange: r(0, 5),
            replacement: "**hello**",
            selectionAfter: r(2, 5),
            actionName: "Bold"
        ))
    }

    @Test("wrapping preserves selected whitespace outside markers")
    func wrapTrimsWhitespace() {
        #expect(plan(" hello ", r(0, 7), .bold) == MarkdownInlineFormatPlan(
            replacementRange: r(0, 7),
            replacement: " **hello** ",
            selectionAfter: r(3, 5),
            actionName: "Bold"
        ))
    }

    @Test("collapsed caret is a no-op — no empty markers spawned")
    func collapsedCaretIsNoOp() {
        // Bare ⌘B / ⌘I / ⌘U with nothing to format must NOT insert empty
        // `****` / `*` / `<u></u>` markers.
        #expect(plan("hello", r(2, 0), .bold) == nil)
        #expect(plan("hello", r(2, 0), .italic) == nil)
        #expect(plan("hello", r(2, 0), .underline) == nil)
    }

    @Test("whitespace-only selection is a no-op")
    func whitespaceSelectionIsNoOp() {
        #expect(plan("a   b", r(1, 3), .bold) == nil)   // the three spaces
        #expect(plan("   ", r(0, 3), .underline) == nil)
    }

    @Test("bold removes whole bold span")
    func boldRemovesWholeSpan() {
        #expect(plan("**hello**", r(2, 5), .bold) == MarkdownInlineFormatPlan(
            replacementRange: r(0, 9),
            replacement: "hello",
            selectionAfter: r(0, 5),
            actionName: "Bold"
        ))
    }

    @Test("bold toggles OFF when the selection wraps the markers too (re-toggle)")
    func boldRemovesWhenSelectionIncludesMarkers() {
        // The whole `**hello**` selected (markers included) — as produced by ⌘A then a
        // second ⌘B — must strip back to `hello`, not wrap into `****hello****`.
        #expect(plan("**hello**", r(0, 9), .bold) == MarkdownInlineFormatPlan(
            replacementRange: r(0, 9),
            replacement: "hello",
            selectionAfter: r(0, 5),
            actionName: "Bold"
        ))
    }

    @Test("a selection that starts with a bold span but reaches past it is mixed: it wraps, never unwraps")
    func selectionStartingWithSpanIsMixed() {
        // `**a:** *b c*` selected whole: the bold span only covers `a:`, so this is a
        // mixed selection — bold the line (inner marker stripped), don't strip `a:`.
        let text = "**a:** *b c*"
        #expect(plan(text, r(0, 12), .bold) == MarkdownInlineFormatPlan(
            replacementRange: r(0, 12),
            replacement: "**a: *b c***",
            selectionAfter: r(2, 8),
            actionName: "Bold"
        ))
        // …and the result IS one bold span, so the next press toggles it back off.
        #expect(plan("**a: *b c***", r(0, 12), .bold)?.replacement == "a: *b c*")
    }

    @Test("a stray delimiter inside the run gets the underscore form, so the parser sees ONE span")
    func strayDelimiterUsesUnderscoreMarkers() {
        // Hard-wrapped prose whose bold closes on the next line leaves `listed**` on
        // this one; `**listed**, off.**` would read as a short bold plus a literal `**`.
        #expect(plan("listed**, off.", r(0, 14), .bold)?.replacement == "__listed**, off.__")
        #expect(plan("listed**, off.", r(0, 14), .italic)?.replacement == "_listed**, off._")
        #expect(plan("with **no replacement", r(0, 21), .bold)?.replacement == "__with **no replacement__")
        // Round trip: the underscore span is the enclosing token next time.
        #expect(plan("__listed**, off.__", r(0, 18), .bold)?.replacement == "listed**, off.")
        // A delimiter that pairs cleanly keeps the star form.
        #expect(plan("x *both* y", r(0, 10), .bold)?.replacement == "**x *both* y**")
    }

    @Test("toggle-off strips same-style spans nested inside the removed span")
    func toggleOffStripsNestedSpans() {
        #expect(plan("*a *b* c*", r(0, 9), .italic) == MarkdownInlineFormatPlan(
            replacementRange: r(0, 9),
            replacement: "a b c",
            selectionAfter: r(0, 5),
            actionName: "Italic"
        ))
    }

    @Test("many runs: style applies to the unstyled runs and leaves styled ones; once all are styled it removes from all")
    func manyRunsFollowTheMixedSelectionRule() {
        let mixed = "**one**\ntwo" as NSString
        let index = { (text: NSString) in
            EnclosingTokenIndex(tokens: MarkdownTokenizer.parseTokensViaAST(in: text as String), style: .bold)
        }
        let applied = MarkdownInlineFormatter.plans(
            text: mixed, targetRanges: [r(0, 7), r(8, 3)], style: .bold, index: index(mixed))
        #expect(applied.map(\.replacementRange) == [r(8, 3)])
        #expect(applied.first?.replacement == "**two**")

        let allBold = "**one**\n**two**" as NSString
        let removed = MarkdownInlineFormatter.plans(
            text: allBold, targetRanges: [r(0, 7), r(8, 7)], style: .bold, index: index(allBold))
        #expect(removed.map(\.replacement) == ["one", "two"])
    }

    @Test("runs never span a line break: a soft-wrapped paragraph yields one run per line")
    func runsSplitAtLineBreaks() {
        let text = "A. The Math\nB. Glossary\nC. Checklists"
        let ns = text as NSString
        let whole = r(0, ns.length)
        let runs = MarkdownInlineFormattingRuns.formattingRuns(
            targetRange: whole,
            blocks: DocumentAST.parse(text, scopedRanges: [whole]),
            clips: [],
            nsText: ns
        )
        #expect(runs == [r(0, 11), r(12, 11), r(24, 13)])
    }

    @Test("bold on a mixed selection strips the inner bold marker and wraps once (no nesting)")
    func boldMixedSelectionWrapsOnceNoNesting() {
        // ⌘A over a span that already contains a lone `**bold**` must NOT wrap verbatim
        // into `**alpha **bold** beta**` (nested → runaway). It strips the inner markers,
        // then wraps once.
        let text = "alpha **bold** beta"
        #expect(plan(text, r(0, (text as NSString).length), .bold) == MarkdownInlineFormatPlan(
            replacementRange: r(0, 19),
            replacement: "**alpha bold beta**",
            selectionAfter: r(2, 15),
            actionName: "Bold"
        ))
    }

    @Test("bold on a selection containing a bold-italic span keeps the italic, no nesting")
    func boldMixedKeepsBoldItalicAsItalic() {
        let text = "x ***both*** y"
        #expect(plan(text, r(0, (text as NSString).length), .bold) == MarkdownInlineFormatPlan(
            replacementRange: r(0, 14),
            replacement: "**x *both* y**",
            selectionAfter: r(2, 10),
            actionName: "Bold"
        ))
    }

    @Test("bold removes one word inside a bold phrase without invalid whitespace markers")
    func boldRemovesOneWordInsidePhrase() {
        #expect(plan("**hello world**", r(8, 5), .bold) == MarkdownInlineFormatPlan(
            replacementRange: r(0, 15),
            replacement: "**hello** world",
            selectionAfter: r(10, 5),
            actionName: "Bold"
        ))
    }

    @Test("underline wraps selected text")
    func underlineWrapsSelection() {
        #expect(plan("abc", r(0, 3), .underline) == MarkdownInlineFormatPlan(
            replacementRange: r(0, 3),
            replacement: "<u>abc</u>",
            selectionAfter: r(3, 3),
            actionName: "Underline"
        ))
    }

    @Test("underline removes whole underline span")
    func underlineRemovesWholeSpan() {
        #expect(plan("<u>abc</u>", r(3, 3), .underline) == MarkdownInlineFormatPlan(
            replacementRange: r(0, 10),
            replacement: "abc",
            selectionAfter: r(0, 3),
            actionName: "Underline"
        ))
    }

    @Test("underline removes selected core and preserves underline on surrounding text")
    func underlineRemovesPartialSpan() {
        #expect(plan("<u>abc</u>", r(4, 1), .underline) == MarkdownInlineFormatPlan(
            replacementRange: r(0, 10),
            replacement: "<u>a</u>b<u>c</u>",
            selectionAfter: r(8, 1),
            actionName: "Underline"
        ))
    }

    @Test("removing bold from a bold italic span preserves italic")
    func removeBoldFromBoldItalicPreservesItalic() {
        #expect(plan("***abc***", r(3, 3), .bold) == MarkdownInlineFormatPlan(
            replacementRange: r(0, 9),
            replacement: "*abc*",
            selectionAfter: r(1, 3),
            actionName: "Bold"
        ))
    }

    @Test("removing bold from part of a bold italic span isolates delimiters")
    func removePartialBoldFromBoldItalic() {
        #expect(plan("***abc***", r(4, 1), .bold) == MarkdownInlineFormatPlan(
            replacementRange: r(0, 9),
            replacement: "***a***_b_***c***",
            selectionAfter: r(8, 1),
            actionName: "Bold"
        ))
    }

    @Test("removing italic from part of a bold italic span isolates delimiters")
    func removePartialItalicFromBoldItalic() {
        #expect(plan("***abc***", r(4, 1), .italic) == MarkdownInlineFormatPlan(
            replacementRange: r(0, 9),
            replacement: "___a___**b**___c___",
            selectionAfter: r(9, 1),
            actionName: "Italic"
        ))
    }

    @Test("UTF-16 ranges stay intact for non-BMP characters")
    func wrapsEmojiSelection() {
        #expect(plan("go 🧪 now", r(3, 2), .bold) == MarkdownInlineFormatPlan(
            replacementRange: r(3, 2),
            replacement: "**🧪**",
            selectionAfter: r(5, 2),
            actionName: "Bold"
        ))
    }
}

@Suite("Formatting hot-path helpers")
struct FormattingHotPathTests {
    private func r(_ location: Int, _ length: Int) -> NSRange { NSRange(location: location, length: length) }

    @Test("clipsTouching returns exactly the sorted clips that overlap or abut the line")
    func clipsTouching() {
        let clips = [r(0, 3), r(10, 5), r(20, 2), r(40, 4)]
        #expect(MarkdownInlineFormattingRuns.clipsTouching(r(12, 10), in: clips) == [r(10, 5), r(20, 2)])
        #expect(MarkdownInlineFormattingRuns.clipsTouching(r(3, 7), in: clips) == [])          // ends where a clip starts
        #expect(MarkdownInlineFormattingRuns.clipsTouching(r(2, 1), in: clips) == [r(0, 3)])
        #expect(MarkdownInlineFormattingRuns.clipsTouching(r(50, 5), in: clips) == [])
        #expect(MarkdownInlineFormattingRuns.clipsTouching(r(0, 100), in: clips) == clips)
    }

    @Test("a hidden run is kerned out by at least its laid-out width")
    func hiddenRunWidthBoundsTheLaidOutWidth() {
        let font = NSFont.systemFont(ofSize: 1)
        for text in ["| a | b |\n|---|---|\n| **x** | $y$ |", "R_d(r) = \\frac{a}{b}", "中文 mixed ascii", "x"] {
            #expect(HeadingHelpers.hiddenRunWidth(text, font: font) + 0.01 >= HeadingHelpers.textWidth(text, font: font), Comment(rawValue: text))
        }
    }

    @Test("auto-links: a domain in prose is still linked, a full stop or abbreviation is not scanned")
    func autoLinkPrefilterKeepsRealLinks() {
        let text = "See example.com now.\n\nPlain prose e.g. this ends. Next\n\nmail me@site.org today"
        let attrs = MarkdownASTStyler.styleAttributes(text: text, fontName: NSFont.systemFont(ofSize: 14).fontName, fontSize: 14)
        let ns = text as NSString
        let linked = attrs.filter { $0.attributes[.link] != nil }.map { ns.substring(with: $0.range) }
        #expect(linked.contains("example.com"))
        #expect(linked.contains("me@site.org"))
        #expect(!linked.contains { $0.contains("e.g") })
    }

    @Test("a www. link destination opens on the web; other schemeless links stay literal")
    func bareWWWLinkGetsAScheme() {
        let text = "[site](www.example.com) and [note](other.md) and [mail](mailto:a@b.c)"
        let attrs = MarkdownASTStyler.styleAttributes(text: text, fontName: NSFont.systemFont(ofSize: 14).fontName, fontSize: 14)
        let urls = attrs.compactMap { $0.attributes[.link] as? URL }.map(\.absoluteString)
        #expect(urls.contains("https://www.example.com"))
        #expect(urls.contains("other.md"))
        #expect(urls.contains("mailto:a@b.c"))
    }

    @Test("a whole-document parse is memoized: the same text parses once")
    func documentParseMemo() {
        let text = (1...200).map { "Paragraph \($0) with **bold** and `code` and [l](https://x.y)." }.joined(separator: "\n\n")
        let first = DocumentAST.parse(text)
        let again = DocumentAST.parse(text, scopedRanges: [NSRange(location: 0, length: (text as NSString).length)])
        #expect(first == again)
        let scoped = DocumentAST.parse(text, scopedRanges: [NSRange(location: 0, length: 40)])
        #expect(scoped.count < first.count)   // a small scope still builds only its blocks
    }

    @Test("a near-whole scope parsed first memoizes every block, not just the scoped ones")
    func nearWholeScopeMemoKeepsAllBlocks() {
        // A unique heading keeps this text out of any memo another test left behind.
        let text = "# Memo \(UUID().uuidString)\n\n" + String(repeating: "Body sentence long enough to dominate. ", count: 30)
        let ns = text as NSString
        let paragraph = ns.range(of: "Body")
        let scope = NSRange(location: paragraph.location, length: ns.length - paragraph.location)
        _ = DocumentAST.parse(text, scopedRanges: [scope])   // ≥ 90 % coverage → memoized as whole
        let memoized = DocumentAST.parse(text)
        #expect(memoized.contains { if case .heading = $0 { return true } else { return false } })
        #expect(memoized.count == BlockParser.parse(text).count)
    }
}
