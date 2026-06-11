//
//  TabSession.swift
//  PageFlow
//
//  The owned, lifecycle-bearing bundle of one tab's managers and per-tab state.
//

import Foundation
import AppKit
import Observation

/// Per-tab UI state (sidebars, dialogs, edit mode). Travels with the session
/// when a tab is moved between windows. Not persisted.
struct TabUIState: Sendable {
    var showingOutline = false
    var showingComments = false
    var showingGoToPage = false
    var showingFileImporter = false
    var isEditingPages = false
}

/// The owned bundle of one tab's collaborating managers — PDF, search,
/// annotation, comment, bookmark, undo — plus that tab's UI state and pending
/// unlock request. Created once per open tab, cleaned up on close, and moved as
/// a single unit between windows. The **PDF View State** (Projector/Ingest)
/// lives inside its `pdfManager`.
///
/// This is a deep module: it hides which managers exist and how they are wired
/// (the page-mutation fan-out, the undo-availability observers) behind a narrow
/// interface, so a window's `TabManager` keeps one `[UUID: TabSession]` instead
/// of nine parallel dictionaries, and lifecycle becomes one call each.
@Observable
@MainActor
final class TabSession {
    /// Identifies the tab this session belongs to. Stable across window moves.
    let id: UUID

    let pdfManager: PDFManager
    let searchManager: SearchManager
    let annotationManager: AnnotationManager
    let commentManager: CommentManager
    let bookmarkManager: BookmarkManager

    /// Owned per-tab undo stack. Not observable itself (`UndoManager` predates
    /// Observation); availability is mirrored into `undoAvailability` instead.
    @ObservationIgnored let undoManager: UndoManager

    /// Per-tab UI state, mutated in place so toggling one flag invalidates only
    /// the views that read it — not every tab.
    var uiState = TabUIState()

    /// This tab's pending password-unlock request, set when its document is
    /// locked. The data lives here so it rides along when the tab moves between
    /// windows; the owning `TabManager` decides which session is presented.
    var pendingUnlock: UnlockRequest?

    /// Snapshot of this tab's page, zoom, and search, captured when the tab is
    /// switched away from and re-applied when it becomes active again so the
    /// reused live `PDFView` re-projects to match. It rides with the session on a
    /// window move (no hand-copy). Distinct from the durable **PDF View State** on
    /// `pdfManager` and from cross-launch reading-position persistence
    /// (`DocumentStateStore`): this snapshot is in-memory and per-activation.
    @ObservationIgnored private(set) var viewSnapshot = ViewSnapshot()

    /// Cached undo availability, refreshed from `undoManager`'s notifications so
    /// menu enable/disable stays observable and cheap.
    private(set) var undoAvailability = UndoAvailability()

    @ObservationIgnored private var undoObservers: [NSObjectProtocol] = []

    /// The per-document data needed to finish opening a locked PDF once a
    /// password is supplied. The tab is identified by the owning session, so no
    /// `tabID` is stored here.
    struct UnlockRequest: Equatable {
        let url: URL
        let isSecurityScoped: Bool
        let closeTabOnCancel: Bool
        let restoreTabIDOnCancel: UUID?
    }

    struct UndoAvailability: Equatable {
        var canUndo = false
        var canRedo = false
    }

    /// The page/zoom/search a tab is restored to when it becomes active again.
    struct ViewSnapshot: Sendable, Equatable {
        var pageIndex = 0
        var scaleFactor: CGFloat = 1.0
        var searchQuery = ""
        var searchResultIndex = 0
    }

    init(id: UUID) {
        self.id = id
        self.pdfManager = PDFManager()
        self.searchManager = SearchManager()
        self.annotationManager = AnnotationManager()
        self.commentManager = CommentManager()
        self.bookmarkManager = BookmarkManager()
        self.undoManager = UndoManager()
        // The markup managers are configured with the live PDFView later, in
        // PDFViewWrapper.makeNSView(); only window-independent wiring lives here.
        wirePageMutations()
        installUndoObservers()
    }

