//
//  MarkdownASTStylerTests.swift
//  MarkdownEngineTests
//
//  Phase 2.5b — the AST styler composes nested/combined inline styles instead
//  of overwriting them (the flat 18-pass styler's flaw).
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Phase 2.5b — AST styler font composition")
struct MarkdownASTStylerTests {

    private let base: CGFloat = 14
    private var fontName: String { NSFont.systemFont(ofSize: 14).fontName }

    /// Effective font at `pos`: the last styled range covering it that sets `.font`.
    private func font(in attrs: [StyledRange], at pos: Int) -> NSFont? {
        var result: NSFont?
        for (range, a) in attrs where NSLocationInRange(pos, range) {
            if let f = a[.font] as? NSFont { result = f }
        }
        return result
    }

    private func attribute(_ key: NSAttributedString.Key, in attrs: [StyledRange], at pos: Int) -> Any? {
        var result: Any?
        for (range, a) in attrs where NSLocationInRange(pos, range) {
            if let value = a[key] { result = value }
        }
        return result
    }

    /// Per-keystroke perf: scoping a restyle to the edited paragraph must produce
    /// the EXACT same attributes within that paragraph as a full-document style.
    /// This is the safety net for the `scopedRanges` fast path — it can't diverge
    /// from the full rebuild (no glitch).
    @MainActor
    @Test("scoped styling == full styling, clipped to the edited paragraph")
    func scopedMatchesFullForEditedParagraph() {
        _ = NSApplication.shared
        let text = "plain one\n\n**bold** in two `code`\n\n- item *x*\n\nhttps://example.com"
        let ns = text as NSString
        let para = ns.paragraphRange(for: NSRange(location: 13, length: 0))   // the `**bold**…` line
        func keys(_ scoped: [NSRange]?) -> String {
            let r = MarkdownASTStyler.styleAttributes(
                text: text, fontName: fontName, fontSize: base, scopedRanges: scoped
            ).filter { NSIntersectionRange($0.range, para).length > 0 }
            return styleKeySnapshot(r)
        }
        #expect(keys([para]) == keys(nil))
    }

    @Test("bold inside a heading stays heading-size and consistent (fixes # **n*o*des**)")
    func headingBoldComposesToHeadingSize() {
        let attrs = MarkdownASTStyler.styleAttributes(text: "# **n*o*des**", fontName: fontName, fontSize: base)
        // "# **n*o*des**": n=4, o=6, d=8
        let n = font(in: attrs, at: 4)
        let o = font(in: attrs, at: 6)
        let d = font(in: attrs, at: 8)

        // The fix: every emphasized char is the SAME (heading) size — not "o" big, "n/des" small.
        #expect(n?.pointSize == o?.pointSize)
        #expect(n?.pointSize == d?.pointSize)
        #expect((n?.pointSize ?? 0) > base)   // heading-size, not base

        // Correct composed traits.
        #expect(n?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(d?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(o?.fontDescriptor.symbolicTraits.contains([.bold, .italic]) == true)
    }

    @Test("nested emphasis in a paragraph composes bold+italic")
    func paragraphNestedEmphasis() {
        let attrs = MarkdownASTStyler.styleAttributes(text: "**a *b* c**", fontName: fontName, fontSize: base)
        // "**a *b* c**": a=2, b=5, c=8
        let a = font(in: attrs, at: 2)
        let b = font(in: attrs, at: 5)
        #expect(a?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(a?.fontDescriptor.symbolicTraits.contains(.italic) == false)
        #expect(b?.fontDescriptor.symbolicTraits.contains([.bold, .italic]) == true)
    }

    @Test("underline applies underline style to content")
    func underlineAppliesStyle() {
        let attrs = MarkdownASTStyler.styleAttributes(text: "<u>x</u>", fontName: fontName, fontSize: base)
        #expect(attribute(.underlineStyle, in: attrs, at: 3) as? Int == NSUnderlineStyle.single.rawValue)
    }

    @Test("underline composes with nested emphasis")
    func underlineComposesWithNestedEmphasis() {
        let attrs = MarkdownASTStyler.styleAttributes(text: "<u>*x*</u>", fontName: fontName, fontSize: base)
        let x = font(in: attrs, at: 4)
        #expect(attribute(.underlineStyle, in: attrs, at: 4) as? Int == NSUnderlineStyle.single.rawValue)
        #expect(x?.fontDescriptor.symbolicTraits.contains(.italic) == true)
    }

