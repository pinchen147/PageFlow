//
//  PDFManagerNavigationTests.swift
//  PageFlowTests
//
//  Explicit-destination navigation (goToDestination): history push rules, the
//  observable pendingNavigation one-shot, and how an explicit jump supersedes a
//  still-pending reading-position restore.
//

import AppKit
import PDFKit
import Testing
@testable import PageFlow

@MainActor
struct PDFManagerNavigationTests {

    // MARK: - Fixtures

    private func makeManager(pages: Int, current: Int = 0) -> PDFManager {
        let manager = PDFManager()
        manager.document = makeTestDocument(pageCount: pages)
        manager.currentPageIndex = current
        manager.currentPage = manager.document?.page(at: current)
        return manager
    }

    // MARK: - goToDestination

    @Test
    func crossPageJumpMovesPushesHistoryArmsNavigationAndClearsScrollRestore() throws {
        let manager = makeManager(pages: 5)
        let document = try #require(manager.document)

        // A still-pending reading-position restore must be superseded by the
        // explicit jump (its settle retry would otherwise yank the view away).
        let startPage = try #require(document.page(at: 0))
        manager.pendingScrollRestore = PDFDestination(page: startPage, at: CGPoint(x: 0, y: 10))

        let targetPage = try #require(document.page(at: 3))
        let destination = PDFDestination(page: targetPage, at: CGPoint(x: 5, y: 100))
        manager.goToDestination(destination)

        #expect(manager.currentPageIndex == 3)
        #expect(manager.currentPage === targetPage)
        #expect(manager.canGoBack)                          // history pushed
        #expect(manager.pendingNavigation === destination)  // projector armed
        #expect(manager.pendingScrollRestore == nil)        // restore superseded
    }

    @Test
    func samePageJumpArmsNavigationWithoutPushingHistory() throws {
        let manager = makeManager(pages: 3, current: 1)
        let page = try #require(manager.document?.page(at: 1))

        let destination = PDFDestination(page: page, at: CGPoint(x: 0, y: 50))
        manager.goToDestination(destination)

        #expect(manager.currentPageIndex == 1)
        #expect(!manager.canGoBack)                         // no history entry
        #expect(manager.pendingNavigation === destination)  // but still projects
    }

    @Test
    func destinationOnAPageOutsideTheDocumentIsANoOp() throws {
        let manager = makeManager(pages: 3)
        let foreignPage = try #require(makeTestDocument(pageCount: 1).page(at: 0))

        manager.goToDestination(PDFDestination(page: foreignPage, at: .zero))

        #expect(manager.currentPageIndex == 0)
        #expect(!manager.canGoBack)
        #expect(manager.pendingNavigation == nil)
    }

    @Test
    func closeDocumentClearsPendingNavigation() throws {
        let manager = makeManager(pages: 3)
        let targetPage = try #require(manager.document?.page(at: 2))
        manager.goToDestination(PDFDestination(page: targetPage, at: .zero))
        #expect(manager.pendingNavigation != nil)

        manager.closeDocument()

        #expect(manager.pendingNavigation == nil)
    }
}
