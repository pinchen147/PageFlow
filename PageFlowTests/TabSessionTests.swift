//
//  TabSessionTests.swift
//  PageFlowTests
//
//  The Tab Session invariant: a tab's whole runtime is one movable unit.
//

import AppKit
import PDFKit
import Testing
@testable import PageFlow

@MainActor
struct TabSessionTests {
    @Test(arguments: [ContentKind.pdf, .markdown])
    func unselectedTransferIntoEmptyWindowStillHasAnActiveSession(kind: ContentKind) throws {
        let source = TabManager()
        if kind == .markdown { source.newMarkdownDocument() }
        let session = try #require(source.activeSession)
        let destination = TabManager(createInitialTab: false)

        #expect(source.moveTab(session.id, to: destination, at: 0, select: false))

        #expect(destination.activeSession === session)
        #expect(destination.activeSession?.contentKind == kind)
        #expect(destination.renderedTabIDs.contains(session.id))
    }

    @Test
    func movingWarmBackgroundPDFPreservesExactScroll() throws {
        let source = TabManager()
        let tabID = try #require(source.activeTabID)
        let pdf = try #require(source.activePDFManager)
        let document = makeTestDocument(pageCount: 3)
        pdf.document = document
        pdf.documentURL = URL(fileURLWithPath: "/tmp/transfer-\(UUID()).pdf")
        let livePosition = PDFDestination(page: try #require(document.page(at: 1)), at: CGPoint(x: 42, y: 315))
        pdf.liveDestinationProvider = { livePosition }
        source.createNewTab()
        source.closeFilePicker()
        // A mounted background view has consumed the switch-away restoration.
        pdf.pendingScrollRestore = nil

        let target = TabManager(createInitialTab: false)
        #expect(source.moveTab(tabID, to: target, at: 0))

        let restoration = try #require(target.activePDFManager?.pendingScrollRestore)
        #expect(restoration.page === livePosition.page)
        #expect(restoration.point == CGPoint(x: 42, y: 315))
    }

    @Test
    func movingEvictedBackgroundPDFKeepsPersistedScrollPoint() throws {
        let source = TabManager()
        let tabID = try #require(source.activeTabID)
        let pdf = try #require(source.activePDFManager)
        let document = makeTestDocument(pageCount: 3)
        let url = URL(fileURLWithPath: "/tmp/evicted-transfer-\(UUID()).pdf")
        pdf.document = document
        pdf.documentURL = url
        let livePosition = PDFDestination(page: try #require(document.page(at: 1)), at: CGPoint(x: 12, y: 275))
        pdf.liveDestinationProvider = { livePosition }
        for _ in 0..<TabManager.maxRenderedTabs { source.createNewTab() }
        source.closeFilePicker()
        try #require(!source.renderedTabIDs.contains(tabID))
        // The evicted view dismantles; only cached and durable state remain.
        pdf.liveDestinationProvider = nil
        try #require(DocumentStateStore.shared.state(for: url)?.scrollPoint == CGPoint(x: 12, y: 275))

        let target = TabManager()
        #expect(source.moveTab(tabID, to: target, at: 0, select: false))

        #expect(DocumentStateStore.shared.state(for: url)?.scrollPoint == CGPoint(x: 12, y: 275))
        #expect(pdf.pendingScrollRestore?.point == CGPoint(x: 12, y: 275))
    }

    @Test
    func transferCapturesEachAffectedLivePDFViewOnce() throws {
        let source = TabManager()
        let destination = TabManager()
        let tabID = try #require(source.activeTabID)
        let sourcePDF = try #require(source.activePDFManager)
        let destinationPDF = try #require(destination.activePDFManager)
        sourcePDF.document = makeTestDocument(pageCount: 1)
        sourcePDF.documentURL = URL(fileURLWithPath: "/tmp/source-\(UUID()).pdf")
        destinationPDF.document = makeTestDocument(pageCount: 1)
        destinationPDF.documentURL = URL(fileURLWithPath: "/tmp/destination-\(UUID()).pdf")
        var sourceCaptures = 0
        var destinationCaptures = 0
        sourcePDF.liveDestinationProvider = { sourceCaptures += 1; return nil }
        destinationPDF.liveDestinationProvider = { destinationCaptures += 1; return nil }

        #expect(source.moveTab(tabID, to: destination, at: 0))

        #expect(sourceCaptures == 1)
        #expect(destinationCaptures == 1)
    }

    @Test
    func transferDoesNotRestartCompletedPDFSearchWithoutMatches() async throws {
        let source = TabManager()
        let tabID = try #require(source.activeTabID)
        let pdf = try #require(source.activePDFManager)
        let search = try #require(source.activeSearchManager)
        let document = makeTestDocument(pageCount: 3)
        pdf.document = document
        search.restoreSearch("absent phrase", resultIndex: 0, in: document)
        for _ in 0..<100 where search.isSearching {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!search.isSearching)
        try #require(search.searchResults.isEmpty)

        let destination = TabManager(createInitialTab: false)
        #expect(source.moveTab(tabID, to: destination, at: 0))

        #expect(destination.activeSearchManager?.searchQuery == "absent phrase")
        #expect(destination.activeSearchManager?.isSearching == false)
    }

    /// Tearing a tab off into another window moves its session as ONE unit:
    /// the same manager instances, undo history, and UI state travel together,
    /// and the source window releases the tab.
    @Test
    func detachAttachMovesTheSessionAsOneUnit() throws {
        let source = TabManager()
        let tabID = try #require(source.activeTabID)
        source.setShowingComments(true, for: tabID)

        let session = try #require(source.activeSession)
        let pdfManager = session.pdfManager
        let undoManager = try #require(session.undoManager)
        undoManager.registerUndo(withTarget: session) { _ in }  // canUndo == true

        let destination = TabManager(createInitialTab: false)
        #expect(source.moveTab(tabID, to: destination, at: 0))

        // Source released the tab; destination owns the identical session.
        #expect(source.activeTabID == nil)
        #expect(destination.activeTabID == tabID)
        #expect(destination.activeSession === session)
        #expect(destination.activePDFManager === pdfManager)
        #expect(destination.activeUndoManager === undoManager)

        // UI state and undo history travelled intact.
        #expect(destination.showingComments)
        #expect(destination.activeSession?.undoManager?.canUndo == true)
    }

    /// A Markdown tab tears off as ONE unit (S8 P3): the SAME `MarkdownContent` and
    /// `MarkdownDocumentManager` instance travel to the destination window, with the
    /// buffer text preserved — the markdown peer of the PDF session-move invariant.
    @Test
    func markdownTabDetachesAsOneUnit() throws {
        let source = TabManager()
        // A fresh window's empty PDF placeholder is reused IN PLACE by ⌘N
        // (`newMarkdownDocument`), so the source holds exactly one tab — the
        // markdown document — under the placeholder's id (the single-tab move
        // above, with markdown content).
        let placeholderID = try #require(source.activeTabID)
        source.newMarkdownDocument()
        let tabID = try #require(source.activeTabID)
        #expect(tabID == placeholderID)
        #expect(source.tabs.count == 1)

        let content = try #require(source.activeSession?.content.markdown)
        let documentManager = content.documentManager
        let originalText = documentManager.text
        let undo = content.undoManager
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: documentManager) { manager in
            manager.text = originalText
        }
        documentManager.text = "# Torn off\n\nkeep me"
        undo.endUndoGrouping()

        let destination = TabManager(createInitialTab: false)
        #expect(source.moveTab(tabID, to: destination, at: 0))

        // Source released the tab; destination owns the identical markdown content.
        #expect(source.activeTabID == nil)
        #expect(destination.activeTabID == tabID)
        #expect(destination.activeSession?.content.markdown === content)
        #expect(destination.activeSession?.content.markdown?.documentManager === documentManager)

        // The buffer text survived the move.
        #expect(destination.activeSession?.content.markdown?.documentManager.text == "# Torn off\n\nkeep me")
        #expect(destination.isTabDirty(tabID))
        #expect(destination.activeUndoManager === undo)
        undo.undo()
        #expect(documentManager.text == originalText)
        #expect(!destination.isTabDirty(tabID))
    }

    /// A pending password-unlock request rides inside the session, so a tab torn
    /// off mid-unlock surfaces its prompt in the destination window — with no
    /// hand-copied request payload.
    @Test
    func pendingUnlockTravelsWithTheSession() throws {
        let source = TabManager()
        let tabID = try #require(source.activeTabID)

        let session = try #require(source.activeSession)
        session.pendingUnlock = TabSession.UnlockRequest(
            url: URL(fileURLWithPath: "/tmp/locked.pdf"),
            isSecurityScoped: false,
            closeTabOnCancel: false,
            restoreTabIDOnCancel: nil
        )
        #expect(source.isAwaitingPassword(for: tabID))

        let destination = TabManager(createInitialTab: false)
        #expect(source.moveTab(tabID, to: destination, at: 0))

        #expect(!source.isAwaitingPassword(for: tabID))
        #expect(destination.isAwaitingPassword(for: tabID))
        #expect(destination.pendingPasswordRequest?.tabID == tabID)
        #expect(destination.pendingPasswordRequest?.url.lastPathComponent == "locked.pdf")
    }

    /// Closing a tab runs the session's ordered teardown and drops it.
    @Test
    func closingATabCleansUpItsSession() throws {
        let manager = TabManager()
        let tabID = try #require(manager.activeTabID)

        let session = try #require(manager.activeSession)
        let undoManager = try #require(session.undoManager)
        undoManager.registerUndo(withTarget: session) { _ in }
        #expect(undoManager.canUndo)

        // A second tab so the window survives the close (single-tab close would
        // ask the registry to close the window).
        manager.createNewTab()
        manager.closeTab(tabID)

        // cleanup() cleared the undo history and the session is gone from the manager.
        #expect(!undoManager.canUndo)
        #expect(manager.activeSession !== session)
    }

    // MARK: - View Snapshot

    /// Capturing reads the tab's live page/zoom/search into the snapshot.
    @Test
    func captureViewSnapshotReadsTheLiveManagers() {
        let session = TabSession(id: UUID())
        let pdfManager = session.pdfManager!
        let searchManager = session.searchManager!
        pdfManager.document = makeTestDocument(pageCount: 5)
        pdfManager.goToPage(3)
        pdfManager.setZoom(1.5)
        searchManager.searchQuery = "needle"
        searchManager.currentResultIndex = 2

        session.captureViewSnapshot()

        #expect(session.viewSnapshot == TabSession.ViewSnapshot(
            pageIndex: 3, scaleFactor: 1.5, searchQuery: "needle", searchResultIndex: 2))
    }

    /// Restoring re-applies the snapshot's page and zoom to the live managers.
    @Test
    func restoreViewSnapshotReappliesPageAndZoom() {
        let session = TabSession(id: UUID())
        let pdfManager = session.pdfManager!
        pdfManager.document = makeTestDocument(pageCount: 5)
        pdfManager.goToPage(3)
        pdfManager.setZoom(1.5)
        session.captureViewSnapshot()

        // Simulate the live view being moved while the tab was inactive.
        pdfManager.goToPage(0)
        pdfManager.setZoom(1.0)

        session.restoreViewSnapshot()

        #expect(pdfManager.currentPageIndex == 3)
        #expect(pdfManager.scaleFactor == 1.5)
    }

    /// Restoring without a document is a safe no-op (the guard the live app relies
    /// on for not-yet-loaded tabs).
    @Test
    func restoreViewSnapshotWithoutDocumentIsANoOp() {
        let session = TabSession(id: UUID())
        session.restoreViewSnapshot()
        #expect(session.pdfManager?.currentPageIndex == 0)
        #expect(session.viewSnapshot == TabSession.ViewSnapshot())
    }

    /// Clearing the search snapshot leaves page and zoom intact.
    @Test
    func clearSearchSnapshotKeepsPageAndZoom() {
        let session = TabSession(id: UUID())
        let pdfManager = session.pdfManager!
        let searchManager = session.searchManager!
        pdfManager.document = makeTestDocument(pageCount: 5)
        pdfManager.goToPage(2)
        pdfManager.setZoom(1.5)
        searchManager.searchQuery = "needle"
        searchManager.currentResultIndex = 2
        session.captureViewSnapshot()

        session.clearSearchSnapshot()

        #expect(session.viewSnapshot == TabSession.ViewSnapshot(
            pageIndex: 2, scaleFactor: 1.5, searchQuery: "", searchResultIndex: 0))
    }

    /// The whole point of #4: the snapshot rides with the session when a tab is
    /// torn off, with no hand-copy by the manager.
    @Test
    func viewSnapshotTravelsWithTheSessionOnMove() throws {
        let source = TabManager()
        let tabID = try #require(source.activeTabID)
        let session = try #require(source.activeSession)
        let searchManager = try #require(session.searchManager)
        searchManager.searchQuery = "carryover"
        searchManager.currentResultIndex = 1
        session.captureViewSnapshot()

        let destination = TabManager(createInitialTab: false)
        #expect(source.moveTab(tabID, to: destination, at: 0))

        #expect(destination.activeSession?.viewSnapshot.searchQuery == "carryover")
        #expect(destination.activeSession?.viewSnapshot.searchResultIndex == 1)
    }

    /// Re-activating a tab whose SearchManager still holds the snapshot's query
    /// and results must NOT re-run the full-document find — that guard is what
    /// keeps warm-tab switching instant.
    @Test
    func restoreViewSnapshotSkipsSearchWhenLiveStateStillMatches() {
        let session = TabSession(id: UUID())
        let pdfManager = session.pdfManager!
        let searchManager = session.searchManager!
        let document = makeTestDocument(pageCount: 3)
        pdfManager.document = document
        searchManager.searchQuery = "needle"
        let liveResult = PDFSelection(document: document)
        searchManager.searchResults = [liveResult]
        searchManager.currentResultIndex = 0
        session.captureViewSnapshot()

        session.restoreViewSnapshot()

        // A re-run would synchronously flip isSearching and later rebuild the
        // result array; neither happened, and the result index was not reset.
        #expect(!searchManager.isSearching)
        #expect(searchManager.searchResults.first === liveResult)
        #expect(searchManager.currentResultIndex == 0)
    }

    /// When the search was cleared while the tab was inactive (or the view was
    /// evicted and rebuilt), re-activation restores the snapshot's search.
    @Test
    func restoreViewSnapshotRerunsSearchAfterItWasCleared() {
        let session = TabSession(id: UUID())
        let pdfManager = session.pdfManager!
        let searchManager = session.searchManager!
        let document = makeTestDocument(pageCount: 3)
        pdfManager.document = document
        searchManager.searchQuery = "needle"
        searchManager.searchResults = [PDFSelection(document: document)]
        session.captureViewSnapshot()

        searchManager.clearSearch()
        session.restoreViewSnapshot()

        // restoreSearch kicked off synchronously: the query is reinstated and
        // the (undebounced) full-document find is in flight.
        #expect(searchManager.searchQuery == "needle")
        #expect(searchManager.isSearching)
    }
}
