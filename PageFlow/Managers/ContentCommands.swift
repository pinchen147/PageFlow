//
//  ContentCommands.swift
//  PageFlow
//
//  The command surface the menus and chrome ask of the active tab — zoom,
//  Back/Forward, Go menu pages, comments, highlights, find, print — with one conformance
//  per content type. `TabManager.activeCommands` makes the one content switch;
//  the TabManager command members forward to it, so each type's rules live
//  together here instead of in a switch per command.
//
//  Every type answers the commands all three support (find, view gating,
//  Back/Forward, zoom), so a new content type must decide them. The rest
//  default to "not supported", and a type overrides only what it offers.
//

import Foundation
import MarkdownEngine

@MainActor
protocol ContentCommands {

    // MARK: Every content type

    var findDriver: (any FindDriving)? { get }
    /// Accepts view-level chrome commands (zoom, sidebar).
    var acceptsViewCommands: Bool { get }

    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    func goBack()
    func goForward()

    var canZoomIn: Bool { get }
    var canZoomOut: Bool { get }
    var canResetZoom: Bool { get }
    func zoomIn()
    func zoomOut()
    func resetZoom()

    /// A link's `#fragment` into this document, once it has opened at `url`.
    /// Returns false when this tab doesn't hold it yet.
    func followLinkFragment(_ fragment: String, at url: URL) async -> Bool

    // MARK: Optional (default: not supported)

    var resetZoomTitle: String { get }
    var zoomToFitTitle: String { get }
    var canZoomToFit: Bool { get }
    func zoomToFit()

    /// Print is allowed by the content itself; the tab must also have content.
    var allowsPrinting: Bool { get }

    var goToDialogTitle: String { get }
    var canShowGoToDialog: Bool { get }

    /// What View ▸ Show/Hide names the panel: a book's are Notes.
    var commentsTitle: String { get }
    var isShowingComments: Bool { get }
    var canToggleComments: Bool { get }
    func toggleComments()

    /// Tools ▸ Highlight Selection and Add Comment (a book's Add Note).
    var canHighlightSelection: Bool { get }
    func highlightSelection()
    /// ⌘U: an annotation in a PDF, an underline highlight in a book. Markdown's
    /// Underline is the Format menu's, under its own shortcut.
    var canUnderline: Bool { get }
    func underlineSelection()
    var addCommentTitle: String { get }
    /// One configurable Comment/Note action across content formats.
    var addCommentShortcutID: String { get }
    var canAddComment: Bool { get }
    func addComment()

    var canGoToNextPage: Bool { get }
    var canGoToPreviousPage: Bool { get }
    /// First Page, Last Page and Toggle Bookmark apply.
    var hasPages: Bool { get }
    func goToNextPage()
    func goToPreviousPage()
    func goToFirstPage()
    func goToLastPage()
    func toggleBookmark()
}

extension ContentCommands {
    var resetZoomTitle: String { "Actual Size" }
    var zoomToFitTitle: String { "Zoom to Fit" }
    var canZoomToFit: Bool { false }
    func zoomToFit() {}

    var allowsPrinting: Bool { false }

    var goToDialogTitle: String { "Go to Page…" }
    var canShowGoToDialog: Bool { false }

    var commentsTitle: String { "Comments" }
    var isShowingComments: Bool { false }
    var canToggleComments: Bool { false }
    func toggleComments() {}

    var canHighlightSelection: Bool { false }
    func highlightSelection() {}
    var canUnderline: Bool { false }
    func underlineSelection() {}
    var addCommentTitle: String { "Add Comment" }
    var addCommentShortcutID: String { "comment" }
    var canAddComment: Bool { false }
    func addComment() {}

    var canGoToNextPage: Bool { false }
    var canGoToPreviousPage: Bool { false }
    var hasPages: Bool { false }
    func goToNextPage() {}
    func goToPreviousPage() {}
    func goToFirstPage() {}
    func goToLastPage() {}
    func toggleBookmark() {}
}

// MARK: - PDF

