//
//  MarkdownInlineFormattingShortcutTests.swift
//  MarkdownEngineTests
//
//  Coordinator-level coverage for native formatting shortcuts.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Markdown inline formatting shortcut path")
struct MarkdownInlineFormattingShortcutTests {

    private final class State {
        var text: String
        var isWikiLinkActive = false

        init(text: String) {
            self.text = text
        }
    }

    private func makeCoordinatorAndTextView(text: String) -> (NativeTextViewCoordinator, NativeTextView, State) {
        _ = NSApplication.shared
        let state = State(text: text)
        let coordinator = NativeTextViewCoordinator(
            text: Binding(get: { state.text }, set: { state.text = $0 }),
            fontName: NSFont.systemFont(ofSize: 14).fontName,
            fontSize: 14,
            isWikiLinkActive: Binding(get: { state.isWikiLinkActive }, set: { state.isWikiLinkActive = $0 }),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        textView.string = text
        textView.delegate = coordinator
        coordinator.textView = textView
        _ = coordinator.parsedDocument(for: text)
        return (coordinator, textView, state)
    }

    @Test("bold shortcut uses the inline-formatting fast path")
    func boldShortcutUsesFastPath() {
        let text = largeFixture(target: "target")
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)
        let target = (text as NSString).range(of: "target")

        textView.setSelectedRange(target)
        coordinator.didMarkdownBold(nil)

        #expect(textView.string.contains("**target**"))
        #expect(coordinator.cachedParsedChars?.count == nil)
    }

    @Test("italic shortcut applies to current word")
    func italicShortcutTargetsCurrentWord() {
        let text = largeFixture(target: "cursorword")
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)
        let target = (text as NSString).range(of: "cursorword")

        textView.setSelectedRange(NSRange(location: target.location + 3, length: 0))
        coordinator.didMarkdownItalic(nil)

