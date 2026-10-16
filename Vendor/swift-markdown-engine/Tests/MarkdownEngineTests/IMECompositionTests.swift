//
//  IMECompositionTests.swift
//  MarkdownEngineTests
//
//  Regression coverage for the "pinyin typing is laggy / IME breaks" field
//  bug: every setMarkedText (one per composition keystroke) triggered a
//  restyle that re-parsed the WHOLE document (the composition text misses the
//  parse cache) and destructively `setAttributes`-wiped the marked range,
//  destroying the IME's composition underline and fighting the input context.
//
//  The contract pinned here:
//  1. Composition updates never tokenize the document.
//  2. Selection changes during composition never tokenize the document.
//  3. Marked text inherits the visual attributes of the run it's typed into.
//  4. A restyle landing mid-composition leaves the marked range's IME
//     attributes intact (TextStylingService carves the marked range out of
//     its destructive base-attribute wipe).
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("IME composition")
struct IMECompositionTests {

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

    private func startComposition(_ pinyin: String, in textView: NativeTextView, at location: Int) {
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.setMarkedText(
            pinyin,
            selectedRange: NSRange(location: (pinyin as NSString).length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    @Test func compositionUpdateDoesNotReparseTheDocument() {
        let text = "# Title\n\nBody paragraph."
        let (coordinator, tv) = makeEditor(text: text)

        startComposition("nihao", in: tv, at: (text as NSString).length)

        #expect(tv.hasMarkedText())
        // The parse cache still reflects the pre-composition document: the
        // composition path must not tokenize per keystroke.
        #expect(coordinator.cachedParsedChars == Array(text.utf16))
    }

    @Test func selectionChangeDuringCompositionDoesNotReparse() {
        let text = "# Title\n\nBody paragraph."
        let (coordinator, tv) = makeEditor(text: text)

        startComposition("ni", in: tv, at: (text as NSString).length)
        // Simulate the post-fast-path state where the cache is invalidated;
        // the selection handler must not rebuild it mid-composition.
        coordinator.cachedParsedChars = nil
        coordinator.cachedParsedDocument = nil

        coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: tv)
        )

        #expect(coordinator.cachedParsedChars == nil)
        #expect(coordinator.cachedParsedDocument == nil)
    }

    @Test func compositionInheritsSurroundingRunStyling() throws {
        let text = "# Heading"
        let (_, tv) = makeEditor(text: text)

        startComposition("ni", in: tv, at: (text as NSString).length)

        let marked = tv.markedRange()
        #expect(marked.location != NSNotFound && marked.length > 0)
        let attrs = try #require(tv.textStorage).attributes(at: marked.location, effectiveRange: nil)
        let font = try #require(attrs[.font] as? NSFont)
        // Composing at the end of an H1 renders at heading size, not body 16pt.
        #expect(font.pointSize > 16)
    }

    @Test func restyleDuringCompositionPreservesMarkedRangeAttributes() throws {
        let text = "# Heading\n\nBody paragraph."
        let (coordinator, tv) = makeEditor(text: text)

        startComposition("nihao", in: tv, at: (text as NSString).length)
        let marked = tv.markedRange()
        #expect(marked.location != NSNotFound && marked.length > 0)

        // Stand-in for the IME's composition attributes (clause underline).
        let storage = try #require(tv.textStorage)
        storage.addAttribute(
            .underlineStyle,
            value: NSNumber(value: NSUnderlineStyle.thick.rawValue),
            range: marked
        )

        // A full paragraph restyle landing mid-composition (async callback,
        // font change) must not wipe the IME's attributes off the marked range.
        let paragraph = (tv.string as NSString).paragraphRange(for: marked)
        coordinator.restyleParagraphs([paragraph], in: tv)

        let attrs = storage.attributes(at: marked.location, effectiveRange: nil)
        #expect(attrs[.underlineStyle] != nil)
    }
}
