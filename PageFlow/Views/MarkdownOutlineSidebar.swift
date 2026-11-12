//
//  MarkdownOutlineSidebar.swift
//  PageFlow
//
//  The Markdown side of the document sidebar — the SAME shell as the PDF
//  `SidebarView` (`GlassSidebarShell`/`GlassSidebarList`, so the chrome cannot
//  drift), holding the heading outline. Clicking a heading scrolls the editor
//  to it (via the tab's scoped bus reveal+scroll leg — see
//  `MarkdownContent.scrollToOutlineItem`).
//

import SwiftUI

struct MarkdownOutlineSidebar: View {
    let items: [MarkdownOutlineItem]
    /// The heading the reader is in, shown like EPUB's current chapter.
    var currentID: Int?
    let onSelect: (MarkdownOutlineItem) -> Void
    let onClose: () -> Void

    var body: some View {
        GlassSidebarShell {
            HStack {
                GlassSidebarTitle(text: "Contents")
                Spacer()
                GlassSidebarCloseButton(label: "Close Sidebar", action: onClose)
            }
        } content: {
            GlassSidebarList {
                if items.isEmpty {
                    GlassSidebarEmptyState(text: "No Outline Available")
                } else {
                    ForEach(items) { item in
                        outlineItemRow(item)
                    }
                }
            }
        }
    }

    private func outlineItemRow(_ item: MarkdownOutlineItem) -> some View {
        let isCurrent = item.id == currentID
        return Button {
            onSelect(item)
        } label: {
            HStack {
                Text(item.title.isEmpty ? "Untitled" : item.title)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .lineLimit(1)
                Spacer()
            }
            // ATX depth → indent, mirroring the PDF outline's hierarchy feel.
            .padding(.leading, CGFloat(item.level - 1) * DesignTokens.spacingMD)
            .padding(.vertical, DesignTokens.spacingXS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pageFlowClickCursor()
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
