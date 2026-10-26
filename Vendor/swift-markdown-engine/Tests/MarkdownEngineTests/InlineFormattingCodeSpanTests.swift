//
//  InlineFormattingCodeSpanTests.swift
//  MarkdownEngineTests
//
//  Regression coverage for the "⌘U nests literal <u><u>…</u></u>" field bug:
//  an underline (or strikethrough) whose content holds an inline-code span was
//  silently dropped by the parser (full-range overlap with the claimed code
//  span), so the toggle never saw an enclosing token and wrapped a fresh pair
//  of markers on every press.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Inline formatting around code spans")
struct InlineFormattingCodeSpanTests {

    private final class State { var text: String; init(_ t: String) { text = t } }

    private func makeEditor(text: String) -> (NativeTextViewCoordinator, NativeTextView) {
        _ = NSApplication.shared
        let state = State(text)
        let coordinator = NativeTextViewCoordinator(
            text: Binding(get: { state.text }, set: { state.text = $0 }),
            fontName: NSFont.systemFont(ofSize: 16).fontName,
            fontSize: 16,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        textView.string = text
        textView.isEditable = true
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        return (coordinator, textView)
    }

    // MARK: - Parser

    @Test func underlineTokenSurvivesInnerCodeSpan() {
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: "1. <u>`report.pdf` (钟品晨, 2026)</u>")
        #expect(tokens.contains { $0.kind == .underline })
        #expect(tokens.contains { $0.kind == .inlineCode })
    }

