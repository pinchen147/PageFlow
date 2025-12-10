//
//  OutlineSidebar.swift
//  PageFlow
//
//  Displays the PDF outline (table of contents) in a sidebar.
//

import SwiftUI

struct OutlineSidebar: View {
    @Bindable var pdfManager: PDFManager
    let items: [OutlineItem]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingSM) {
            HStack {
                Text("Contents")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .frame(width: DesignTokens.tabCloseButtonSize, height: DesignTokens.tabCloseButtonSize)
                .onHover { hovering in
                    (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
                }
            }
            .padding(.leading, DesignTokens.spacingMD)
            .padding(.trailing, DesignTokens.spacingSM)
            .padding(.top, DesignTokens.spacingSM)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    OutlineGroup(items, children: \.children) { item in
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
                .padding(.horizontal, DesignTokens.spacingMD + DesignTokens.spacingSM)
                .padding(.bottom, DesignTokens.spacingMD)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.clear)
            .hideScrollBackgroundIfAvailable()
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
