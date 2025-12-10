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

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingSM) {
            Text("Contents")
                .font(.headline)
                .padding(.horizontal, DesignTokens.spacingMD)
                .padding(.top, DesignTokens.spacingMD)

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
