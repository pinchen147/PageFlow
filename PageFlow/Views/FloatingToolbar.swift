//
//  FloatingToolbar.swift
//  PageFlow
//
//  The PDF item set for the shared top-chrome toolbar slot: document, zoom,
//  annotation, and page-navigation controls inside the shared
//  `GlassToolbarShell` (see GlassToolbar.swift).
//

import SwiftUI

struct FloatingToolbar: View {
    @Bindable var pdfManager: PDFManager
    @Bindable var annotationManager: AnnotationManager
    @Bindable var commentManager: CommentManager
    @Bindable var bookmarkManager: BookmarkManager
    var onOpenFilePicker: () -> Void
    @Binding var showingOutline: Bool
    @Binding var showingComments: Bool
    var onFind: () -> Void
    @State private var settingsManager = SettingsManager.shared

    private var isBookmarked: Bool { bookmarkManager.isBookmarked(pdfManager.currentPageIndex) }

    var body: some View {
        GlassToolbarShell {
            GlassToolbarButton(icon: "doc", help: "Open a document", action: onOpenFilePicker, label: "Open")
            Divider().frame(height: 16)
            GlassToolbarButton(
                icon: pdfManager.interactionMode == .pan ? "cursorarrow" : "hand.raised",
                help: "Switch between pan and text selection",
                action: { pdfManager.interactionMode = pdfManager.interactionMode == .pan ? .select : .pan },
                disabled: !pdfManager.hasDocument,
                label: "Pan",
                isOn: pdfManager.interactionMode == .pan
            )
            ZoomToolbarGroup(
                canZoomOut: pdfManager.canZoomOut,
                canZoomIn: pdfManager.canZoomIn,
                onZoomOut: { pdfManager.zoomOut() },
                onZoomIn: { pdfManager.zoomIn() },
                reset: .init(help: "Actual size (100%)", disabled: !pdfManager.canResetZoom,
                             action: { pdfManager.resetZoom() }),
                fit: .init(isFitted: pdfManager.isAutoScaling, isAvailable: pdfManager.hasDocument,
                           action: { pdfManager.zoomToFit() })
            )
            SidebarFindToolbarGroup(
                showingSidebar: $showingOutline,
                canToggleSidebar: pdfManager.hasDocument,
                canFind: pdfManager.hasDocument,
                onFind: onFind
            )
            GlassToolbarButton(
                icon: "rotate.right",
                help: "Rotate page clockwise",
                action: { pdfManager.rotateClockwise() },
                disabled: !pdfManager.permissions.editPages,
                label: "Rotate"
            )
            Divider().frame(height: 16)
            GlassToolbarButton(
                icon: "underline",
                help: "Underline the selected text",
                action: { annotationManager.underlineSelection(color: annotationManager.underlineColor) },
                disabled: !pdfManager.permissions.annotate || !annotationManager.hasSelection,
                label: "Underline"
            )
            GlassToolbarButton(
                icon: "highlighter",
                help: "Highlight the selected text",
                action: { annotationManager.highlightSelection(color: annotationManager.highlightColor) },
                disabled: !pdfManager.permissions.annotate || !annotationManager.hasSelection,
                label: "Highlight"
            )
            AnnotationColorMenu(
                isUnderlineColor: { $0.color.isEqual(to: annotationManager.underlineColor) },
                isHighlightColor: { $0.color.isEqual(to: annotationManager.highlightColor) },
                chooseUnderline: { annotationManager.underlineColor = $0.color },
                chooseHighlight: { annotationManager.highlightColor = $0.color },
                isAvailable: pdfManager.hasDocument
            )
            GlassToolbarButton(
                icon: "text.bubble",
                help: "Add a comment",
                action: { _ = commentManager.addComment() },
                disabled: !pdfManager.permissions.annotate,
                label: "Add Comment"
            )
            GlassToolbarButton(
                icon: showingComments ? "bubble.right.fill" : "bubble.right",
                help: "Show or hide comments",
                action: { withAnimation(.easeInOut(duration: DesignTokens.animationFast)) { showingComments.toggle() } },
                disabled: !pdfManager.hasDocument,
                label: "Comments",
                isOn: showingComments
            )
            GlassToolbarButton(
                icon: isBookmarked ? "bookmark.fill" : "bookmark",
                help: "Add or remove a bookmark on this page",
                action: { bookmarkManager.toggleBookmark(at: pdfManager.currentPageIndex) },
                disabled: !pdfManager.hasDocument,
                label: "Bookmark",
                isOn: isBookmarked
            )
            Divider().frame(height: 16)
            GlassToolbarButton(icon: "arrow.uturn.backward", help: "Go back", action: { pdfManager.goBack() },
                               disabled: !pdfManager.canGoBack, label: "Back")
            GlassToolbarButton(icon: "arrow.uturn.forward", help: "Go forward", action: { pdfManager.goForward() },
                               disabled: !pdfManager.canGoForward, label: "Forward")
            Divider().frame(height: 16)
            GlassToolbarButton(icon: "chevron.left", help: "Previous page", action: { pdfManager.previousPage() },
                               disabled: !pdfManager.hasDocument || pdfManager.currentPageIndex == 0,
                               label: "Previous Page")
            GlassToolbarButton(icon: "chevron.right", help: "Next page", action: { pdfManager.nextPage() },
                               disabled: !pdfManager.hasDocument || pdfManager.currentPageIndex >= pdfManager.pageCount - 1,
                               label: "Next Page")
        }
    }
}
