//
//  PlainTypingParseRebaseTests.swift
//  MarkdownEngineTests
//
//  Plain typing keeps the parse cache current: the next caller that needs
//  tokens (a click, Find, a deferred chunk) gets the cached parse moved past
//  the typed text instead of a whole-note re-parse (half a second on a 5 MB
//  note), and what it gets always equals a fresh parse. Typing against inline
//  syntax falls back to that parse.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@Suite("Plain typing parse rebase", .serialized)
@MainActor
struct PlainTypingParseRebaseTests {
    typealias H = TableOverlayEndToEndTests

    private static let note = """
    # Title line

    Some prose with **bold** words and a [link](https://x.y) in it.

    ## Second heading

    More prose follows here, and then *emphasis* and `code` too.

    Loose *stars *here stay literal until one closes.
    """

    private func findEditor(in view: NSView) -> NativeTextView? {
        if let tv = view as? NativeTextView { return tv }
        for sub in view.subviews { if let found = findEditor(in: sub) { return found } }
        return nil
    }

    private func mount() throws -> (NSWindow, NativeTextView, NativeTextViewCoordinator) {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: H.EditorHarnessView(host: H.Host(text: Self.note), configuration: .default))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let tv = try #require(findEditor(in: hosting))
        let coordinator = try #require(tv.delegate as? NativeTextViewCoordinator)
        return (window, tv, coordinator)
    }

    /// Types `text` one character at a time at `offset`, as the keyboard does.
    private func type(_ text: String, at offset: Int, in tv: NativeTextView) {
        tv.setSelectedRange(NSRange(location: offset, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        for character in text {
            tv.insertText(String(character), replacementRange: tv.selectedRange())
        }
    }

    private func signature(_ tokens: [MarkdownToken]) -> [String] {
        tokens.map { "\($0.kind) \($0.range) \($0.contentRange) \($0.markerRanges)" }
    }

    private func expectMatchesFreshParse(_ tv: NativeTextView, _ coordinator: NativeTextViewCoordinator) {
        let cached = coordinator.parsedDocument(for: tv.string).tokens
        let fresh = MarkdownTokenizer.parseTokensViaAST(in: tv.string)
        #expect(signature(cached) == signature(fresh), "the cached parse differs from a fresh one")
        #expect(coordinator.plainInsertionsSinceParse.isEmpty)
    }

    @Test("prose typing keeps the cache key and rebases to a fresh parse")
    func proseTypingRebases() throws {
        let (window, tv, coordinator) = try mount()
        defer { window.orderOut(nil) }
        let offset = (tv.string as NSString).range(of: "prose with").location + 5
        type("abc", at: offset, in: tv)
        #expect(coordinator.cachedParsedChars != nil, "plain typing dropped the parse key")
        #expect(coordinator.plainInsertionsSinceParse == [NSRange(location: offset, length: 3)])
        let parsed = try #require(coordinator.cachedParsedDocument)
        #expect(coordinator.parsedDocumentRebasedForPlainInsertions(parsed) != nil, "prose typing fell back to a full parse")
        expectMatchesFreshParse(tv, coordinator)
    }

    @Test("typing at the end of a heading rebases it to the longer line")
    func headingEndRebases() throws {
        let (window, tv, coordinator) = try mount()
        defer { window.orderOut(nil) }
        let offset = NSMaxRange((tv.string as NSString).range(of: "## Second heading"))
        type("xyz", at: offset, in: tv)
        let parsed = try #require(coordinator.cachedParsedDocument)
        #expect(coordinator.parsedDocumentRebasedForPlainInsertions(parsed) != nil)
        expectMatchesFreshParse(tv, coordinator)
    }

    @Test("typing right after inline syntax falls back to a fresh parse")
    func inlineEdgeFallsBack() throws {
        let (window, tv, coordinator) = try mount()
        defer { window.orderOut(nil) }
        let offset = NSMaxRange((tv.string as NSString).range(of: "**bold**"))
        type("s", at: offset, in: tv)
        if !coordinator.plainInsertionsSinceParse.isEmpty, let parsed = coordinator.cachedParsedDocument {
            #expect(coordinator.parsedDocumentRebasedForPlainInsertions(parsed) == nil, "an inline edge was rebased")
        }
        expectMatchesFreshParse(tv, coordinator)
    }

    /// Emphasis depends on the characters beside its delimiters (flanking), so
    /// typing beside one can make or break a span that no cached token marks.
    @Test("typing beside a delimiter matches a fresh parse", arguments: ["opens", "breaks"])
    func typingBesideADelimiter(_ edit: String) throws {
        let (window, tv, coordinator) = try mount()
        defer { window.orderOut(nil) }
        let text = tv.string as NSString
        if edit == "opens" {
            type("x", at: text.range(of: "*stars *").location + 7, in: tv)   // `*stars x*` is emphasis
        } else {
            type(" ", at: text.range(of: "*emphasis*").location + 1, in: tv) // `* emphasis*` is not
        }
        expectMatchesFreshParse(tv, coordinator)
    }

    @Test("separate runs of typing rebase in order")
    func separateRunsRebase() throws {
        let (window, tv, coordinator) = try mount()
        defer { window.orderOut(nil) }
        type("ab", at: (tv.string as NSString).range(of: "More prose").location + 4, in: tv)
        type("cd", at: (tv.string as NSString).range(of: "Some prose").location + 4, in: tv)
        expectMatchesFreshParse(tv, coordinator)
    }
}
