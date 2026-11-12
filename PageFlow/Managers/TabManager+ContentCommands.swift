//
//  TabManager+ContentCommands.swift
//  PageFlow
//
//  The menu layer's content-aware commands. `activeCommands` is the one switch
//  over the active tab's content; every gate and action forwards to that
//  content's `ContentCommands` conformance, so menu items stay one-liners and
//  never re-derive content routing by hand. Commands only one content type has
//  (the Markdown format bus) match that type directly.
//

import Foundation

extension TabManager {

    // MARK: - Command predicates (menu gating)

    /// Whether Save (⌘S) applies. PDF requires an open document. Markdown keeps
    /// Save available to reconcile pending native edits; untitled routes to
    /// Save-As. Delegates to the per-content `TabSession.canSave`.
    var canSave: Bool { activeSession?.canSave ?? false }

    /// Whether Save As… (⌘⇧S) applies. PDF: a document is open (as today).
    /// Markdown: always — even an untitled buffer can be written to a new file.
    /// Delegates to the per-content `TabSession.canSaveAs`.
    var canSaveAs: Bool { activeSession?.canSaveAs ?? false }

    /// Whether Find (⌘F) applies. PDF: a document is open. Markdown: the tab has
    /// content (a file URL or any typed text) — the shared Find surface (S7a) now
    /// routes ⌘F into the editor, so an empty buffer is the only no-op case. This is
    /// exactly `TabSession.hasContent`.
    var canFind: Bool { activeSession?.hasContent ?? false }

    var activeFindDriver: (any FindDriving)? { activeCommands?.findDriver }

    var canReplace: Bool { canFind && activeFindDriver is any FindReplacing }
    var canNavigateFind: Bool { canFind && activeFindDriver?.query.isEmpty == false }

    func requestFind(showReplacement: Bool = false) {
        guard canFind, !showReplacement || canReplace else { return }
        if showReplacement {
            (activeFindDriver as? any FindReplacing)?.setShowingReplacement(true)
        }
        showingSearch = true
        searchFocusRequest += 1
    }

    /// Whether Print (⌘P) applies: the tab has content (a loaded PDF, or a note
    /// with a file URL or any typed text) and its type prints it — a PDF its
    /// permissions allow, any note's styled Live-Preview text, a book once ready.
    var canPrint: Bool {
        activeSession?.hasContent == true && activeCommands?.allowsPrinting == true
    }

    /// Whether markdown formatting commands (⌘B/⌘I/heading/list/link) apply: the
    /// active tab is a Markdown tab with content (a file URL or any typed text).
    /// An empty untitled buffer is the only no-op case — there is nothing to format.
    var canFormatMarkdown: Bool {
        guard let content = activeMarkdownContent else { return false }
        return content.documentManager.hasDocumentURL || !content.documentManager.text.isEmpty
    }

    /// The active tab's command surface. `nil` when no tab is active.
    var activeCommands: (any ContentCommands)? { activeTabID.flatMap(commands(for:)) }

    /// A tab's command surface: the one content switch commands route through.
    func commands(for tabID: UUID) -> (any ContentCommands)? {
        guard let session = sessions[tabID] else { return nil }
        switch renderModel(for: tabID) {
        case .pdf(let runtime): return PDFTabCommands(runtime: runtime, session: session)
        case .markdown(let runtime): return runtime
        case .epub(let runtime): return runtime
        case nil: return nil
        }
    }

    /// The active tab accepts view-level chrome commands (zoom, sidebar): a PDF
    /// with a loaded document, any Markdown tab, or an opened book.
    var activeContentAcceptsViewCommands: Bool { activeCommands?.acceptsViewCommands ?? false }

    var canUnderline: Bool { activeCommands?.canUnderline ?? false }

    /// The Go menu's jump dialog, content-routed: pages for PDF and EPUB, lines
    /// for Markdown (all bind the same per-tab `uiState.showingGoToPage` slot).
    var goToDialogTitle: String { activeCommands?.goToDialogTitle ?? "Go to Page…" }
    var canShowGoToDialog: Bool { activeCommands?.canShowGoToDialog ?? false }

