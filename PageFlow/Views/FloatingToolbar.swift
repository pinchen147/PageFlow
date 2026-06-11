//
//  FloatingToolbar.swift
//  PageFlow
//
//  Floating Liquid Glass toolbar: document, zoom, annotation, and
//  page-navigation controls.
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

    private var toolbarMetrics: SettingsManager.ToolbarMetrics {
        SettingsManager.toolbarMetrics(for: settingsManager.toolbarScale)
    }

    var body: some View {
        toolbarContent
            .pageFlowLiquidGlassPanel(.toolbar)
            .frame(height: toolbarMetrics.containerHeight)
    }

    private var toolbarContent: some View {
        HStack(spacing: DesignTokens.spacingXS) {
            toolbarButton(icon: "doc", action: onOpenFilePicker)
            Divider().frame(height: 16)
            toolbarButton(
                icon: pdfManager.interactionMode == .pan ? "cursorarrow" : "hand.raised",
                action: { pdfManager.interactionMode = pdfManager.interactionMode == .pan ? .select : .pan },
                disabled: !pdfManager.hasDocument
            )
            toolbarButton(icon: "minus.magnifyingglass", action: { pdfManager.zoomOut() }, disabled: !pdfManager.hasDocument)
            toolbarButton(icon: "1.magnifyingglass", action: { pdfManager.resetZoom() }, disabled: !pdfManager.hasDocument)
            toolbarButton(icon: "plus.magnifyingglass", action: { pdfManager.zoomIn() }, disabled: !pdfManager.hasDocument)
            toolbarButton(
                icon: pdfManager.isAutoScaling ? "arrow.down.forward.and.arrow.up.backward.circle.fill" : "arrow.down.forward.and.arrow.up.backward.circle",
                action: handleFitButtonTap,
                disabled: !pdfManager.hasDocument
            )
            toolbarButton(
                icon: "sidebar.leading",
                action: { withAnimation(.easeInOut(duration: DesignTokens.animationFast)) { showingOutline.toggle() } },
                disabled: !pdfManager.hasDocument
            )
            toolbarButton(icon: "rotate.right", action: { pdfManager.rotateClockwise() }, disabled: !pdfManager.hasDocument)
            Divider().frame(height: 16)
            toolbarButton(
                icon: "underline",
                action: { annotationManager.underlineSelection(color: annotationManager.underlineColor) },
                disabled: !pdfManager.hasDocument
            )
            toolbarButton(
                icon: "highlighter",
                action: { annotationManager.highlightSelection(color: annotationManager.highlightColor) },
                disabled: !pdfManager.hasDocument
            )
            colorMenu
            toolbarButton(
                icon: "text.bubble",
                action: { _ = commentManager.addComment() },
                disabled: !pdfManager.hasDocument
            )
            toolbarButton(
                icon: showingComments ? "bubble.right.fill" : "bubble.right",
                action: { withAnimation(.easeInOut(duration: DesignTokens.animationFast)) { showingComments.toggle() } },
                disabled: !pdfManager.hasDocument
            )
            toolbarButton(
                icon: bookmarkManager.isBookmarked(pdfManager.currentPageIndex) ? "bookmark.fill" : "bookmark",
                action: { bookmarkManager.toggleBookmark(at: pdfManager.currentPageIndex) },
                disabled: !pdfManager.hasDocument
            )
            Divider().frame(height: 16)
            toolbarButton(icon: "arrow.uturn.backward", action: { pdfManager.goBack() }, disabled: !pdfManager.canGoBack)
            toolbarButton(icon: "arrow.uturn.forward", action: { pdfManager.goForward() }, disabled: !pdfManager.canGoForward)
            Divider().frame(height: 16)
            toolbarButton(icon: "chevron.left", action: { pdfManager.previousPage() }, disabled: !pdfManager.hasDocument || pdfManager.currentPageIndex == 0)
            toolbarButton(icon: "chevron.right", action: { pdfManager.nextPage() }, disabled: !pdfManager.hasDocument || pdfManager.currentPageIndex >= pdfManager.pageCount - 1)
        }
        .padding(.horizontal, toolbarMetrics.horizontalPadding)
        .padding(.vertical, toolbarMetrics.verticalPadding)
        .proximityField(isEnabled: settingsManager.isToolbarMagnificationEnabled)
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
            Image(systemName: "paintpalette")
                .font(.system(size: toolbarMetrics.iconSize, weight: .medium))
                .frame(width: toolbarMetrics.buttonSize, height: toolbarMetrics.buttonSize)
                .contentShape(RoundedRectangle(cornerRadius: DesignTokens.spacingSM))
                .pageFlowGlassControlLabel(
                    interactive: pdfManager.hasDocument
                )
                .proximityMagnified()
        }
        .buttonStyle(.plain)
        .disabled(!pdfManager.hasDocument)
        .opacity(pdfManager.hasDocument ? 1 : 0.3)
    }

    private func toolbarButton(icon: String, action: @escaping () -> Void, disabled: Bool = false) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: toolbarMetrics.iconSize, weight: .medium))
                .frame(width: toolbarMetrics.buttonSize, height: toolbarMetrics.buttonSize)
                .contentShape(RoundedRectangle(cornerRadius: DesignTokens.spacingSM))
                .pageFlowGlassControlLabel(
                    interactive: !disabled
                )
                .proximityMagnified()
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1.0)
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
