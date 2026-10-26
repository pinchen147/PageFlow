import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Live source cache ownership", .serialized)
struct LiveSourceCacheTests {
    @Test("parsing observes changes in native text storage", arguments: ["x ", "", "## "])
    func blockCacheDoesNotBorrowMutableSource(replacement: String) throws {
        let view = NativeTextView(frame: .zero)
        view.string = "# Heading\n\nA **paragraph**.\n"
        let storage = try #require(view.textStorage)
        let before = BlockParser.parse(view.string)
        storage.replaceCharacters(in: NSRange(location: 0, length: 2), with: replacement)
        let incremental = BlockParser.parse(view.string)
        let snapshot = NSString(string: view.string) as String
        _ = BlockParser.parse("")
        let fresh = BlockParser.parse(snapshot)
        #expect(incremental == fresh)
        #expect(before != fresh)
    }

    @Test("coordinator parsing observes equal-length native edits")
    func coordinatorCacheDoesNotBorrowMutableSource() throws {
        let view = NativeTextView(frame: .zero)
        view.string = "A **bold** paragraph.\n"
        let coordinator = NativeTextViewCoordinator(
            text: .constant(view.string), fontName: "", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        let before = coordinator.parsedDocument(for: view.string).tokens
        let storage = try #require(view.textStorage)
        storage.replaceCharacters(in: NSRange(location: 2, length: 2), with: "xx")
        let incremental = coordinator.parsedDocument(for: view.string).tokens
        let snapshot = NSString(string: view.string) as String
        _ = MarkdownTokenizer.parseTokensViaAST(in: "")
        let fresh = MarkdownTokenizer.parseTokensViaAST(in: snapshot)
        #expect(signature(incremental) == signature(fresh))
        #expect(signature(before) != signature(fresh))
    }

    @Test("native canonical-equivalent source keeps literal UTF-16 and CRLF token coordinates")
    func canonicalSourceKeepsLiteralRanges() throws {
        let composed = "é\r\n\r\n*tail*\r\n"
        let decomposed = "e\u{301}\r\n\r\n*tail*\r\n"
        try #require(composed == decomposed)
        try #require((composed as NSString).length != (decomposed as NSString).length)
        let view = NativeTextView(frame: .zero)
        view.string = composed
        let storage = try #require(view.textStorage)
        let coordinator = NativeTextViewCoordinator(
            text: .constant(composed), fontName: "", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        _ = BlockParser.parse(view.string)
        _ = coordinator.parsedDocument(for: view.string)

        for source in [decomposed, composed, composed] {
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)
            let ns = view.string as NSString
            let tail = ns.range(of: "*tail*")
            let scoped = coordinator.scopedInlineTokens(in: ns, targetRange: tail)
            #expect(scoped.first { $0.kind == .italic }?.range == tail)
            let blocks = BlockParser.parse(view.string)
            #expect(blocks.first?.range == NSRange(location: 0, length: NSMaxRange(ns.range(of: "\r\n"))))
            #expect(blocks.last?.range == ns.range(of: "*tail*\r\n"))
            let parsed = coordinator.parsedDocument(for: view.string)
            #expect(parsed.tokens.first { $0.kind == .italic }?.range == tail)
            #expect(signature(coordinator.parsedDocument(for: view.string).tokens) == signature(parsed.tokens))
            #expect(ns.isEqual(to: source))
        }
    }

    @Test("same-length native source edits invalidate block, coordinator and formatting caches")
    func sameLengthSourceEditInvalidatesCaches() throws {
        let before = "# Heading\r\n\r\n**tail**\r\n"
        let after = "x Heading\r\n\r\n**tail**\r\n"
        try #require((before as NSString).length == (after as NSString).length)
        let view = NativeTextView(frame: .zero)
        view.string = before
        let storage = try #require(view.textStorage)
        let coordinator = NativeTextViewCoordinator(
            text: .constant(before), fontName: "", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        try #require(BlockParser.parse(view.string).first?.kind == .heading)
        try #require(coordinator.parsedDocument(for: view.string).tokens.contains { $0.kind == .heading })
        storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "x")
        let ns = view.string as NSString
        let scoped = coordinator.scopedInlineTokens(in: ns, targetRange: ns.range(of: "x Heading"))
        #expect(scoped.isEmpty)
        #expect(BlockParser.parse(view.string).first?.kind == .paragraph)
        let tokens = coordinator.parsedDocument(for: view.string).tokens
        #expect(!tokens.contains { $0.kind == .heading })
        #expect(tokens.first { $0.kind == .bold }?.range == ns.range(of: "**tail**"))
        #expect(ns.isEqual(to: after))
    }

    private func signature(_ tokens: [MarkdownToken]) -> [String] {
        tokens.map { "\($0.kind):\($0.range):\($0.contentRange):\($0.markerRanges)" }
    }
}
