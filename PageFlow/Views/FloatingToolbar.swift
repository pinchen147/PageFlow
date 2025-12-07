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
    @State private var isExpanded = true

    var body: some View {
        ZStack(alignment: .trailing) {
            if isExpanded {
                expandedContainer
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            } else {
                collapsedButton
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .frame(height: DesignTokens.collapsedToolbarSize)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isExpanded)
    }

    private var expandedContainer: some View {
        expandedToolbar
            .background(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.floatingToolbarCornerRadius)
                    .fill(DesignTokens.floatingToolbarBase.opacity(0.12))
                    .allowsHitTesting(false)
            )
            .cornerRadius(DesignTokens.floatingToolbarCornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.floatingToolbarCornerRadius)
                    .strokeBorder(.white.opacity(0.22))
                    .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
    }

    private var expandedToolbar: some View {
        HStack(spacing: DesignTokens.spacingSM) {
            toolbarButton(icon: "doc", action: { showingFileImporter = true })
            Divider().frame(height: 20)
            toolbarButton(icon: "minus.magnifyingglass", action: { pdfManager.zoomOut() }, disabled: !pdfManager.hasDocument)
            toolbarButton(icon: "1.magnifyingglass", action: { pdfManager.resetZoom() }, disabled: !pdfManager.hasDocument)
            toolbarButton(icon: "plus.magnifyingglass", action: { pdfManager.zoomIn() }, disabled: !pdfManager.hasDocument)
            Divider().frame(height: 20)
            toolbarButton(icon: "chevron.left", action: { pdfManager.previousPage() }, disabled: !pdfManager.hasDocument || pdfManager.currentPageIndex == 0)
            toolbarButton(icon: "chevron.right", action: { pdfManager.nextPage() }, disabled: !pdfManager.hasDocument || pdfManager.currentPageIndex >= pdfManager.pageCount - 1)
            Divider().frame(height: 20)
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
                .font(.system(size: 16, weight: .medium))
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
}
