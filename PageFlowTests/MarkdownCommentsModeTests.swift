//
//  MarkdownCommentsModeTests.swift
//  PageFlowTests
//
//  the reference editor's Comments button (doc 25 §1.4, §5.6) on a Markdown tab.
//

import Foundation
import MarkdownEngine
import Testing
@testable import PageFlow

@MainActor
struct MarkdownCommentsModeTests {
    @Test
    func theButtonSwitchesBetweenMarginAndListAndShowsHiddenComments() {
        let content = MarkdownContent(documentId: UUID().uuidString)
        #expect(content.commentsMode == .margin)
        #expect(content.commentsButtonHelp == "All comments")
        content.toggleCommentsList()
        #expect(content.commentsMode == .list)
        #expect(content.commentsButtonHelp == "Floating comments")
        content.toggleCommentsList()
        #expect(content.commentsMode == .margin)
        content.toggleCommentsHidden()
        #expect(content.commentsMode == .hidden)
        #expect(content.commentsButtonHelp == "Show comments")
        content.toggleCommentsList()
        #expect(content.commentsMode == .margin)
    }

    @Test
    func theBadgeCountsOpenThreadsOnlyWhileHidden() {
        let content = MarkdownContent(documentId: UUID().uuidString)
        let anchor = MarkdownCommentAnchor(prefix: "", exact: "x", suffix: "")
        let threads = [
            MarkdownCommentThread(anchor: anchor, root: MarkdownComment(body: "a")),
            MarkdownCommentThread(anchor: anchor, resolved: true, root: MarkdownComment(body: "b")),
        ]
        content.editorController.onCommentThreadsChange?(threads)
        #expect(content.openCommentCount == 1)
        #expect(content.hiddenCommentBadge == nil)
        content.toggleCommentsHidden()
        #expect(content.hiddenCommentBadge == 1)
    }
}