    /// Code is not prose: fenced blocks and inline `code` spans must carry
    /// `.spellingState: 0` so the system spell-checker leaves them alone,
    /// matching the existing convention that links / wiki-links / LaTeX / tables
    /// already follow.
    @Test("a revealed table styles bold, italic and underline inside its cells")
    func revealedTableCellsStyleInlineMarkup() throws {
        let text = "| a | b |\n|---|---|\n| **c** | <u>d</u> |\n| *e* | f |"
        let ns = text as NSString
        let caret = ns.range(of: "f").location
        let attrs = MarkdownASTStyler.styleAttributes(text: text, fontName: fontName, fontSize: base, caretLocation: caret)
        let c = ns.range(of: "c").location, d = ns.range(of: "d").location, e = ns.range(of: "e").location
        let bold = try #require(font(in: attrs, at: c))
        #expect(bold.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(attribute(.underlineStyle, in: attrs, at: d) as? Int == NSUnderlineStyle.single.rawValue)
        let italic = try #require(font(in: attrs, at: e))
        #expect(italic.fontDescriptor.symbolicTraits.contains(.italic))
        // The caret is in another cell, so the `**` markers around c are hidden.
        let marker = try #require(font(in: attrs, at: c - 1))
        #expect(marker.pointSize < 1)
    }

    @Test("a rendered table (caret outside) gets no inline styling from the AST styler")
    func renderedTableCellsAreLeftToTheImagePass() {
        let text = "intro\n\n| a | b |\n|---|---|\n| **c** | <u>d</u> |"
        let ns = text as NSString
        let attrs = MarkdownASTStyler.styleAttributes(text: text, fontName: fontName, fontSize: base, caretLocation: 0)
        let table = ns.range(of: "| a | b |").location
        #expect(!attrs.contains { $0.range.location >= table && ($0.attributes[.font] != nil || $0.attributes[.underlineStyle] != nil) })
    }

    @Test("math source never gets link colouring: `\\Big[ … \\Big]` is not an incomplete link")
    func mathIsOpaqueToTheLinkPasses() {
        let text = "intro\n\n$$\\Big[ z_r(1+d) \\Big], \\qquad x$$\n\ninline $[a](b$ tail"
        let ns = text as NSString
        let attrs = MarkdownASTStyler.styleAttributes(text: text, fontName: fontName, fontSize: base, caretLocation: 0)
        let block = ns.range(of: "$$\\Big")
        let inline = ns.range(of: "$[a](b$")
        let blockEnd = ns.range(of: "x$$").location + 3
        for (range, a) in attrs where a[.foregroundColor] != nil || a[.link] != nil {
            let inBlock = range.location >= block.location && NSMaxRange(range) <= blockEnd
            let inInline = NSIntersectionRange(range, inline).length > 0
            #expect(!inBlock && !inInline, "link pass painted \(range) \(ns.substring(with: range))")
        }
    }

    @Test("hidden fence rows shrink to the block padding; revealed ones are full code lines")
    func fenceRowsCollapseWhenTheCaretIsOutside() {
        let text = "prose\n\n```swift\nlet x = 1\n```\n\ntail"
        let ns = text as NSString
        let openFence = ns.range(of: "```swift").location
        let closeFence = ns.range(of: "```", options: .backwards).location
        let code = ns.range(of: "let x").location
        let hidden = MarkdownEditorConfiguration.default.codeBlock.hiddenFenceHeight

        let outside = MarkdownASTStyler.styleAttributes(text: text, fontName: fontName, fontSize: base, caretLocation: 0)
        let openStyle = try? #require(attribute(.paragraphStyle, in: outside, at: openFence) as? NSParagraphStyle)
        let closeStyle = try? #require(attribute(.paragraphStyle, in: outside, at: closeFence) as? NSParagraphStyle)
        let codeStyle = try? #require(attribute(.paragraphStyle, in: outside, at: code) as? NSParagraphStyle)
        #expect(openStyle?.maximumLineHeight == hidden && openStyle?.minimumLineHeight == hidden)
        #expect(closeStyle?.maximumLineHeight == hidden && closeStyle?.minimumLineHeight == hidden)
        #expect(openStyle?.paragraphSpacing == 0, "no gap between the opening fence and the code")
        #expect(closeStyle?.paragraphSpacingBefore == 0, "no gap between the code and the closing fence")
        #expect(openStyle?.headIndent == codeStyle?.headIndent, "the fence row keeps the block's indent")
        #expect((codeStyle?.maximumLineHeight ?? 0) > hidden, "code lines keep their height")
        let hiddenFont = font(in: outside, at: openFence)
        #expect((hiddenFont?.pointSize ?? 99) <= hidden, "a hidden fence's glyph run must fit inside its row (no background poking out)")

        let inside = MarkdownASTStyler.styleAttributes(text: text, fontName: fontName, fontSize: base, caretLocation: code)
        let revealed = try? #require(attribute(.paragraphStyle, in: inside, at: openFence) as? NSParagraphStyle)
        #expect(revealed?.maximumLineHeight == codeStyle?.maximumLineHeight, "a revealed fence is a full code line")
        #expect((attribute(.foregroundColor, in: inside, at: openFence) as? NSColor) != NSColor.clear)
    }

