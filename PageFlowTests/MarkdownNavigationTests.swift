//
//  MarkdownNavigationTests.swift
//  PageFlowTests
//
//  The Markdown side of the shared navigation surface: the two-stack scroll
//  trail behind ⌘[/⌘] (the PDF page-history peer), the Go to Line bounds, and
//  the reading-position record that rides the shared DocumentStateStore.
//

import Foundation
import Testing
@testable import PageFlow
import MarkdownEngine

@Suite("Markdown navigation trail")
struct MarkdownNavigationTrailTests {

    @Test func jumpThenBackThenForwardWalksBothWays() {
        var trail = MarkdownNavigationTrail<CGFloat>()
        #expect(!trail.canGoBack && !trail.canGoForward)

        trail.recordJump(from: 100)          // user was at 100, jumped away
        #expect(trail.canGoBack && !trail.canGoForward)

        let back = trail.goBack(from: 900)   // currently at 900
        #expect(back == 100)
        #expect(!trail.canGoBack && trail.canGoForward)

        let forward = trail.goForward(from: 100)
        #expect(forward == 900)
        #expect(trail.canGoBack && !trail.canGoForward)
    }

    @Test func newJumpClearsTheForwardStack() {
        var trail = MarkdownNavigationTrail<CGFloat>()
        trail.recordJump(from: 100)
        _ = trail.goBack(from: 900)
        #expect(trail.canGoForward)
        trail.recordJump(from: 100)          // browser semantics
        #expect(!trail.canGoForward)
    }

    @Test func emptyTrailNavigationIsANoOp() {
        var trail = MarkdownNavigationTrail<CGFloat>()
        #expect(trail.goBack(from: 5) == nil)
        #expect(trail.goForward(from: 5) == nil)
        #expect(trail == MarkdownNavigationTrail<CGFloat>())
    }

    @Test func backStackIsCapped() {
        var trail = MarkdownNavigationTrail<CGFloat>()
        for i in 0..<250 { trail.recordJump(from: CGFloat(i)) }
        #expect(trail.backStack.count == 100)
        #expect(trail.backStack.first == 150, "oldest entries prune from the front")
    }
}

@MainActor
@Suite("Markdown go-to-line + reading position")
struct MarkdownGoToLineTests {

    @Test func lineCountCountsSourceLines() {
        let content = MarkdownContent(documentId: "t")
        content.documentManager.text = "one\ntwo\nthree"
        #expect(content.lineCount == 3)
        content.documentManager.text = ""
        #expect(content.lineCount == 1)
    }

    @Test func lineStartLocationHonorsTheSplitContract() {
        let text = "alpha\nbeta\ngamma"
        #expect(MarkdownOutline.lineStartLocation(ofLine: 0, in: text) == 0)
        #expect(MarkdownOutline.lineStartLocation(ofLine: 1, in: text) == 6)
        #expect(MarkdownOutline.lineStartLocation(ofLine: 2, in: text) == 11)
        #expect(MarkdownOutline.lineStartLocation(ofLine: 3, in: text) == nil, "past EOF")
        #expect(MarkdownOutline.lineStartLocation(ofLine: -1, in: text) == nil)
        #expect(MarkdownOutline.lineStartLocation(ofLine: 0, in: "") == nil)

        // Newline-terminated document: the trailing empty line is a valid caret
        // position AND counted by lineCount — Go-to-last-line must not no-op.
        let terminated = "alpha\nbeta\n"
        #expect(MarkdownOutline.lineStartLocation(ofLine: 2, in: terminated) == (terminated as NSString).length)
        #expect(MarkdownOutline.lineStartLocation(ofLine: 3, in: terminated) == nil)
    }