        #expect(textView.string.contains("*cursorword*"))
        #expect(coordinator.cachedParsedChars?.count == nil)
    }

    @Test("underline shortcut applies raw HTML underline")
    func underlineShortcutUsesHTMLUnderline() {
        let text = largeFixture(target: "underlined")
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)
        let target = (text as NSString).range(of: "underlined")

        textView.setSelectedRange(target)
        coordinator.didMarkdownUnderline(nil)

        #expect(textView.string.contains("<u>underlined</u>"))
        #expect(coordinator.cachedParsedChars?.count == nil)
    }

    @Test("formatting a selected heading wraps the text, not the #### marker")
    func headingSelectionPreservesMarker() {
        let text = largeFixture(target: "#### Level 4")
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)
        let heading = (text as NSString).range(of: "#### Level 4")

        textView.setSelectedRange(heading)
        coordinator.didMarkdownUnderline(nil)

        // The `#### ` marker is protected → the line stays a heading; only the text wraps.
        #expect(textView.string.contains("#### <u>Level 4</u>"))
        #expect(!textView.string.contains("<u>#### "))
    }

    @Test("caret in a heading word wraps the word and keeps the heading")
    func headingCaretWordKeepsHeading() {
        let text = largeFixture(target: "#### Level 4")
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)
        let level = (text as NSString).range(of: "Level")

        textView.setSelectedRange(NSRange(location: level.location + 2, length: 0))
        coordinator.didMarkdownBold(nil)

        #expect(textView.string.contains("#### **Level** 4"))
    }

    @Test("formatting shortcut is ignored inside inline code")
    func formattingInsideInlineCodeIsIgnored() {
        let text = largeFixture(target: "`target`")
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)
        let target = (text as NSString).range(of: "target")

        textView.setSelectedRange(target)
        coordinator.didMarkdownBold(nil)

        #expect(textView.string.contains("`target`"))
        #expect(!textView.string.contains("`**target**`"))
    }

    @Test("formatting shortcut is ignored inside inline LaTeX")
    func formattingInsideInlineLatexIsIgnored() {
        let text = largeFixture(target: "$target$")
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)
        let target = (text as NSString).range(of: "target")

        textView.setSelectedRange(target)
        coordinator.didMarkdownItalic(nil)

        #expect(textView.string.contains("$target$"))
        #expect(!textView.string.contains("$*target*$"))
    }

    @Test("selection spanning interior code/LaTeX makes ONE span, markers outside them")
    func formattingMixedSelectionWrapsOnce() {
        let text = largeFixture(target: "alpha `code` beta $x+y$ gamma")
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)
        let target = (text as NSString).range(of: "alpha `code` beta $x+y$ gamma")

        textView.setSelectedRange(target)
        coordinator.didMarkdownBold(nil)

        // Bold spans the interior code/LaTeX (valid CommonMark) instead of fragmenting
        // into `**alpha** \`code\` **beta**`; the `**` never lands inside a code/LaTeX span.
        #expect(textView.string.contains("**alpha `code` beta $x+y$ gamma**"))
        #expect(!textView.string.contains("`**code**`"))
        #expect(!textView.string.contains("$**x+y**$"))
    }

    @Test("blockquote: format wraps the content, not the > marker")
    func blockquoteSingleLine() {
        let text = largeFixture(target: "> A blockquote here")
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)
        let line = (text as NSString).range(of: "> A blockquote here")

        textView.setSelectedRange(line)
        coordinator.didMarkdownBold(nil)

        #expect(textView.string.contains("> **A blockquote here**"))
        #expect(!textView.string.contains("**> "))
    }

    @Test("multi-line blockquote: each line's content wraps, markers intact")
    func blockquoteMultiLine() {
        let text = largeFixture(target: "> first line\n> second line")
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)
        let quote = (text as NSString).range(of: "> first line\n> second line")

        textView.setSelectedRange(quote)
        coordinator.didMarkdownBold(nil)

        #expect(textView.string.contains("> **first line**"))
        #expect(textView.string.contains("> **second line**"))
        #expect(!textView.string.contains("**> "))
    }

    @Test("nested blockquote keeps the full >> marker")
    func nestedBlockquote() {
        let text = largeFixture(target: ">> deep quote")
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)
        let line = (text as NSString).range(of: ">> deep quote")

        textView.setSelectedRange(line)
        coordinator.didMarkdownItalic(nil)

        #expect(textView.string.contains(">> *deep quote*"))
        #expect(!textView.string.contains("*>> "))
    }

    @Test("bullet / ordered / task list markers are preserved")
    func listMarkersPreserved() {
        for (item, expected) in [("- a bullet", "- **a bullet**"),
                                 ("1. an ordered", "1. **an ordered**"),
                                 ("- [ ] a task", "- [ ] **a task**")] {
            let text = largeFixture(target: item)
            let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)
            textView.setSelectedRange((text as NSString).range(of: item))
            coordinator.didMarkdownBold(nil)
            #expect(textView.string.contains(expected))
        }
    }

    @Test("toggle off: bold over already-bold text removes the markers")
    func toggleOffBold() {
        let text = largeFixture(target: "**already bold**")
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)
        let inner = (text as NSString).range(of: "already bold")

        textView.setSelectedRange(inner)
        coordinator.didMarkdownBold(nil)

        #expect(textView.string.contains("already bold"))
        #expect(!textView.string.contains("**already bold**"))
    }

    @Test("toggle off when the SELECTION includes the markers (the ⌘A re-press case)")
    func toggleOffWholeSpan() {
        let text = largeFixture(target: "**already bold**")
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)
        let whole = (text as NSString).range(of: "**already bold**")   // markers included

        textView.setSelectedRange(whole)
        coordinator.didMarkdownBold(nil)

        #expect(textView.string.contains("already bold"))
        #expect(!textView.string.contains("**already bold**"))
        #expect(!textView.string.contains("****"))
    }

    @Test("⌘A then ⌘B twice toggles back off — no `****` accumulation")
    func selectAllBoldTwiceTogglesOff() {
        let text = "para one\n\n> a quote\n\n- a bullet\n\n#### a heading"
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)

        textView.setSelectedRange(NSRange(location: 0, length: (text as NSString).length))
        coordinator.didMarkdownBold(nil)
        #expect(textView.string.contains("**para one**"))

        // Re-select everything (now longer, markers included) and bold again → toggles OFF.
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        coordinator.didMarkdownBold(nil)

        #expect(textView.string == text)
        #expect(!textView.string.contains("****"))
    }

    @Test("⌘A bold on a paragraph WITH inline emphasis wraps once and is reversible — no runaway")
    func selectAllBoldMixedIsReversible() {
        // The exact shape from the spike fixture: a paragraph already holding bold / italic /
        // bold-italic / inline code. ⌘A + ⌘B must produce ONE clean bold span (inner markers
        // demoted, never nested), and pressing again must toggle it back OFF.
        let text = "Regular paragraph with **bold**, *italic*, ***both***, and `code` here."
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)

        textView.setSelectedRange(NSRange(location: 0, length: (text as NSString).length))
        coordinator.didMarkdownBold(nil)
        #expect(textView.string == "**Regular paragraph with bold, *italic*, *both*, and `code` here.**")
        #expect(!textView.string.contains("****"))

        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        coordinator.didMarkdownBold(nil)
        #expect(textView.string == "Regular paragraph with bold, *italic*, *both*, and `code` here.")
    }

    @Test("repeated ⌘A bold only oscillates between two states — never accumulates `****`/nesting")
    func repeatedSelectAllBoldOscillates() {
        let text = "Regular paragraph with **bold**, *italic*, ***both***, and `code` here."
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)

        var seen: Set<String> = []
        for _ in 0..<6 {
            textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
            coordinator.didMarkdownBold(nil)
            seen.insert(textView.string)
            #expect(!textView.string.contains("****"))
        }
        // A correct toggle bounces between exactly two strings; a runaway would produce 6.
        #expect(seen.count <= 2)
    }

    @Test("⌘A underline over already-bold text nests validly and toggles back off")
    func selectAllUnderlineOverBoldIsReversible() {
        let text = "keep **this** safe"
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)

        textView.setSelectedRange(NSRange(location: 0, length: (text as NSString).length))
        coordinator.didMarkdownUnderline(nil)
        // Underline doesn't touch the orthogonal bold span; it wraps the whole run once.
        #expect(textView.string == "<u>keep **this** safe</u>")
        #expect(!textView.string.contains("<u><u>"))

        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        coordinator.didMarkdownUnderline(nil)
        #expect(textView.string == "keep **this** safe")
    }

    @Test("⌘A formats each block's content, every marker intact, in one undo step")
    func selectAllPerBlockWrap() {
        let text = "para one\n\n> a quote\n\n- a bullet\n\n#### a heading"
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)

        textView.setSelectedRange(NSRange(location: 0, length: (text as NSString).length))
        coordinator.didMarkdownBold(nil)

        #expect(textView.string.contains("**para one**"))
        #expect(textView.string.contains("> **a quote**"))
        #expect(textView.string.contains("- **a bullet**"))
        #expect(textView.string.contains("#### **a heading**"))
        #expect(!textView.string.contains("**> "))
        #expect(!textView.string.contains("**#### "))
        // (Atomic one-undo-step is guaranteed by the single shouldChangeText(inRanges:)
        // call in applyInlineFormattingPlans; undo itself needs a live first-responder
        // window the headless harness lacks, so it isn't asserted here.)
    }

    @Test("⌘A ⌘U twice on a soft-wrapped paragraph wraps each line and toggles back off — no `<u><u>`")
    func selectAllUnderlineSoftWrappedParagraphTogglesOff() {
        let text = "A. The Math\nB. Glossary\n\n**Part V**"
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)

        textView.setSelectedRange(NSRange(location: 0, length: (text as NSString).length))
        coordinator.didMarkdownUnderline(nil)
        #expect(textView.string == "<u>A. The Math</u>\n<u>B. Glossary</u>\n\n<u>**Part V**</u>")

        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        coordinator.didMarkdownUnderline(nil)
        #expect(textView.string == text)
    }

    @Test("⌘A ⌘B with one line already bold bolds the rest and leaves it; the second press unbolds all")
    func selectAllBoldMixedLinesConverges() {
        let text = "**Part V**\n\nplain line\n\n- item"
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)

        textView.setSelectedRange(NSRange(location: 0, length: (text as NSString).length))
        coordinator.didMarkdownBold(nil)
        #expect(textView.string == "**Part V**\n\n**plain line**\n\n- **item**")

        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        coordinator.didMarkdownBold(nil)
        #expect(textView.string == "Part V\n\nplain line\n\n- item")

        // Deciding per run instead flipped the bold line the other way on every press.
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        coordinator.didMarkdownBold(nil)
        #expect(textView.string == "**Part V**\n\n**plain line**\n\n- **item**")
    }

    @Test("⌘A ⌘B twice on prose hard-wrapped through a bold span toggles off cleanly")
    func selectAllBoldAcrossHardWrappedSpanTogglesOff() {
        // The author's `**…**` closes on the next line; each line holds a stray `**`.
        let text = "deprecated with **no replacement\nlisted**, the app was off."
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)

        textView.setSelectedRange(NSRange(location: 0, length: (text as NSString).length))
        coordinator.didMarkdownBold(nil)
        #expect(textView.string == "__deprecated with **no replacement__\n__listed**, the app was off.__")

        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        coordinator.didMarkdownBold(nil)
        #expect(textView.string == text)
    }

    @Test("⌘A: stack U, B, I then unwind I, B, U returns the document with no marker soup")
    func selectAllStackAndUnwind() {
        let text = """
        # Title

        Line one
        line two

        > **a:** *b c*

        - item **two**

        | a | b |
        |---|---|
        | x | y |
        """
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)
        let press: (MarkdownInlineStyle) -> Void = { style in
            textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
            switch style {
            case .bold: coordinator.didMarkdownBold(nil)
            case .italic: coordinator.didMarkdownItalic(nil)
            case .underline: coordinator.didMarkdownUnderline(nil)
            case .strikethrough, .highlight: coordinator.applyInlineStyle(style)
            }
            for soup in ["<u><u>", "</u></u>", "<u></u>", "****", "<u>*</u>", "<u>**</u>", "<u>***</u>"] {
                #expect(!textView.string.contains(soup), "\(soup) after \(style): \(textView.string)")
            }
        }
        [.underline, .bold, .italic].forEach(press)
        #expect(textView.string.contains("# ***<u>Title</u>***"))
        #expect(textView.string.contains("> ***<u>a: b c</u>***"))
        #expect(textView.string.contains("| ***<u>x</u>*** | ***<u>y</u>*** |"))

        [.italic, .bold, .underline].forEach(press)
        // Every style is off; the pre-existing emphasis went with its style's toggle-off.
        #expect(textView.string == """
        # Title

        Line one
        line two

        > a: b c

        - item two

        | a | b |
        |---|---|
        | x | y |
        """)
    }

    @Test("table cell content can be bolded; pipes and the separator row stay intact")
    func tableCellFormatting() {
        let text = "| Construct | Renders |\n|-----------|---------|\n| Heading   | yes     |"
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)
        textView.setSelectedRange((text as NSString).range(of: "Heading"))
        coordinator.didMarkdownBold(nil)

        #expect(textView.string.contains("| **Heading**   | yes     |"))
        #expect(textView.string.contains("|-----------|---------|"))   // separator untouched
        #expect(!textView.string.contains("**|"))                      // never wraps a pipe
    }

    @Test("formatting inside a table cell shows immediately in the revealed source")
    func tableCellFormattingIsVisibleWhileRevealed() throws {
        let text = "| a | b |\n|---|---|\n| one | two |"
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)
        let storage = try #require(textView.textStorage)

        textView.setSelectedRange((textView.string as NSString).range(of: "one"))
        coordinator.didMarkdownBold(nil)
        var range = (textView.string as NSString).range(of: "one")
        let bold = try #require(storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        #expect(bold.fontDescriptor.symbolicTraits.contains(.bold), "bold cell text must render bold while the table is revealed")

        textView.setSelectedRange((textView.string as NSString).range(of: "two"))
        coordinator.didMarkdownUnderline(nil)
        range = (textView.string as NSString).range(of: "two")
        #expect(textView.string.contains("<u>two</u>"))
        #expect(storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
    }

    @Test("a selection spanning two table cells formats each cell, never the pipe between")
    func tableCrossCellFormatting() {
        let text = "| a | b |\n|---|---|\n| one | two |"
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)
        let across = (text as NSString).range(of: "one | two")
        textView.setSelectedRange(across)
        coordinator.didMarkdownItalic(nil)

        #expect(textView.string.contains("| *one* | *two* |"))
        #expect(!textView.string.contains("*one | two*"))   // not one span across the pipe
    }

    @Test("formatting shortcut is ignored inside fenced code")
    func formattingInsideFencedCodeIsIgnored() {
        let text = largeFixture(target: "```swift\nlet target = 1\n```")
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)
        let target = (text as NSString).range(of: "target")

        textView.setSelectedRange(target)
        coordinator.didMarkdownUnderline(nil)

        #expect(textView.string.contains("let target = 1"))
        #expect(!textView.string.contains("let <u>target</u> = 1"))
    }

    @Test("heading and list commands select the entire Unicode content", arguments: ["😀abc", "𐐀abc", "e\u{301}abc"])
    func blockFormattingPreservesUnicodeSelection(content: String) {
        for heading in [true, false] {
            let (coordinator, textView, _) = makeCoordinatorAndTextView(text: content)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            if heading {
                let item = NSMenuItem()
                item.tag = 1
                coordinator.didMarkdownHeading(item)
            } else {
                coordinator.didMarkdownUnorderedList(nil)
            }
            textView.insertText("replacement", replacementRange: textView.selectedRange())
            #expect(textView.string == (heading ? "# replacement" : "- replacement"))
        }
    }

    @Test("bold uses native boundaries for supplementary-letter words")
    func boldPreservesSupplementaryWord() {
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: "𐐀abc")
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        coordinator.didMarkdownBold(nil)
        #expect(textView.string == "**𐐀abc**")
    }

    @Test("block formatting preserves line endings and trailing source spaces", arguments: ["\n", "\r\n", "\r"])
    func blockFormattingPreservesLineEndings(_ ending: String) {
        let source = "😀body  " + ending + "next"
        for heading in [true, false] {
            let (coordinator, textView, state) = makeCoordinatorAndTextView(text: source)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            if heading {
                let item = NSMenuItem()
                item.tag = 1
                coordinator.didMarkdownHeading(item)
            } else {
                coordinator.didMarkdownUnorderedList(nil)
            }
            let expected = (heading ? "# " : "- ") + source
            #expect((textView.string as NSString).isEqual(to: expected))
            #expect((state.text as NSString).isEqual(to: expected))
        }
    }

    @Test("native word formatting preserves ordinary and whitespace caret behavior")
    func nativeWordFormattingBoundaries() {
        for (source, caret, expected) in [
            ("hello world", 2, "**hello** world"),
            ("hello world", 5, "**hello** world"),
            ("hello world", 6, "hello **world**"),
            ("  ", 1, "  "),
        ] {
            let (coordinator, textView, _) = makeCoordinatorAndTextView(text: source)
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            coordinator.didMarkdownBold(nil)
            #expect(textView.string == expected)
        }
    }

    @Test("formatting commands cannot edit a read-only document")
    func readOnlyFormattingPreservesSource() {
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: "source")
        textView.isEditable = false
        textView.setSelectedRange(NSRange(location: 0, length: 6))
        coordinator.didMarkdownBold(nil)
        #expect(textView.string == "source")
        coordinator.didMarkdownUnorderedList(nil)
        #expect(textView.string == "source")
    }

    private func largeFixture(target: String) -> String {
        let prefix = (0..<2_000).map { "plain line \($0) with text" }.joined(separator: "\n")
        let suffix = (2_000..<4_000).map { "plain line \($0) with text" }.joined(separator: "\n")
        return prefix + "\n" + target + "\n" + suffix
    }
}
