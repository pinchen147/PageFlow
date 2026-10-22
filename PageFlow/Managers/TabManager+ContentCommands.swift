//
//  TabManager+ContentCommands.swift
//  PageFlow
//
//  The menu layer's ONE routing authority for content-aware commands: every
//  gate and action here is an exhaustive switch over the active tab's content
//  (`activeRender` / `TabSession` forwarders), so menu items stay one-liners
//  and never re-derive content routing by hand — and a future content type is
//  a compile error at every command, never a silent no-op.
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

    var activeFindDriver: (any FindDriving)? {
        switch activeRender {
        case .pdf(let runtime):
            return PDFFindDriver(searchManager: runtime.searchManager, pdfManager: runtime.pdfManager)
        case .markdown(let runtime): return runtime.content.searchManager
        case nil: return nil
        }
    }

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

    /// Whether Print (⌘P) applies. PDF: a document is open. Markdown: the tab has
    /// content (a file URL or any typed text) — ⌘P prints the styled Live-Preview
    /// text (S9). An empty untitled buffer is the only no-op case (nothing to print).
    /// This is exactly `TabSession.hasContent`.
    var canPrint: Bool {
        guard activeSession?.hasContent == true else { return false }
        if case .pdf(let runtime) = activeRender { return runtime.pdfManager.permissions.print }
        return true
    }

    /// Whether markdown formatting commands (⌘B/⌘I/heading/list/link) apply: the
    /// active tab is a Markdown tab with content (a file URL or any typed text).
    /// An empty untitled buffer is the only no-op case — there is nothing to format.
    var canFormatMarkdown: Bool {
        guard let content = activeSession?.content else { return false }
        switch content {
        case .pdf: return false
        case .markdown(let c):
            return c.documentManager.hasDocumentURL || !c.documentManager.text.isEmpty
        }
    }

    /// The active tab accepts view-level chrome commands (zoom, sidebar): a PDF
    /// with a loaded document, or any Markdown tab (its editor is always a surface).
    var activeContentAcceptsViewCommands: Bool {
        switch activeRender {
        case .pdf(let runtime): return runtime.pdfManager.hasDocument
        case .markdown: return true
        case nil: return false
        }
    }

    /// ⌘U: PDF underlines the selection as an annotation; Markdown wraps the
    /// selection in `<u>…</u>` via the format bus.
    var canUnderline: Bool {
        switch activeRender {
        case .pdf(let runtime): return runtime.pdfManager.permissions.annotate
        // Markdown's Underline is the Format menu's, under its own shortcut.
        case .markdown, nil: return false
        }
    }

    /// The Go menu's jump dialog, content-routed: pages for PDF, lines for
    /// Markdown (both bind the same per-tab `uiState.showingGoToPage` slot).
    var goToDialogTitle: String {
        switch activeRender {
        case .markdown: return "Go to Line…"
        case .pdf, nil: return "Go to Page…"
        }
    }

    var canShowGoToDialog: Bool {
        switch activeRender {
        case .pdf(let runtime): return runtime.pdfManager.hasDocument
        case .markdown: return true
        case nil: return false
        }
    }

    /// Content-routed Go Back/Forward: PDF navigates its page-view history;
    /// Markdown navigates the tab's scroll-jump trail (outline / go-to-line).
    var canGoBack: Bool {
        switch activeRender {
        case .pdf(let runtime): return runtime.pdfManager.canGoBack
        case .markdown(let runtime): return runtime.content.canGoBack
        case nil: return false
        }
    }

    var canGoForward: Bool {
        switch activeRender {
        case .pdf(let runtime): return runtime.pdfManager.canGoForward
        case .markdown(let runtime): return runtime.content.canGoForward
        case nil: return false
        }
    }

    // MARK: - Command actions

    /// Posts a markdown format command to the active tab's editor (no-op if the
    /// active tab is not a markdown tab). The single entry the menu + toolbar use.
    func requestMarkdownFormat(_ command: MarkdownFormatCommand) {
        activeMarkdownContent?.requestFormat(command)
    }

    /// Content-routed zoom: both PDF and Markdown visually magnify the document
    /// (Markdown per-document, persisted — PDF parity), not a font-size change.
    func zoomIn() {
        switch activeRender {
        case .pdf(let runtime): runtime.pdfManager.zoomIn()
        case .markdown: activeMarkdownContent?.zoomIn()
        case nil: break
        }
    }

    func zoomOut() {
        switch activeRender {
        case .pdf(let runtime): runtime.pdfManager.zoomOut()
        case .markdown: activeMarkdownContent?.zoomOut()
        case nil: break
        }
    }

    func resetZoom() {
        switch activeRender {
        case .pdf(let runtime): runtime.pdfManager.resetZoom()
        case .markdown: activeMarkdownContent?.resetZoom()
        case nil: break
        }
    }

    func underlineActiveSelection() {
        switch activeRender {
        case .pdf(let runtime): runtime.annotationManager.underlineSelection()
        case .markdown: requestMarkdownFormat(.underline)
        case nil: break
        }
    }

    func goBack() {
        switch activeRender {
        case .pdf(let runtime): runtime.pdfManager.goBack()
        case .markdown(let runtime): runtime.content.goBack()
        case nil: break
        }
    }

    func goForward() {
        switch activeRender {
        case .pdf(let runtime): runtime.pdfManager.goForward()
        case .markdown(let runtime): runtime.content.goForward()
        case nil: break
        }
    }
}
