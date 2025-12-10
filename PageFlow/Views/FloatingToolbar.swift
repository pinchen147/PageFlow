//
//  FloatingToolbar.swift
//  PageFlow
//
//  Floating glassmorphism toolbar with collapse functionality
//

import SwiftUI

struct FloatingToolbar: View {
    @Bindable var pdfManager: PDFManager
    @Binding var showingFileImporter: Bool
    @Binding var isTopBarHovered: Bool
    @State private var isExpanded = true
    @State private var lastFitTapTime: Date?
    private let doubleTapWindow: TimeInterval = 0.3

    var body: some View {
        let isVisible = isTopBarHovered

        ZStack(alignment: .trailing) {
            expandedContainer
                .scaleEffect(x: isExpanded ? 1 : 0.01, y: 1, anchor: .trailing)
                .opacity(isExpanded ? 1 : 0)
                .allowsHitTesting(isExpanded)

            collapsedButton
                .scaleEffect(x: isExpanded ? 0.01 : 1, y: 1, anchor: .trailing)
                .opacity(collapsedButtonOpacity)
                .allowsHitTesting(!isExpanded)
        }
        .frame(height: DesignTokens.collapsedToolbarSize)
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
        .animation(.easeInOut(duration: DesignTokens.animationFast), value: isTopBarHovered)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(.easeInOut(duration: DesignTokens.animationFast), value: isVisible)
    }

    private var collapsedButtonOpacity: Double {
        if isExpanded {
            return 0
        }
        return isTopBarHovered ? 1 : 0
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
            toolbarButton(icon: "minus.magnifyingglass", action: { pdfManager.zoomOut() }, disabled: !pdfManager.hasDocument)
            toolbarButton(icon: "1.magnifyingglass", action: { pdfManager.resetZoom() }, disabled: !pdfManager.hasDocument)
            toolbarButton(icon: "plus.magnifyingglass", action: { pdfManager.zoomIn() }, disabled: !pdfManager.hasDocument)
            toolbarButton(
                icon: pdfManager.isAutoScaling ? "arrow.down.forward.and.arrow.up.backward.circle.fill" : "arrow.down.forward.and.arrow.up.backward.circle",
                action: handleFitButtonTap,
                disabled: !pdfManager.hasDocument
            )
            toolbarButton(icon: "rotate.right", action: { pdfManager.rotateClockwise() }, disabled: !pdfManager.hasDocument)
            Divider().frame(height: 16)
            toolbarButton(icon: "chevron.left", action: { pdfManager.previousPage() }, disabled: !pdfManager.hasDocument || pdfManager.currentPageIndex == 0)
            toolbarButton(icon: "chevron.right", action: { pdfManager.nextPage() }, disabled: !pdfManager.hasDocument || pdfManager.currentPageIndex >= pdfManager.pageCount - 1)
            Divider().frame(height: 16)
            toolbarButton(icon: "xmark", action: { isExpanded.toggle() })
        }
        .padding(.horizontal, DesignTokens.spacingSM)
        .padding(.vertical, DesignTokens.spacingXS)
    }

    private var collapsedButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .frame(width: DesignTokens.collapsedToolbarSize, height: DesignTokens.collapsedToolbarSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial)
        .overlay(
            Circle()
                .fill(DesignTokens.floatingToolbarBase.opacity(0.12))
                .allowsHitTesting(false)
        )
        .clipShape(Circle())
        .overlay(
            Circle()
                .strokeBorder(.white.opacity(0.22))
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
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
