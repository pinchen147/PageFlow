//
//  TabSession.swift
//  PageFlow
//
//  The owned, lifecycle-bearing bundle of one tab's content plus per-tab state.
//  A tab's content is discriminated by `TabContent`: `.pdf(PDFContent)` holds
//  the PDF manager bundle (ADR-0006) and `.markdown(MarkdownContent)` the note.
//  PDF-specific call sites reach the managers through optionals, so the compiler
//  makes every one handle a Markdown tab that has none.
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
    var isEditingPages = false
}

/// Cached undo can-undo/can-redo, mirrored from an `UndoManager`'s
/// notifications (the manager itself predates Observation) so menu
/// enable/disable stays observable and cheap. Shared by every content type.
struct UndoAvailability: Equatable {
    var canUndo = false
    var canRedo = false
}

/// A per-tab undo stack plus its observable availability mirror — the ONE
/// implementation every content type owns (`let undo = UndoAvailabilityMirror()`),
/// so the notification wiring, refresh, and teardown have exactly one home.
/// Observers capture this object's stable identity, so they survive a window
/// move untouched and are removed in `deinit` (the object dies with its content).
@Observable
@MainActor
final class UndoAvailabilityMirror {
    @ObservationIgnored let manager = UndoManager()
    private(set) var availability = UndoAvailability()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let names: [Notification.Name] = [
            .NSUndoManagerDidCloseUndoGroup,
            .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange
        ]
        observers = names.map { name in
            // One-turn-deferred availability refresh is fine (see helper doc).
            NotificationCenter.default.addMainActorObserver(
                forName: name,
                object: manager
            ) { [weak self] in
                self?.refresh()
            }
        }
        refresh()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func refresh() {
        let updated = UndoAvailability(canUndo: manager.canUndo, canRedo: manager.canRedo)
        if availability != updated {
            availability = updated
        }
    }
}

/// The PDF backend of a tab: the owned bundle of one tab's collaborating
/// managers — PDF, search, annotation, comment, bookmark, undo — plus that tab's
/// pending unlock request. Created with a `.pdf` tab, cleaned up on
/// close, and moved as a single unit between windows. The **PDF View State**
/// (Projector/Ingest) lives inside its `pdfManager`.
///
/// This is a deep module: it hides which managers exist and how they are wired
/// (the page-mutation fan-out, the undo-availability observers) behind a narrow
/// interface, so a window's `TabManager` keeps one `[UUID: TabSession]` instead
/// of nine parallel dictionaries, and lifecycle becomes one call each.
@Observable
@MainActor
final class PDFContent {
    let pdfManager: PDFManager
    let searchManager: SearchManager
    let annotationManager: AnnotationManager
    let commentManager: CommentManager
    let bookmarkManager: BookmarkManager

    /// Owned per-tab page-op undo stack + its observable availability mirror.
    let undo = UndoAvailabilityMirror()
    var undoManager: UndoManager { undo.manager }
    var undoAvailability: UndoAvailability { undo.availability }

    /// This tab's pending password-unlock request, set when its document is
    /// locked. The data lives here so it rides along when the tab moves between
    /// windows; the owning `TabManager` decides which session is presented.
    var pendingUnlock: TabSession.UnlockRequest?

    /// Snapshot of this tab's page, zoom, and search, captured when the tab is
    /// switched away from and re-applied when it becomes active again so the
    /// reused live `PDFView` re-projects to match. It rides with the session on a
    /// window move (no hand-copy). Distinct from the durable **PDF View State** on
    /// `pdfManager` and from cross-launch reading-position persistence
    /// (`DocumentStateStore`): this snapshot is in-memory and per-activation.
    @ObservationIgnored private(set) var viewSnapshot = ViewSnapshot()

    /// The page/zoom/search a tab is restored to when it becomes active again.
    struct ViewSnapshot: Sendable, Equatable {
        var pageIndex = 0
        var scaleFactor: CGFloat = 1.0
        var searchQuery = ""
        var searchResultIndex = 0
    }

    init() {
        self.pdfManager = PDFManager()
        self.searchManager = SearchManager()
        self.annotationManager = AnnotationManager()
        self.commentManager = CommentManager()
        self.bookmarkManager = BookmarkManager()
        // The markup managers are configured with the live PDFView later, in
        // PDFViewWrapper.makeNSView(); only window-independent wiring lives here.
        wirePageMutations()
    }

    // MARK: - Lifecycle

    /// Ordered teardown when the tab is closed (not when it is merely moved to
    /// another window — a move transfers the session intact).
    func cleanup() {
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
                pdfManager.restoreZoom(viewSnapshot.scaleFactor)
            }
        }

        // Warm tabs keep their SearchManager alive across switches. Restore
        // only a changed query: empty results are valid for a completed no-match
        // search or a search that is still in flight.
        if let document = pdfManager.document,
           !viewSnapshot.searchQuery.isEmpty,
           searchManager.searchQuery != viewSnapshot.searchQuery {
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

}

// MARK: - PDFContent: TabDocument

