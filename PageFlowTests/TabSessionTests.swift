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
    /// Tearing a tab off into another window moves its session as ONE unit:
    /// the same manager instances, undo history, and UI state travel together,
    /// and the source window releases the tab.
    @Test
    func detachAttachMovesTheSessionAsOneUnit() {
        let source = TabManager()
        let tabID = try! #require(source.activeTabID)
        source.setShowingComments(true, for: tabID)

        let session = try! #require(source.activeSession)
        let pdfManager = session.pdfManager
        let undoManager = session.undoManager
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
        #expect(destination.activeSession?.undoManager.canUndo == true)
    }

    /// A pending password-unlock request rides inside the session, so a tab torn
    /// off mid-unlock surfaces its prompt in the destination window — with no
    /// hand-copied request payload.
    @Test
    func pendingUnlockTravelsWithTheSession() {
        let source = TabManager()
        let tabID = try! #require(source.activeTabID)

        let session = try! #require(source.activeSession)
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
    func closingATabCleansUpItsSession() {
        let manager = TabManager()
        let tabID = try! #require(manager.activeTabID)

        let session = try! #require(manager.activeSession)
        session.undoManager.registerUndo(withTarget: session) { _ in }
        #expect(session.undoManager.canUndo)

        // A second tab so the window survives the close (single-tab close would
        // ask the registry to close the window).
        manager.createNewTab()
        manager.closeTab(tabID)

        // cleanup() cleared the undo history and the session is gone from the manager.
        #expect(!session.undoManager.canUndo)
        #expect(manager.activeSession !== session)
    }

    // MARK: - View Snapshot

    /// Capturing reads the tab's live page/zoom/search into the snapshot.
    @Test
    func captureViewSnapshotReadsTheLiveManagers() {
        let session = TabSession(id: UUID())
        session.pdfManager.document = makeTestDocument(pageCount: 5)
        session.pdfManager.goToPage(3)
        session.pdfManager.setZoom(1.5)
        session.searchManager.searchQuery = "needle"
        session.searchManager.currentResultIndex = 2

        session.captureViewSnapshot()

        #expect(session.viewSnapshot == TabSession.ViewSnapshot(
            pageIndex: 3, scaleFactor: 1.5, searchQuery: "needle", searchResultIndex: 2))
    }

    /// Restoring re-applies the snapshot's page and zoom to the live managers.
    @Test
    func restoreViewSnapshotReappliesPageAndZoom() {
        let session = TabSession(id: UUID())
        session.pdfManager.document = makeTestDocument(pageCount: 5)
        session.pdfManager.goToPage(3)
        session.pdfManager.setZoom(1.5)
        session.captureViewSnapshot()

        // Simulate the live view being moved while the tab was inactive.
        session.pdfManager.goToPage(0)
        session.pdfManager.setZoom(1.0)

        session.restoreViewSnapshot()

        #expect(session.pdfManager.currentPageIndex == 3)
        #expect(session.pdfManager.scaleFactor == 1.5)
    }

    /// Restoring without a document is a safe no-op (the guard the live app relies
    /// on for not-yet-loaded tabs).
    @Test
    func restoreViewSnapshotWithoutDocumentIsANoOp() {
        let session = TabSession(id: UUID())
        session.restoreViewSnapshot()
        #expect(session.pdfManager.currentPageIndex == 0)
        #expect(session.viewSnapshot == TabSession.ViewSnapshot())
    }

    /// Clearing the search snapshot leaves page and zoom intact.
    @Test
    func clearSearchSnapshotKeepsPageAndZoom() {
        let session = TabSession(id: UUID())
        session.pdfManager.document = makeTestDocument(pageCount: 5)
        session.pdfManager.goToPage(2)
        session.pdfManager.setZoom(1.5)
        session.searchManager.searchQuery = "needle"
        session.searchManager.currentResultIndex = 2
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
        session.searchManager.searchQuery = "carryover"
        session.searchManager.currentResultIndex = 1
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
        let document = makeTestDocument(pageCount: 3)
        session.pdfManager.document = document
        session.searchManager.searchQuery = "needle"
        let liveResult = PDFSelection(document: document)
        session.searchManager.searchResults = [liveResult]
        session.searchManager.currentResultIndex = 0
        session.captureViewSnapshot()

        session.restoreViewSnapshot()

        // A re-run would synchronously flip isSearching and later rebuild the
        // result array; neither happened, and the result index was not reset.
        #expect(!session.searchManager.isSearching)
        #expect(session.searchManager.searchResults.first === liveResult)
        #expect(session.searchManager.currentResultIndex == 0)
    }

    /// When the search was cleared while the tab was inactive (or the view was
    /// evicted and rebuilt), re-activation restores the snapshot's search.
    @Test
    func restoreViewSnapshotRerunsSearchAfterItWasCleared() {
        let session = TabSession(id: UUID())
        let document = makeTestDocument(pageCount: 3)
        session.pdfManager.document = document
        session.searchManager.searchQuery = "needle"
        session.searchManager.searchResults = [PDFSelection(document: document)]
        session.captureViewSnapshot()

        session.searchManager.clearSearch()
        session.restoreViewSnapshot()

        // restoreSearch kicked off synchronously: the query is reinstated and
        // the (undebounced) full-document find is in flight.
        #expect(session.searchManager.searchQuery == "needle")
        #expect(session.searchManager.isSearching)
    }
}
