//
//  CommentManagerTests.swift
//  PageFlowTests
//
//  Display-order rule for the comments sidebar.
//

import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PageFlow

@MainActor
struct CommentManagerTests {

    @Test
    func sortedCommentsOrdersByCreationTime() {
        let manager = CommentManager()
        let older = CommentModel(
            text: "first",
            pageIndex: 2,
            bounds: .zero,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let newer = CommentModel(
            text: "second",
            pageIndex: 0,
            bounds: .zero,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        manager.comments = [newer, older]

        #expect(manager.sortedComments.map(\.id) == [older.id, newer.id])
    }

    /// Selecting a comment whose highlight is missing (e.g. loaded from a file
    /// whose annotation vanished) falls back to a plain page jump: the manager
    /// lands on the comment's page via goToPage and never arms the
    /// destination-level pendingNavigation.
    @Test
    func selectCommentWithoutHighlightFallsBackToPageJump() {
        let pdfManager = PDFManager()
        pdfManager.document = makeTestDocument(pageCount: 3)
        pdfManager.currentPage = pdfManager.document?.page(at: 0)

        let manager = CommentManager()
        manager.configure(
            pdfManager: pdfManager,
            selectionProvider: { (nil, nil) },
            undoManagerProvider: { nil }
        )

        // Injected directly, so no highlight annotation backs this comment.
        let orphan = CommentModel(text: "orphan", pageIndex: 2, bounds: .zero)
        manager.comments = [orphan]

        manager.selectComment(orphan.id)

        #expect(manager.selectedCommentID == orphan.id)
        #expect(pdfManager.currentPageIndex == 2)        // landed via goToPage
        #expect(pdfManager.pendingNavigation == nil)     // no destination jump
    }
}
