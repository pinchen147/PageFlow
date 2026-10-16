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
    @State private var lastFitTapTime: Date?
    @State private var settingsManager = SettingsManager.shared
    private let doubleTapWindow: TimeInterval = 0.3

    var body: some View {
        GlassToolbarShell {
            GlassToolbarButton(icon: "doc", help: "Open a PDF", action: onOpenFilePicker)
            Divider().frame(height: 16)
            GlassToolbarButton(
                icon: pdfManager.interactionMode == .pan ? "cursorarrow" : "hand.raised",
                help: "Switch between pan and text selection",
                action: { pdfManager.interactionMode = pdfManager.interactionMode == .pan ? .select : .pan },
                disabled: !pdfManager.hasDocument
            )
            GlassToolbarButton(icon: "minus.magnifyingglass", help: "Zoom out", action: { pdfManager.zoomOut() }, disabled: !pdfManager.hasDocument)
            GlassToolbarButton(icon: "1.magnifyingglass", help: "Actual size (100%)", action: { pdfManager.resetZoom() }, disabled: !pdfManager.hasDocument)
            GlassToolbarButton(icon: "plus.magnifyingglass", help: "Zoom in", action: { pdfManager.zoomIn() }, disabled: !pdfManager.hasDocument)
            GlassToolbarButton(
                icon: pdfManager.isAutoScaling ? "arrow.down.forward.and.arrow.up.backward.circle.fill" : "arrow.down.forward.and.arrow.up.backward.circle",
                help: "Fit page to window (double-click to toggle auto-fit)",
                action: handleFitButtonTap,
                disabled: !pdfManager.hasDocument
            )
            GlassToolbarButton(
                icon: "sidebar.leading",
                help: "Show or hide the sidebar",
                action: { withAnimation(.easeInOut(duration: DesignTokens.animationFast)) { showingOutline.toggle() } },
                disabled: !pdfManager.hasDocument
            )
            GlassToolbarButton(icon: "rotate.right", help: "Rotate page clockwise", action: { pdfManager.rotateClockwise() }, disabled: !pdfManager.permissions.editPages)
            Divider().frame(height: 16)
            GlassToolbarButton(
                icon: "underline",
                help: "Underline the selected text",
                action: { annotationManager.underlineSelection(color: annotationManager.underlineColor) },
                disabled: !pdfManager.permissions.annotate
            )
            GlassToolbarButton(
                icon: "highlighter",
                help: "Highlight the selected text",
                action: { annotationManager.highlightSelection(color: annotationManager.highlightColor) },
                disabled: !pdfManager.permissions.annotate
            )
            colorMenu
            GlassToolbarButton(
                icon: "text.bubble",
                help: "Add a comment",
                action: { _ = commentManager.addComment() },
                disabled: !pdfManager.permissions.annotate
            )
            GlassToolbarButton(
                icon: showingComments ? "bubble.right.fill" : "bubble.right",
                help: "Show or hide comments",
                action: { withAnimation(.easeInOut(duration: DesignTokens.animationFast)) { showingComments.toggle() } },
                disabled: !pdfManager.hasDocument
            )
            GlassToolbarButton(
                icon: bookmarkManager.isBookmarked(pdfManager.currentPageIndex) ? "bookmark.fill" : "bookmark",
                help: "Add or remove a bookmark on this page",
                action: { bookmarkManager.toggleBookmark(at: pdfManager.currentPageIndex) },
                disabled: !pdfManager.hasDocument
            )
            Divider().frame(height: 16)
            GlassToolbarButton(icon: "arrow.uturn.backward", help: "Go back", action: { pdfManager.goBack() }, disabled: !pdfManager.canGoBack)
            GlassToolbarButton(icon: "arrow.uturn.forward", help: "Go forward", action: { pdfManager.goForward() }, disabled: !pdfManager.canGoForward)
            Divider().frame(height: 16)
            GlassToolbarButton(icon: "chevron.left", help: "Previous page", action: { pdfManager.previousPage() }, disabled: !pdfManager.hasDocument || pdfManager.currentPageIndex == 0)
            GlassToolbarButton(icon: "chevron.right", help: "Next page", action: { pdfManager.nextPage() }, disabled: !pdfManager.hasDocument || pdfManager.currentPageIndex >= pdfManager.pageCount - 1)
        }
    }

    private var colorMenu: some View {
        Menu {
            Text("Underline").font(.caption)
            ForEach(settingsManager.underlinePresets) { preset in
                Button {
                    annotationManager.underlineColor = preset.color
                } label: {
                    HStack {
                        Circle().fill(Color(nsColor: preset.color)).frame(width: 12, height: 12)
                        Text(preset.name)
                        if preset.color.isEqual(to: annotationManager.underlineColor) {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Divider()
            Text("Highlight").font(.caption)
            ForEach(settingsManager.highlightPresets) { preset in
                Button {
                    annotationManager.highlightColor = preset.color
                } label: {
                    HStack {
                        Circle().fill(Color(nsColor: preset.color)).frame(width: 12, height: 12)
                        Text(preset.name)
                        if preset.color.isEqual(to: annotationManager.highlightColor) {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            GlassToolbarLabel(icon: "paintpalette", interactive: pdfManager.hasDocument)
        }
        .buttonStyle(.plain)
        .disabled(!pdfManager.hasDocument)
        .opacity(pdfManager.hasDocument ? 1 : 0.3)
        .toolbarTooltip("Choose underline and highlight colors", enabled: settingsManager.showTooltips)
    }

    private func handleFitButtonTap() {
        let now = Date()

        if let lastTap = lastFitTapTime,
           now.timeIntervalSince(lastTap) < doubleTapWindow {
            pdfManager.toggleAutoScale()
            lastFitTapTime = nil
        } else {
            pdfManager.requestFitOnce()
            lastFitTapTime = now
        }
    }
}
