//
//  FloatingToolbar.swift
//  PageFlow
//
//  Floating glassmorphism toolbar with collapse functionality
//

import SwiftUI

struct FloatingToolbar: View {
    @Bindable var pdfManager: PDFManager
    @Bindable var annotationManager: AnnotationManager
    @Bindable var commentManager: CommentManager
    @Bindable var bookmarkManager: BookmarkManager
    @Binding var showingFileImporter: Bool
    @Binding var isTopBarHovered: Bool
    @Binding var showingOutline: Bool
    @Binding var showingComments: Bool
    @State private var lastFitTapTime: Date?
    private let doubleTapWindow: TimeInterval = 0.3

    var body: some View {
        let isVisible = isTopBarHovered

        expandedContainer
        .frame(height: DesignTokens.collapsedToolbarSize)
        .animation(.easeInOut(duration: DesignTokens.animationFast), value: isTopBarHovered)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(.easeInOut(duration: DesignTokens.animationFast), value: isVisible)
    }

    private var expandedContainer: some View {
        expandedToolbar
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.floatingToolbarCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.floatingToolbarCornerRadius)
                    .fill(DesignTokens.floatingToolbarBase.opacity(0.12))
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.floatingToolbarCornerRadius)
                    .strokeBorder(.white.opacity(0.22))
                    .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
    }

    private var expandedToolbar: some View {
        HStack(spacing: DesignTokens.spacingXS) {
            toolbarButton(icon: "doc", action: { showingFileImporter = true })
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
                icon: showingOutline ? "sidebar.leading" : "sidebar.leading",
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
            toolbarButton(icon: "chevron.left", action: { pdfManager.previousPage() }, disabled: !pdfManager.hasDocument || pdfManager.currentPageIndex == 0)
            toolbarButton(icon: "chevron.right", action: { pdfManager.nextPage() }, disabled: !pdfManager.hasDocument || pdfManager.currentPageIndex >= pdfManager.pageCount - 1)
        }
        .padding(.horizontal, DesignTokens.spacingSM)
        .padding(.vertical, DesignTokens.spacingXS)
    }

    private var underlinePalette: [(String, NSColor)] {
        [
            ("Black", DesignTokens.underlineColor),
            ("Yellow", DesignTokens.underlineYellow),
            ("Green", DesignTokens.underlineGreen),
            ("Red", DesignTokens.underlineRed),
            ("Blue", DesignTokens.underlineBlue)
        ]
    }

    private var highlightPalette: [(String, NSColor)] {
        [
            ("Yellow", DesignTokens.highlightYellow),
            ("Green", DesignTokens.highlightGreen),
            ("Red", DesignTokens.highlightRed),
            ("Blue", DesignTokens.highlightBlue)
        ]
    }

    private var colorMenu: some View {
        Menu {
            Text("Underline").font(.caption)
            ForEach(underlinePalette, id: \.0) { label, color in
                Button {
                    annotationManager.underlineColor = color
                } label: {
                    HStack {
                        Circle().fill(Color(nsColor: color)).frame(width: 12, height: 12)
                        Text(label)
                        if color.isEqual(to: annotationManager.underlineColor) {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Divider()
            Text("Highlight").font(.caption)
            ForEach(highlightPalette, id: \.0) { label, color in
                Button {
                    annotationManager.highlightColor = color
                } label: {
                    HStack {
                        Circle().fill(Color(nsColor: color)).frame(width: 12, height: 12)
                        Text(label)
                        if color.isEqual(to: annotationManager.highlightColor) {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: DesignTokens.toolbarIconSize, weight: .medium))
                .frame(width: DesignTokens.toolbarButtonSize, height: DesignTokens.toolbarButtonSize)
                .contentShape(RoundedRectangle(cornerRadius: DesignTokens.spacingSM))
        }
        .buttonStyle(.plain)
        .disabled(!pdfManager.hasDocument)
        .opacity(pdfManager.hasDocument ? 1 : 0.3)
        .onHover { hovering in
            if pdfManager.hasDocument {
                (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
        }
    }

    private func toolbarButton(icon: String, action: @escaping () -> Void, disabled: Bool = false) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: DesignTokens.toolbarIconSize, weight: .medium))
                .frame(width: DesignTokens.toolbarButtonSize, height: DesignTokens.toolbarButtonSize)
                .contentShape(RoundedRectangle(cornerRadius: DesignTokens.spacingSM))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1.0)
        .onHover { hovering in
            if !disabled {
                (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
        }
    }

    private func handleFitButtonTap() {
        let now = Date()

        if let lastTap = lastFitTapTime,
           now.timeIntervalSince(lastTap) < doubleTapWindow {
            pdfManager.toggleAutoScale()
            pdfManager.scaleNeedsUpdate = true
            lastFitTapTime = nil
        } else {
            pdfManager.isAutoScaling = false
            pdfManager.requestFitOnce()
            pdfManager.scaleNeedsUpdate = true
            lastFitTapTime = now
        }
    }
}
