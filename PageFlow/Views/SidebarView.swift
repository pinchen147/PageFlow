//
//  SidebarView.swift
//  PageFlow
//
//  Displays the PDF sidebar with Outline (Table of Contents) and Thumbnails.
//

import SwiftUI
import PDFKit

enum SidebarMode {
    case outline
    case thumbnails
    case bookmarks
}

struct SidebarView: View {
    @Bindable var pdfManager: PDFManager
    @Bindable var bookmarkManager: BookmarkManager
    @Binding var isEditingPages: Bool
    /// What it shows: the tab's, since this view unmounts while the tab is hidden.
    @Binding var mode: SidebarMode
    let items: [OutlineItem]
    let onClose: () -> Void

    @State private var editingBookmarkID: UUID?

    var body: some View {
        GlassSidebarShell {
            SidebarHeaderView(
                mode: $mode,
                isEditingPages: $isEditingPages,
                onClose: onClose
            )
        } content: {
            Group {
                switch mode {
                case .outline:
                    outlineView
                case .thumbnails:
                    ThumbnailGridView(
                        pdfManager: pdfManager,
                        bookmarkManager: bookmarkManager,
                        isEditing: isEditingPages
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, DesignTokens.spacingXS)
                case .bookmarks:
                    bookmarksView
                }
            }
            .animation(.easeInOut(duration: DesignTokens.animationFast), value: mode)
        }
    }

    private var outlineView: some View {
        GlassSidebarList {
            if items.isEmpty {
                GlassSidebarEmptyState(text: "No Outline Available")
            } else {
                OutlineGroup(items, children: \.children) { item in
                    outlineItemRow(item)
                }
            }
        }
    }
    
    private func outlineItemRow(_ item: OutlineItem) -> some View {
        Button {
            if let index = item.pageIndex {
                pdfManager.jump(toPage: index)
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
        .pageFlowClickCursor()
        .disabled(item.pageIndex == nil)
        .contextMenu {
            if item.pageIndex != nil, pdfManager.permissions.copy {
                Button("Copy Section as Markdown") {
                    copySectionAsMarkdown(item)
                }
            }
        }
    }

    private func copySectionAsMarkdown(_ item: OutlineItem) {
        pdfManager.copyMarkdown(scope: .outlineSection(item))
    }

    // MARK: - Bookmarks View

    private var bookmarksView: some View {
        GlassSidebarList {
            if bookmarkManager.bookmarks.isEmpty {
                GlassSidebarEmptyState(text: "No Bookmarks")
            } else {
                ForEach(bookmarkManager.sortedBookmarks) { bookmark in
                    bookmarkRow(bookmark)
                }
            }
        }
    }

    private func bookmarkRow(_ bookmark: BookmarkModel) -> some View {
        SidebarBookmarkRow(
            id: bookmark.id,
            title: bookmark.title,
            pageLabel: "\(bookmark.pageIndex + 1)",
            editingID: $editingBookmarkID,
            onSelect: {
                pdfManager.jump(toPage: bookmark.pageIndex)
                bookmarkManager.selectBookmark(bookmark.id)
            },
            onRename: { bookmarkManager.renameBookmark(bookmark.id, to: $0.trimmingCharacters(in: .whitespaces)) },
            onRemove: { bookmarkManager.removeBookmark(bookmark.id) }
        )
    }
}