/// A PDF tab's commands. Its comments panel is per-tab UI state on the
/// session, not part of the PDF managers, so the adapter carries the session.
struct PDFTabCommands: ContentCommands {
    let runtime: TabRuntime
    let session: TabSession

    private var pdf: PDFManager { runtime.pdfManager }

    var findDriver: (any FindDriving)? {
        PDFFindDriver(searchManager: runtime.searchManager, pdfManager: pdf)
    }
    var acceptsViewCommands: Bool { pdf.hasDocument }

    var canGoBack: Bool { pdf.canGoBack }
    var canGoForward: Bool { pdf.canGoForward }
    func goBack() { pdf.goBack() }
    func goForward() { pdf.goForward() }

    var canZoomIn: Bool { pdf.canZoomIn }
    var canZoomOut: Bool { pdf.canZoomOut }
    var canResetZoom: Bool { pdf.canResetZoom }
    func zoomIn() { pdf.zoomIn() }
    func zoomOut() { pdf.zoomOut() }
    func resetZoom() { pdf.resetZoom() }

    func followLinkFragment(_ fragment: String, at url: URL) async -> Bool {
        if let page = pdf.pageIndex(ofHeading: fragment) { pdf.followPageLink(page, for: url) }
        return true
    }

    /// Already fitted, the command has nothing to do.
    var canZoomToFit: Bool { pdf.hasDocument && !pdf.isAutoScaling }
    func zoomToFit() { pdf.zoomToFit() }

    var allowsPrinting: Bool { pdf.permissions.print }

    var canShowGoToDialog: Bool { pdf.hasDocument }

    var isShowingComments: Bool { session.uiState.showingComments }
    var canToggleComments: Bool { pdf.hasDocument }
    func toggleComments() { session.uiState.showingComments.toggle() }

    var canHighlightSelection: Bool { pdf.permissions.annotate && runtime.annotationManager.hasSelection }
    func highlightSelection() { runtime.annotationManager.highlightSelection() }
    var canUnderline: Bool { canHighlightSelection }
    func underlineSelection() { runtime.annotationManager.underlineSelection() }
    var canAddComment: Bool { pdf.permissions.annotate }
    func addComment() { _ = runtime.commentManager.addComment() }

    var canGoToNextPage: Bool { pdf.hasDocument && pdf.currentPageIndex < pdf.pageCount - 1 }
    var canGoToPreviousPage: Bool { pdf.hasDocument && pdf.currentPageIndex > 0 }
    var hasPages: Bool { pdf.hasDocument }
    func goToNextPage() { pdf.nextPage() }
    func goToPreviousPage() { pdf.previousPage() }
    func goToFirstPage() { pdf.goToFirstPage() }
    func goToLastPage() { pdf.goToLastPage() }
    func toggleBookmark() { runtime.bookmarkManager.toggleBookmark(at: pdf.currentPageIndex) }
}

// MARK: - Markdown

/// A note fits its reading row and has no page commands or bookmarks.
/// Its jump dialog goes to a line, and its comments show in the note.
extension MarkdownRuntime: ContentCommands {
    var findDriver: (any FindDriving)? { content.searchManager }
    /// The editor is always a surface.
    var acceptsViewCommands: Bool { true }

    var canGoBack: Bool { content.canGoBack }
    var canGoForward: Bool { content.canGoForward }
    func goBack() { content.goBack() }
    func goForward() { content.goForward() }

    var canZoomIn: Bool { content.canZoomIn }
    var canZoomOut: Bool { content.canZoomOut }
    var canResetZoom: Bool { content.canResetZoom }
    func zoomIn() { content.zoomIn() }
    func zoomOut() { content.zoomOut() }
    func resetZoom() { content.resetZoom() }
    var zoomToFitTitle: String { "Fit Text to Window" }
    var canZoomToFit: Bool { !content.isAwaitingOpen }
    func zoomToFit() { content.zoomToFit() }