/// PDF's half of the content contract. `undoManager`, `undoAvailability`,
/// `cleanup()`, and the three view-snapshot methods already live on the class;
/// this adds the open/save predicates that were formerly `switch` arms in
/// `TabSession`/`DirtyDoc`, now owned by the content itself.
extension PDFContent: TabDocument {
    var restoreBookmark: Data? { pdfManager.securityScopedBookmark }

    var hasContent: Bool { pdfManager.hasDocument }

    /// Keyed to DURABLE identity (`documentURL`), not the live load-state
    /// (`hasDocument`): a tab that ever had a file URL is not a blank placeholder
    /// even if its document is momentarily unloaded, so an open must never clobber it.
    var canReplaceWithoutPrompt: Bool { pdfManager.documentURL == nil && !pdfManager.isDirty }

    var canSave: Bool { pdfManager.hasDocument }
    var canSaveAs: Bool { pdfManager.hasDocument }
    var isDirty: Bool { pdfManager.isDirty }

    var documentTitle: String { pdfManager.documentTitle }
    var needsSaveAs: Bool { false }

    @discardableResult
    func saveSync() -> Bool { pdfManager.saveSync() }
    func finishPendingWrites() { pdfManager.finishPendingWrites() }

    /// PDF always has a URL, so it never routes to the untitled Save-As path.
    func saveAsSync(to url: URL, isSecurityScoped: Bool) -> Bool { false }
}

/// The discriminated content of a tab — the single per-tab routing authority
/// (ADR-0006). Switches over it are exhaustive, so a new content type is flagged
/// at every site that routes by content.
enum TabContent {
    case pdf(PDFContent)
    case markdown(MarkdownContent)

    /// The PDF backend if this is a PDF tab, else nil. The narrow seam every
    /// PDF-specific accessor optional-chains through.
    var pdf: PDFContent? {
        if case .pdf(let content) = self { return content } else { return nil }
    }

    /// The Markdown backend if this is a Markdown tab, else nil.
    var markdown: MarkdownContent? {
        if case .markdown(let content) = self { return content } else { return nil }
    }

    /// The content kind for chrome routing (tab icon / toolbar item set / sidebar)
    /// — the tiny value the chrome layer branches on without touching the managers.
    /// Exhaustive so a new content type must declare its kind.
    var kind: ContentKind {
        switch self {
        case .pdf: return .pdf
        case .markdown: return .markdown
        }
    }
}

/// The owned, content-agnostic unit moved as one when a tab is torn off or
/// merged: a stable id plus its `TabContent`, with the per-tab UI state. The
/// per-content managers and undo history live inside the content; this type
/// forwards to them, optional where a content type has none.
@Observable
@MainActor
final class TabSession {
    /// Identifies the tab this session belongs to. Stable across window moves.
    let id: UUID

    /// This tab's content. The single routing authority for view/chrome/open
    /// routing — never a re-derived path extension at the call site.
    var content: TabContent

    /// The content kind for chrome routing (tab icon / toolbar set / sidebar),
    /// forwarded from `content` so chrome reads it without unwrapping the backend.
    var contentKind: ContentKind { content.kind }

    /// The per-document data needed to finish opening a locked PDF once a
    /// password is supplied. The tab is identified by the owning session, so no
    /// `tabID` is stored here.
    struct UnlockRequest: Equatable {
        let id = UUID()
        let url: URL
        let isSecurityScoped: Bool
        let closeTabOnCancel: Bool
        let restoreTabIDOnCancel: UUID?
    }

    /// Re-exported so existing `TabSession.ViewSnapshot` references (tests,
    /// snapshot reads) keep resolving after the move into `PDFContent`.
    /// (`UndoAvailability` is a top-level type now — shared by both contents.)
    typealias ViewSnapshot = PDFContent.ViewSnapshot

    init(id: UUID) {
        self.id = id
        self.content = .pdf(PDFContent())
    }

    /// Creates a Markdown-backed session — the peer of the pdf `init(id:)`. The
    /// `content` is the single routing authority for view/chrome/open paths, so a
    /// markdown tab is built here rather than by mutating a pdf session after the
    /// fact (which would needlessly spin up a throwaway `PDFContent`).
    static func markdown(id: UUID) -> TabSession {
        // The engine's `documentId` is per CONTENT, not per tab: replacing a
        // tab's markdown with another file builds a fresh content on the same
        // tab id, and the mounted editor must treat that as a document switch
        // (reset its per-document state), not as the same note changing text.
        TabSession(id: id, content: .markdown(MarkdownContent(documentId: "\(id.uuidString).\(UUID().uuidString.prefix(8))")))
    }

    /// Designated initializer taking explicit content. Private: the pdf entry is
    /// `init(id:)` and the markdown entry is `markdown(id:)`; both funnel here.
    private init(id: UUID, content: TabContent) {
        self.id = id
        self.content = content
    }

    // MARK: - Manager forwarding (optional: a Markdown tab has none)

