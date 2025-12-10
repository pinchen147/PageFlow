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
                .padding(.horizontal, DesignTokens.spacingMD)
                .padding(.bottom, DesignTokens.spacingMD)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.floatingToolbarCornerRadius)
                .fill(DesignTokens.floatingToolbarBase.opacity(0.12))
                .allowsHitTesting(false)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.floatingToolbarCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.floatingToolbarCornerRadius)
                .strokeBorder(.white.opacity(0.22))
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
    }
}