    func followLinkFragment(_ fragment: String, at url: URL) async -> Bool {
        guard content.documentManager.documentURL?.pageFlowCanonicalDocumentURL == url.pageFlowCanonicalDocumentURL else { return false }
        if let thread = MarkdownEditorController.commentThreadID(inFragment: fragment) {
            content.openCommentThread(thread)
        } else {
            content.revealHeading(fragment)
        }
        return true
    }

    /// ⌘P prints the styled Live-Preview text.
    var allowsPrinting: Bool { true }

    var goToDialogTitle: String { "Go to Line…" }
    var canShowGoToDialog: Bool { true }

    var isShowingComments: Bool { content.isShowingComments }
    var canToggleComments: Bool { true }
    func toggleComments() { content.toggleCommentsHidden() }

    /// Comments on the selection, or opens the comment at the caret. With
    /// neither, the editor says what to select, as PDF's needs no selection.
    var addCommentShortcutID: String { "comment" }
    var canAddComment: Bool { !content.isAwaitingOpen }
    func addComment() { content.addComment() }
}

// MARK: - EPUB

/// A book still opening (or one that failed) has no pages to zoom, fit or
/// reflow or print. Its reset is Reflow to Fit. Highlights and notes act on
/// the text selected on a page.
extension EPUBRuntime: ContentCommands {
    private var hasBook: Bool { content.book != nil }

    var findDriver: (any FindDriving)? { content.searchManager }
    var acceptsViewCommands: Bool { hasBook }

    var canGoBack: Bool { content.canGoBack }
    var canGoForward: Bool { content.canGoForward }
    func goBack() { content.goBack() }
    func goForward() { content.goForward() }

    var canZoomIn: Bool { hasBook && content.canZoomIn }
    var canZoomOut: Bool { hasBook && content.canZoomOut }
    /// Nothing to do once reflowed.
    var canResetZoom: Bool { hasBook && content.zoom != .reflow }
    func zoomIn() { content.zoomIn() }
    func zoomOut() { content.zoomOut() }
    func resetZoom() { content.reflowToFit() }

    func followLinkFragment(_ fragment: String, at url: URL) async -> Bool {
        await content.load().value
        content.goToContentsEntry(headed: fragment)
        return true
    }

    /// A reflowable book's natural size is the window's, so it reflows
    /// instead of showing 100%.
    var resetZoomTitle: String { "Reflow to Fit" }
    /// Already fitted, the command has nothing to do; from Reflow to Fit it
    /// stops the pages following the window.
    var canZoomToFit: Bool { hasBook && content.zoom != .fit }
    func zoomToFit() { content.zoomToFit() }

    /// A ready book lays out for the paper the print panel has.
    var allowsPrinting: Bool { content.isReady }

    var canShowGoToDialog: Bool { hasPages }

    var canGoToNextPage: Bool { content.canTurn(forward: true) }
    var canGoToPreviousPage: Bool { content.canTurn(forward: false) }
    var hasPages: Bool { content.pagination.pageCount > 0 }
    func goToNextPage() { content.turnPage(forward: true) }
    func goToPreviousPage() { content.turnPage(forward: false) }
    func goToFirstPage() { content.jump(toPage: 0) }
    func goToLastPage() { content.jump(toPage: content.pagination.pageCount - 1) }
    func toggleBookmark() { content.toggleBookmarkAtCurrentLocation() }

    var canHighlightSelection: Bool { hasBook && content.highlights.canAnnotateSelection }
    func highlightSelection() { content.highlights.highlightSelection() }
    var canUnderline: Bool { canHighlightSelection }
    func underlineSelection() { content.highlights.highlightSelection(style: .underline) }
    var addCommentTitle: String { "Add Note" }
    var canAddComment: Bool { hasBook && content.canAddNote }
    func addComment() { content.addNote() }

    /// View ▸ Show Notes shows the Notes panel, as Show Comments shows PDF's comments.
    var commentsTitle: String { "Notes" }
    var isShowingComments: Bool { content.highlights.isPanelShown }
    var canToggleComments: Bool { hasBook }
    func toggleComments() { content.highlights.togglePanel() }
}