    @Test("Source line numbering agrees across LF, CRLF and CR", arguments: ["\n", "\r\n", "\r"])
    func sourceLineEndings(ending: String) {
        let content = MarkdownContent(documentId: UUID().uuidString)
        defer { content.cleanup() }
        let text = "😀e\u{301}" + ending + ending + "# 日本語" + ending
        content.documentManager.text = text
        let firstEnd = 4 + ending.utf16.count
        let headingStart = firstEnd + ending.utf16.count
        #expect(content.lineCount == 4)
        #expect(MarkdownOutline.lineStartLocation(ofLine: 1, in: text) == firstEnd)
        #expect(MarkdownOutline.lineStartLocation(ofLine: 2, in: text) == headingStart)
        #expect(MarkdownOutline.lineStartLocation(ofLine: 3, in: text) == text.utf16.count)
        #expect(MarkdownOutline.lineStartLocation(ofLine: 4, in: text) == nil)
        #expect(MarkdownOutline.parse(text).map(\.lineIndex) == [2])
        #expect(MarkdownOutline.parse(text).map(\.title) == ["日本語"])
    }

    @Test("Mixed source endings preserve blank lines and fenced heading numbering")
    func mixedSourceLineEndings() {
        let content = MarkdownContent(documentId: UUID().uuidString)
        defer { content.cleanup() }
        let text = "# A\r\n```\r# hidden\n```\r\n\r## B\n"
        content.documentManager.text = text
        #expect(content.lineCount == 7)
        #expect(MarkdownOutline.parse(text).map(\.title) == ["A", "B"])
        #expect(MarkdownOutline.parse(text).map(\.lineIndex) == [0, 5])
        #expect(MarkdownOutline.lineStartLocation(ofLine: 5, in: text) == 24)
    }

    @Test func markdownViewStateRoundTripsThroughCodable() throws {
        let state = DocumentViewState.markdown(anchorOffset: 1_204, offsetInViewport: -12.5, scaleFactor: 1.25)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(DocumentViewState.self, from: data)
        #expect(decoded.markdownAnchorOffset == 1_204)
        #expect(decoded.markdownOffsetInViewport == -12.5)
        #expect(decoded.markdownScaleFactor == 1.25)

        // Records written BEFORE the fields existed must keep decoding (nil).
        let legacy = DocumentViewState(pageIndex: 3, scaleFactor: 1.5, isAutoScaling: true, scrollPoint: nil)
        let legacyData = try JSONEncoder().encode(legacy)
        let legacyDecoded = try JSONDecoder().decode(DocumentViewState.self, from: legacyData)
        #expect(legacyDecoded.markdownAnchorOffset == nil)
        #expect(legacyDecoded.pageIndex == 3)
    }

    /// A stored anchor arms the editor's one-shot restore at load; no anchor
    /// (a PDF-shaped or pre-D7 record) arms nothing, and the zoom still applies.
    @Test func loadArmsReadingPositionFromTheStore() async throws {
        try await withTempMarkdown(bytes: Data("# A\n\nbody\n".utf8)) { url in
            DocumentStateStore.shared.save(.markdown(anchorOffset: 5, offsetInViewport: 3, scaleFactor: 1.5), for: url)
            let content = MarkdownContent(documentId: UUID().uuidString)
            try content.documentManager.load(from: url)
            content.restoreReadingPositionIfAvailable()
            let request = try #require(content.pendingReadingPosition)
            #expect(request.position == ReadingPosition(anchorOffset: 5, offsetInViewport: 3, magnification: 1.5))
            #expect(content.zoomScale == 1.5)

            DocumentStateStore.shared.save(.markdown(anchorOffset: nil, offsetInViewport: nil, scaleFactor: 1), for: url)
            let other = MarkdownContent(documentId: UUID().uuidString)
            try other.documentManager.load(from: url)
            other.restoreReadingPositionIfAvailable()
            #expect(other.pendingReadingPosition == nil)
        }
    }
}

/// A throwaway `.md` file for the load-time tests.
private func withTempMarkdown(bytes: Data, _ body: (URL) async throws -> Void) async rethrows {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("pf-nav-\(UUID().uuidString)")
        .appendingPathExtension("md")
    try? bytes.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    try await body(url)
}