    /// View ▸ Show Comments, content-routed: PDF's comments panel, or whether
    /// a Markdown note's comments show (in the margin or the list).
    var isShowingComments: Bool { activeCommands?.isShowingComments ?? false }
    /// "Comments", or a book's "Notes", for the View menu's Show/Hide item.
    var commentsTitle: String { activeCommands?.commentsTitle ?? "Comments" }
    var canToggleComments: Bool { activeCommands?.canToggleComments ?? false }

    // MARK: - Pages (Go menu, Toggle Bookmark)

    /// Paged documents (PDF, EPUB) turn pages and carry bookmarks; a note has neither.
    var canGoToNextPage: Bool { activeCommands?.canGoToNextPage ?? false }
    var canGoToPreviousPage: Bool { activeCommands?.canGoToPreviousPage ?? false }
    /// First Page, Last Page and Toggle Bookmark: any paged document with pages.
    var hasPages: Bool { activeCommands?.hasPages ?? false }

    func goToNextPage() { activeCommands?.goToNextPage() }
    func goToPreviousPage() { activeCommands?.goToPreviousPage() }
    func goToFirstPage() { activeCommands?.goToFirstPage() }
    func goToLastPage() { activeCommands?.goToLastPage() }
    func toggleBookmark() { activeCommands?.toggleBookmark() }

    /// Content-routed Go Back/Forward: PDF navigates its page-view history,
    /// Markdown the tab's scroll-jump trail (outline / go-to-line), EPUB its jumps.
    var canGoBack: Bool { activeCommands?.canGoBack ?? false }
    var canGoForward: Bool { activeCommands?.canGoForward ?? false }
    func goBack() { activeCommands?.goBack() }
    func goForward() { activeCommands?.goForward() }

    // MARK: - Command actions

    /// Posts a markdown format command to the active tab's editor (no-op if the
    /// active tab is not a markdown tab). The single entry the menu + toolbar use.
    func requestMarkdownFormat(_ command: MarkdownFormatCommand) {
        activeMarkdownContent?.requestFormat(command)
    }

    /// Content-routed zoom: every type visually magnifies the document
    /// (Markdown per-document, persisted — PDF parity), not a font-size change.
    /// The gates are off at the zoom limits, and the reset off once it would
    /// change nothing.
    func zoomIn() { activeCommands?.zoomIn() }
    func zoomOut() { activeCommands?.zoomOut() }
    func resetZoom() { activeCommands?.resetZoom() }
    var canZoomIn: Bool { activeCommands?.canZoomIn ?? false }
    var canZoomOut: Bool { activeCommands?.canZoomOut ?? false }
    var canResetZoom: Bool { activeCommands?.canResetZoom ?? false }

    /// The reset zoom command's name: EPUB reflows instead of showing 100%.
    var resetZoomTitle: String { activeCommands?.resetZoomTitle ?? "Actual Size" }

    /// Fit the active document's pages or Markdown reading row.
    var zoomToFitTitle: String { activeCommands?.zoomToFitTitle ?? "Zoom to Fit" }
    func zoomToFit() { activeCommands?.zoomToFit() }
    var canZoomToFit: Bool { activeCommands?.canZoomToFit ?? false }

    /// ⌘U: PDF underlines the selection as an annotation; Markdown wraps the
    /// selection in `<u>…</u>` via the format bus; a book underlines it as a
    /// highlight.
    func underlineActiveSelection() { activeCommands?.underlineSelection() }

    func toggleComments() { activeCommands?.toggleComments() }

    /// Tools ▸ Highlight Selection and Add Comment, content-routed: PDF
    /// annotations, or a book's highlights and notes.
    var canHighlightSelection: Bool { activeCommands?.canHighlightSelection ?? false }
    func highlightSelection() { activeCommands?.highlightSelection() }
    var addCommentTitle: String { activeCommands?.addCommentTitle ?? "Add Comment" }
    var addCommentShortcutID: String { activeCommands?.addCommentShortcutID ?? "comment" }
    var canAddComment: Bool { activeCommands?.canAddComment ?? false }
    func addComment() { activeCommands?.addComment() }
}