    deinit {
        // Backstop for a session dropped without an explicit close (e.g. a
        // window closed with tabs still present). The normal close path calls
        // cleanup() first, after which this loops over an empty array.
        for observer in undoObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Lifecycle

    /// Ordered teardown when the tab is closed (not when it is merely moved to
    /// another window — a move transfers the session intact).
    func cleanup() {
        removeUndoObservers()
        pdfManager.closeDocument()
        commentManager.clearComments()
        bookmarkManager.clearBookmarks()
        undoManager.removeAllActions()
    }

    // MARK: - View Snapshot (tab activation)

    /// Captures the live managers into `viewSnapshot` when the tab is switched
    /// away from, so it can be restored exactly on re-activation.
    func captureViewSnapshot() {
        viewSnapshot = ViewSnapshot(
            pageIndex: pdfManager.currentPageIndex,
            scaleFactor: pdfManager.scaleFactor,
            searchQuery: searchManager.searchQuery,
            searchResultIndex: searchManager.currentResultIndex
        )
    }

    /// Re-applies `viewSnapshot` to the live managers when the tab becomes active,
    /// forcing the reused `PDFView` to re-project. A no-op without a document.
    func restoreViewSnapshot() {
        if pdfManager.hasDocument {
            pdfManager.goToPage(viewSnapshot.pageIndex)
            if !pdfManager.isAutoScaling {
                pdfManager.setZoom(viewSnapshot.scaleFactor)
            }
        }

        // Warm tabs keep their SearchManager alive across switches — re-running
        // the full-document find on every re-activation defeats the instant
        // switch. Restore only when live state no longer matches the snapshot
        // (the view was evicted/rebuilt, or the query/results were cleared).
        if let document = pdfManager.document,
           !viewSnapshot.searchQuery.isEmpty,
           searchManager.searchQuery != viewSnapshot.searchQuery || !searchManager.hasResults {
            searchManager.restoreSearch(
                viewSnapshot.searchQuery,
                resultIndex: viewSnapshot.searchResultIndex,
                in: document
            )
        }
    }

    /// Clears just the search part of the snapshot, leaving page and zoom intact.
    func clearSearchSnapshot() {
        viewSnapshot.searchQuery = ""
        viewSnapshot.searchResultIndex = 0
    }

    // MARK: - Wiring

    /// Fans page-structure mutations out to the bookmark and comment managers.
    /// Captured weakly so the handler stored on `pdfManager` never retains its
    /// siblings (the session already owns all three).
    private func wirePageMutations() {
        pdfManager.pageMutationHandler = { [weak bookmarkManager, weak commentManager] mutation in
            switch mutation {
            case .inserted(let index):
                bookmarkManager?.handlePageInsertion(at: index)
                commentManager?.reconcilePageIndices()
            case .deleted(let index):
                bookmarkManager?.handlePageDeletion(at: index)
                commentManager?.reconcilePageIndices()
            case .moved(let sourceIndex, let destinationIndex):
                bookmarkManager?.handlePageMove(from: sourceIndex, to: destinationIndex)
                commentManager?.reconcilePageIndices()
            }
        }
    }

    /// Observes the owned `undoManager` so `undoAvailability` stays current.
    /// Observers capture the session (stable identity), so they survive a window
    /// move untouched — there is no reinstall dance.
    private func installUndoObservers() {
        let names: [Notification.Name] = [
            .NSUndoManagerDidCloseUndoGroup,
            .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange
        ]
        undoObservers = names.map { name in
            // One-turn-deferred availability refresh is fine (see helper doc).
            NotificationCenter.default.addMainActorObserver(
                forName: name,
                object: undoManager
            ) { [weak self] in
                self?.refreshUndoAvailability()
            }
        }
        refreshUndoAvailability()
    }

    private func removeUndoObservers() {
        for observer in undoObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        undoObservers = []
    }

    private func refreshUndoAvailability() {
        let updated = UndoAvailability(canUndo: undoManager.canUndo, canRedo: undoManager.canRedo)
        if undoAvailability != updated {
            undoAvailability = updated
        }
    }
}
