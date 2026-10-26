//
//  TabRenderView.swift
//  PageFlow
//
//  The ONE mount point for a tab's body — the single `switch TabRender` that
//  routes a PDF tab to `PDFTabView` and a Markdown tab to `MarkdownTabView`.
//  The warm ZStack (`TabContainerView`) mounts this once per warm tab and applies
//  only its OWN outer modifiers (stacking, visibility, hit-testing), so the
//  ~13-argument view construction lives in exactly one place.
//

import SwiftUI

struct TabRenderView: View {
    let render: TabRender
    /// Whether this tab is the active one (drives inner chrome; the caller also
    /// uses it for its own outer modifiers — same `render.id == activeTabID` rule).
    let isActive: Bool
    /// Whether this tab is on-screen (the active tab; warm tabs stay hidden).
    let isDisplayed: Bool
    @Binding var showingSearch: Bool
    let searchFocusRequest: Int
    let tabManager: TabManager

    var body: some View {
        switch render {
        case .pdf(let runtime):
            PDFTabView(
                tabID: runtime.tabID,
                pdfManager: runtime.pdfManager,
                searchManager: runtime.searchManager,
                annotationManager: runtime.annotationManager,
                commentManager: runtime.commentManager,
                bookmarkManager: runtime.bookmarkManager,
                tabUndoManager: runtime.undoManager,
                isActive: isActive,
                isDisplayed: isDisplayed,
                showingSearch: $showingSearch,
                searchFocusRequest: searchFocusRequest,
                tabManager: tabManager,
                // Selecting the already-active tab (warm path) is a harmless no-op,
                // so both mount sites can wire focus the same way.
                onRequestFocus: { tabManager.selectTab(runtime.tabID) }
            )
        case .markdown(let runtime):
            MarkdownTabView(
                tabID: runtime.tabID,
                content: runtime.content,
                isActive: isActive,
                isDisplayed: isDisplayed,
                onRequestFocus: { [weak tabManager, tabID = runtime.tabID] in tabManager?.selectTab(tabID) },
                retainedScrollDocumentIds: tabManager.renderedDocumentIds,
                showingSearch: $showingSearch,
                searchFocusRequest: searchFocusRequest,
                tabManager: tabManager
            )
        }
    }
}