    // Each manager is optional because `.markdown` content owns none of them;
    // the compiler then forces every PDF call site to handle that case rather
    // than crashing on a force-unwrap. They are nil exactly for Markdown tabs.
    var pdfManager: PDFManager? { content.pdf?.pdfManager }
    var searchManager: SearchManager? { content.pdf?.searchManager }
    var annotationManager: AnnotationManager? { content.pdf?.annotationManager }
    var commentManager: CommentManager? { content.pdf?.commentManager }
    var bookmarkManager: BookmarkManager? { content.pdf?.bookmarkManager }

    /// The tab's undo stack — content-routed (PDF page ops vs Markdown text
    /// edits), exhaustive so a new content type must declare its stack. This is
    /// what the Edit menu drives (`TabManager.activeUndoManager`) AND, for
    /// Markdown, what the engine's text view registers edits into (the same
    /// object travels to `NativeTextViewWrapper.undoManager`), so ⌘Z and the
    /// editor can never operate different stacks.
    var undoManager: UndoManager? { content.document.undoManager }

    // MARK: - Per-tab state forwarding (default-backed: harmless for non-pdf)

    /// Undo availability for the menu, mirrored per content type.
    var undoAvailability: UndoAvailability { content.document.undoAvailability }

    /// The activation snapshot, defaulting to a zero snapshot for content that
    /// has none. Read-only here; the capture happens on the content itself.
    var viewSnapshot: ViewSnapshot { content.pdf?.viewSnapshot ?? ViewSnapshot() }

    /// Per-tab UI state — lives on the SESSION because it is chrome state, not
    /// content state (the PDF sidebar/comments toggles and the Markdown outline
    /// toggle are the same kind of thing). Stored here so it works for every
    /// content type and rides intact when a tab moves windows. It was formerly
    /// stored on `PDFContent`, which silently no-op'd all setters for Markdown.
    var uiState = TabUIState()

    /// An admitted Markdown open travels with the tab while its old content
    /// remains usable. Closing or replacing the session cancels delivery.
    final class MarkdownOpen {
        let url: URL
        let access: MarkdownFileAccess
        let read: Task<MarkdownDocumentManager.PreparedOpen, Error>
        weak var owner: TabManager?
        var task: Task<Void, Never>?

        init(url: URL, isSecurityScoped: Bool, owner: TabManager) {
            self.url = url
            self.owner = owner
            access = MarkdownFileAccess(url: url, requestSecurityScope: isSecurityScoped)
            read = MarkdownDocumentManager.prepareOpen(access: access)
        }

        func cancel() { read.cancel(); task?.cancel() }
    }

    var pendingMarkdownOpen: MarkdownOpen?

    /// Pending password-unlock request, only meaningful for PDF content.
    var pendingUnlock: UnlockRequest? {
        get { content.pdf?.pendingUnlock }
        set { content.pdf?.pendingUnlock = newValue }
    }

    /// This tab's own security-scoped bookmark for cross-launch restore (S8), if
    /// its content holds the document under a security scope (minted once per held
    /// file access). `nil` for a non-scoped (Finder-opened / non-sandbox) or
    /// untitled tab — the capture path then mints one from the live document URL,
    /// else falls back to the path.
    var restoreBookmark: Data? { content.document.restoreBookmark }

    // MARK: - Content predicates (lifecycle / open-routing)

    /// Whether this tab holds real content (a loaded PDF, or a file-backed or
    /// non-empty Markdown buffer). An empty untitled placeholder reports false.
    var hasContent: Bool { content.document.hasContent }

    /// Whether an open may silently reuse this tab: a non-dirty placeholder with no
    /// durable identity. Once file-backed or edited, an open must not clobber it
    /// (ADR-0012 D6).
    var canReplaceWithoutPrompt: Bool { pendingMarkdownOpen == nil && content.document.canReplaceWithoutPrompt }

    /// Whether Save (⌘S) applies.
    var canSave: Bool { content.document.canSave }

    /// Whether Save As… (⌘⇧S) applies.
    var canSaveAs: Bool { content.document.canSaveAs }

    /// Whether this tab has unsaved changes.
    var isDirty: Bool { content.document.isDirty }

    // MARK: - Lifecycle / snapshot forwarding

    // Routed through `content.document`: the conformance forces every content type
    // to implement each of these (Markdown's snapshot methods are deliberate
    // no-ops), so a new content type still can't silently skip a lifecycle
    // boundary — the guarantee the old exhaustive switches gave.

    /// Ordered teardown on tab close.
    func cleanup() {
        pendingMarkdownOpen?.cancel()
        pendingMarkdownOpen = nil
        content.document.cleanup()
    }

    /// Captures the live view position into the activation snapshot when switching
    /// away (Markdown: no-op — deferred).
    func captureViewSnapshot() { content.document.captureViewSnapshot() }

    /// Re-applies the activation snapshot on re-activation (Markdown: no-op).
    func restoreViewSnapshot() { content.document.restoreViewSnapshot() }

    /// Clears the search part of the activation snapshot (Markdown: no-op).
    func clearSearchSnapshot() { content.document.clearSearchSnapshot() }
}
