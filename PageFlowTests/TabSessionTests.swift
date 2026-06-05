//
//  TabSessionTests.swift
//  PageFlowTests
//
//  The Tab Session invariant: a tab's whole runtime is one movable unit.
//

import AppKit
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
}