    @Test("a hidden block's first code line carries its language; a revealed or unlabeled block does not")
    func languageLabelRidesTheFirstCodeLineWhileHidden() {
        let text = "```swift title=x\nlet x = 1\nlet y = 2\n```\n\n```\nplain\n```"
        let ns = text as NSString
        let firstLine = ns.range(of: "let x").location
        let secondLine = ns.range(of: "let y").location
        let plain = ns.range(of: "plain").location

        let outside = MarkdownASTStyler.styleAttributes(text: text, fontName: fontName, fontSize: base, caretLocation: ns.length)
        #expect(attribute(.codeBlockLanguage, in: outside, at: firstLine) as? String == "swift", "info-string extras are dropped")
        #expect(attribute(.codeBlockLanguage, in: outside, at: secondLine) == nil)
        #expect(attribute(.codeBlockLanguage, in: outside, at: plain) == nil, "no language, no label")

        let inside = MarkdownASTStyler.styleAttributes(text: text, fontName: fontName, fontSize: base, caretLocation: firstLine)
        #expect(attribute(.codeBlockLanguage, in: inside, at: firstLine) == nil, "the revealed fence shows the language itself")
    }

    @Test("code blocks and inline code receive .spellingState: 0; prose does not")
    func codeRegionsSuppressSpellCheck() {
        let text = "prose word\n\n```\nfencedcd notaword\n```\n\nplain `inlnecode` tail"
        let attrs = MarkdownASTStyler.styleAttributes(text: text, fontName: fontName, fontSize: base)
        let ns = text as NSString
        let fencedContent = ns.range(of: "fencedcd notaword")
        let inlineSpan = ns.range(of: "`inlnecode`")
        let prose = ns.range(of: "prose word")

        // Pull every `.spellingState` value from styled ranges that intersect `r`.
        func spellingStates(intersecting r: NSRange) -> [Int] {
            attrs.compactMap { entry -> Int? in
                guard NSIntersectionRange(entry.range, r).length > 0 else { return nil }
                return entry.attributes[.spellingState] as? Int
            }
        }

        #expect(spellingStates(intersecting: fencedContent).contains(0))
        #expect(spellingStates(intersecting: inlineSpan).contains(0))
        #expect(spellingStates(intersecting: prose).isEmpty)
    }
}

/// Canonical, order-independent string of styled ranges so two style runs can be
/// compared for equality.
private func styleKeySnapshot(_ ranges: [StyledRange]) -> String {
    let lines = ranges
        .map { entry -> (NSRange, [String]) in
            (entry.range, entry.attributes.keys.map(\.rawValue).sorted())
        }
        .sorted { a, b in
            if a.0.location != b.0.location { return a.0.location < b.0.location }
            if a.0.length != b.0.length { return a.0.length < b.0.length }
            return a.1.joined(separator: ",") < b.1.joined(separator: ",")
        }
        .map { "@\(fmt($0.0)) keys=[\($0.1.joined(separator: ","))]" }
    return lines.isEmpty ? "(no styled ranges)" : lines.joined(separator: "\n")
}

private func fmt(_ r: NSRange) -> String {
    r.location == NSNotFound ? "∅" : "\(r.location)+\(r.length)"
}