    @Test func strikethroughTokenSurvivesInnerCodeSpan() {
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: "a ~~x `code` y~~ b")
        #expect(tokens.contains { $0.kind == .strikethrough })
        #expect(tokens.contains { $0.kind == .inlineCode })
    }

    @Test func closingTagInsideCodeSpanDoesNotClose() {
        // The </u> inside the code span must not close the underline.
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: "<u>a `x</u>y` b</u>")
        let underline = tokens.first { $0.kind == .underline }
        #expect(underline != nil)
        #expect(underline.map { NSMaxRange($0.range) } == ("<u>a `x</u>y` b</u>" as NSString).length)
    }

    @Test func underlineMarkerInsideCodeSpanIsNotASpan() {
        // `<u>` living INSIDE code is literal text — no underline token.
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: "a `<u>` b")
        #expect(!tokens.contains { $0.kind == .underline })
    }

    // MARK: - ⌘U end-to-end (the field bug)

    @Test func repeatedUnderlinePressesToggleInsteadOfNesting() {
        let text = "1. `report.pdf` (钟品晨, 2026)"
        let (coordinator, textView) = makeEditor(text: text)
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))

        coordinator.didMarkdownUnderline(nil)
        #expect(textView.string == "1. <u>`report.pdf` (钟品晨, 2026)</u>")

        coordinator.didMarkdownUnderline(nil)
        #expect(textView.string == "1. `report.pdf` (钟品晨, 2026)", "second press must toggle OFF, not nest")

        // A few more rounds must stay a clean toggle.
        for _ in 0..<2 {
            coordinator.didMarkdownUnderline(nil)
            #expect(!textView.string.contains("<u><u>"))
            coordinator.didMarkdownUnderline(nil)
            #expect(!textView.string.contains("<u>"))
        }
    }

    @Test func underlineOnSelectedCodeSpanWrapsTheWholeToken() {
        let text = "1. `report.pdf` (钟品晨, 2026)"
        let (coordinator, textView) = makeEditor(text: text)
        let ns = textView.string as NSString
        textView.setSelectedRange(ns.range(of: "`report.pdf`"))

        coordinator.didMarkdownUnderline(nil)
        #expect(textView.string == "1. <u>`report.pdf`</u> (钟品晨, 2026)")

        coordinator.didMarkdownUnderline(nil)
        #expect(textView.string == "1. `report.pdf` (钟品晨, 2026)", "second press toggles off")
    }

    @Test func boldWithCaretInsideCodeSpanWrapsTheWholeToken() {
        let text = "see `report.pdf` here"
        let (coordinator, textView) = makeEditor(text: text)
        let ns = textView.string as NSString
        // Caret in the middle of the code content — the run must snap outward
        // to the whole protected token, never land markers inside it.
        textView.setSelectedRange(NSRange(location: ns.range(of: "report").location + 2, length: 0))

        coordinator.didMarkdownBold(nil)
        #expect(textView.string == "see **`report.pdf`** here")
    }

    @Test func selectionStraddlingCodeSpanSnapsOutward() {
        let text = "see `report.pdf` here"
        let (coordinator, textView) = makeEditor(text: text)
        let ns = textView.string as NSString
        // From mid-code to the end of the line: the start snaps out to the
        // code token's opening backtick.
        let midCode = ns.range(of: "report").location + 3
        textView.setSelectedRange(NSRange(location: midCode, length: ns.length - midCode))

        coordinator.didMarkdownUnderline(nil)
        #expect(textView.string == "see <u>`report.pdf` here</u>")
    }

    @Test func boldAroundCodeSpanRendersBoldMonospace() {
        // The .code child's font append lands after the emphasis font append —
        // it must COMPOSE the inherited bold trait, not clobber it (field
        // report: **`report.pdf`** rendered regular-weight).
        let text = "**`report.pdf`**"
        let ns = text as NSString
        let attrs = MarkdownStyler.styleAttributes(
            text: text,
            fontName: NSFont.systemFont(ofSize: 16).fontName,
            fontSize: 16,
            caretLocation: -1,
            activeTokenIndices: [],
            configuration: .default
        )
        let content = ns.range(of: "report.pdf")
        let lastFont = attrs.last {
            NSIntersectionRange($0.range, content).length > 0 && $0.attributes[.font] is NSFont
        }?.attributes[.font] as? NSFont
        let traits = lastFont?.fontDescriptor.symbolicTraits ?? []
        #expect(traits.contains(.bold), "code inside bold must render bold")
        #expect(traits.contains(.monoSpace), "…and stay monospace")
    }

    @Test func repeatedBoldPressesOnCodeSpanToggle() {
        let text = "see `report.pdf` here"
        let (coordinator, textView) = makeEditor(text: text)
        let ns = textView.string as NSString
        textView.setSelectedRange(ns.range(of: "`report.pdf`"))

        coordinator.didMarkdownBold(nil)
        #expect(textView.string == "see **`report.pdf`** here")

        coordinator.didMarkdownBold(nil)
        #expect(textView.string == "see `report.pdf` here", "second press toggles off, never nests")
    }

    @Test func tableCellBoldAroundCodeComposesBoldMonospace() {
        let cell = MarkdownStyler.formattedCellString(
            "**`x`**",
            baseFont: NSFont.systemFont(ofSize: 16),
            header: false,
            theme: .default,
            codeBackgroundColor: .gray,
            latex: MarkdownEditorConfiguration.default.services.latex
        )
        var sawBoldMono = false
        cell.enumerateAttribute(.font, in: NSRange(location: 0, length: cell.length)) { value, range, _ in
            guard let font = value as? NSFont,
                  (cell.string as NSString).substring(with: range).contains("x") else { return }
            let traits = font.fontDescriptor.symbolicTraits
            if traits.contains(.bold) && traits.contains(.monoSpace) { sawBoldMono = true }
        }
        #expect(sawBoldMono, "table-cell code inside bold must render bold monospace")
    }

    @Test func codeSpanStraddlingATableCellPipeNeverEscapesTheCell() {
        // The code span crosses the cell pipe, so the whole-block clip straddles
        // the cell-content boundary. The outward snap must CLAMP back to the
        // cell: no `**` may wrap a `|`, and the two cells' runs must not overlap
        // (the atomic multi-plan apply requires disjoint ranges).
        let text = """
        | h1 | h2 |
        | --- | --- |
        | a `x | y` b |
        """
        let (coordinator, textView) = makeEditor(text: text)
        let ns = textView.string as NSString
        let row = ns.range(of: "| a `x | y` b |")
        textView.setSelectedRange(row)

        coordinator.didMarkdownBold(nil)

        let pipeCount = textView.string.filter { $0 == "|" }.count
        #expect(pipeCount == text.filter { $0 == "|" }.count, "table structure must be intact")
        #expect(!textView.string.contains("**|"), "no marker may wrap a pipe")
        #expect(!textView.string.contains("|**` "), "no marker may land mid-token")
        #expect(!textView.string.contains("****"), "runs must stay disjoint")
    }

    @Test func formattingCommandTokenizesOnlyTheTargetParagraphWhenCacheIsStale() {
        // The parse cache dies on every keystroke, so the first ⌘B/I/U after
        // typing must work from a paragraph-scoped tokenize — the old path fell
        // back to a FULL-document parse (O(document) on the main thread, the
        // "sometimes ⌘U/B/I is slow" field report).
        let filler = String(repeating: "paragraph with `code` and *emphasis* text\n\n", count: 500)
        let text = filler + "target `span` line"
        let (coordinator, textView) = makeEditor(text: text)
        let ns = textView.string as NSString
        let target = ns.range(of: "target `span` line")

        coordinator.cachedParsedChars = nil     // post-keystroke state
        coordinator.cachedParsedDocument = nil

        // The command's token source with a stale cache: scoped to the target's
        // paragraph union — complete for the target (the `span` code token is
        // there), and NOT the whole document (the 500 filler code tokens aren't).
        let scoped = coordinator.scopedInlineTokens(in: ns, targetRange: target)
        #expect(scoped.contains { $0.kind == .inlineCode && NSIntersectionRange($0.range, target).length > 0 })
        #expect(scoped.count < 20, "must be paragraph-scoped, not the ~1000-token document")

        // And the command itself stays correct end-to-end on the cold cache.
        textView.setSelectedRange(target)
        coordinator.didMarkdownBold(nil)
        #expect(textView.string.hasSuffix("**target `span` line**"), "scoped tokens must still clip + wrap correctly")

        coordinator.cachedParsedChars = nil
        coordinator.cachedParsedDocument = nil
        coordinator.didMarkdownBold(nil)
        #expect(textView.string.hasSuffix("target `span` line"), "toggle-off must also work scoped")
    }

    @Test func underlineToggleWorksInPlainListItemToo() {
        let text = "1. report.pdf (钟品晨, 2026)"
        let (coordinator, textView) = makeEditor(text: text)
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        coordinator.didMarkdownUnderline(nil)
        #expect(textView.string == "1. <u>report.pdf (钟品晨, 2026)</u>")
        coordinator.didMarkdownUnderline(nil)
        #expect(textView.string == "1. report.pdf (钟品晨, 2026)")
    }
}
