//
//  SidebarView.swift
//  PageFlow
//
//  Displays the PDF sidebar with Outline (Table of Contents) and Thumbnails.
//

import SwiftUI

struct SidebarView: View {
    @Bindable var pdfManager: PDFManager
    let items: [OutlineItem]
    let onClose: () -> Void
    
    enum SidebarMode {
        case outline
        case thumbnails
    }
    
    @State private var mode: SidebarMode = .outline

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingSM) {
            header
                .padding(.leading, DesignTokens.spacingMD)
                .padding(.trailing, DesignTokens.spacingSM)
                .padding(.top, DesignTokens.spacingSM)

            Group {
                if mode == .outline {
                    outlineView
                } else {
                    PDFThumbnailViewWrapper(pdfManager: pdfManager)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, DesignTokens.spacingXS)
                        .padding(.bottom, DesignTokens.spacingMD)
                }
            }
            .animation(.easeInOut(duration: DesignTokens.animationFast), value: mode)
        }
        .padding(.horizontal, DesignTokens.spacingXS)
        .padding(.vertical, DesignTokens.spacingXS)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: DesignTokens.floatingToolbarCornerRadius)
        )
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
    
    private var header: some View {
        HStack {
            Text(mode == .outline ? "Contents" : "Thumbnails")
                .font(.headline)

            Spacer()

            modeToggle

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .frame(width: DesignTokens.tabCloseButtonSize, height: DesignTokens.tabCloseButtonSize)
            .onHover { hovering in
                (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
        }
    }
    
    private var modeToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: DesignTokens.animationFast)) {
                mode = mode == .outline ? .thumbnails : .outline
            }
        } label: {
            Image(systemName: mode == .outline ? "square.grid.2x2" : "list.bullet")
                .font(.system(size: DesignTokens.sidebarToggleIconSize))
                .foregroundStyle(.secondary)
                .frame(
                    width: DesignTokens.sidebarToggleButtonSize,
                    height: DesignTokens.sidebarToggleButtonSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mode == .outline ? "Show Thumbnails" : "Show Contents")
    }
    
    private var outlineView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if items.isEmpty {
                     Text("No Outline Available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(DesignTokens.spacingMD)
                } else {
                    OutlineGroup(items, children: \.children) { item in
                        outlineItemRow(item)
                    }
                }
            }
            .padding(.horizontal, DesignTokens.spacingMD + DesignTokens.spacingSM)
            .padding(.bottom, DesignTokens.spacingMD)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .hideScrollBackgroundIfAvailable()
    }
    
    private func outlineItemRow(_ item: OutlineItem) -> some View {
        Button {
            if let index = item.pageIndex {
                pdfManager.goToPage(index)
            }
        } label: {
            HStack {
                Text(item.title)
                    .foregroundStyle(item.pageIndex == nil ? .secondary : .primary)
                    .lineLimit(1)
                Spacer()
                if let page = item.pageIndex {
                    Text("\(page + 1)")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, DesignTokens.spacingXS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.pageIndex == nil)
        .onHover { hovering in
            if item.pageIndex != nil {
                (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
        }
    }
}

// MARK: - Helpers

private extension View {
    @ViewBuilder
    func hideScrollBackgroundIfAvailable() -> some View {
        if #available(macOS 13.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}
