//
//  ImageEmbedActivationTests.swift
//  MarkdownEngineTests
//
//  The caret activates (reveals) an `![[…]]` embed only from the embed's own
//  line when the embed stands alone there, from inside its token when it sits
//  in text, and from the very end of a note that ends on one.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Image embed activation")
struct ImageEmbedActivationTests {

    private final class State {
        var text: String
        var isWikiLinkActive = false
        init(text: String) { self.text = text }
    }

    /// The embed source the caret at each location activates, read from the
    /// coordinator's active tokens after a real selection change.
    private func activeEmbeds(in text: String) -> [Int: String] {
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
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        let ns = text as NSString
        let tokens = coordinator.parsedDocument(for: text).tokens
        var active: [Int: String] = [:]
        for location in 0...ns.length {
            textView.setSelectedRange(NSRange(location: location, length: 0))
            let embeds = coordinator.activeTokenIndices.map { tokens[$0] }.filter { $0.kind == .imageEmbed }
            #expect(embeds.count <= 1, "caret \(location) activates \(embeds.count) embeds")
            if let embed = embeds.first { active[location] = ns.substring(with: embed.range) }
        }
        return active
    }

    /// The caret locations inside `needle`'s token, or on its whole line with
    /// the line break (the note's end for a last line without one).
    private func locations(of needle: String, in text: String, line: Bool) -> [Int] {
        let ns = text as NSString
        let found = ns.range(of: needle)
        let span = line ? ns.paragraphRange(for: found) : found
        let contentEnd = line && ns.substring(with: span).hasSuffix("\n") ? NSMaxRange(span) - 1 : NSMaxRange(span)
        return Array(span.location..<(line ? contentEnd + 1 : NSMaxRange(span)))
    }

    @Test("a standalone embed is active from anywhere on its line; one in text only from inside it")
    func caretActivatesTheEmbedOnItsLine() {
        let text = "![[a.png]]\nText with ![[b.png]] inline\n\n  ![[c.png|300]]  \nlast line"
        var expected: [Int: String] = [:]
        for location in locations(of: "![[a.png]]", in: text, line: true) { expected[location] = "![[a.png]]" }
        for location in locations(of: "![[b.png]]", in: text, line: false) { expected[location] = "![[b.png]]" }
        for location in locations(of: "![[c.png|300]]", in: text, line: true) { expected[location] = "![[c.png|300]]" }
        #expect(activeEmbeds(in: text) == expected)
    }

    @Test("a note that ends on an embed keeps it active with the caret at the very end")
    func caretAtTheEndOfTheNote() {
        let text = "Intro line\n![[e.png]]"
        var expected: [Int: String] = [:]
        for location in locations(of: "![[e.png]]", in: text, line: true) { expected[location] = "![[e.png]]" }
        #expect(expected[(text as NSString).length] == "![[e.png]]")
        #expect(activeEmbeds(in: text) == expected)
    }
}
