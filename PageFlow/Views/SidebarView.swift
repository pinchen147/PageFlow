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
    let items: [OutlineItem]
    let onClose: () -> Void

    @State private var mode: SidebarMode = .outline
    @State private var editingBookmarkID: UUID?
    @State private var editingTitle: String = ""
    @FocusState private var isEditingBookmarkFocused: Bool

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
                pdfManager.pushNavigationState()
                pdfManager.goToPage(index)
            }
        } label: {
            HStack {
                Text(item.title)
                    .foregroundStyle(item.pageIndex == nil ? DesignTokens.sidebarSecondaryText : DesignTokens.sidebarPrimaryText)
                    .lineLimit(1)
                Spacer()
                if let page = item.pageIndex {
                    Text("\(page + 1)")
                        .foregroundStyle(DesignTokens.sidebarSecondaryText)
                }
            }
            .pageFlowGlassControlLabel(interactive: item.pageIndex != nil)
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
        HStack {
            Button {
                if editingBookmarkID == nil {
                    pdfManager.pushNavigationState()
                    bookmarkManager.selectBookmark(bookmark.id)
                }
            } label: {
                HStack {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.sidebarSecondaryText)

                    if editingBookmarkID == bookmark.id {
                        TextField("", text: $editingTitle)
                            .textFieldStyle(.plain)
                            .focused($isEditingBookmarkFocused)
                            .onSubmit { commitBookmarkEdit(bookmark.id) }
                            .onExitCommand { cancelBookmarkEdit() }
                    } else {
                        Text(bookmark.title)
                            .lineLimit(1)
                            .onTapGesture { startEditingBookmark(bookmark) }
                    }

                    Spacer()
                    Text("\(bookmark.pageIndex + 1)")
                        .foregroundStyle(DesignTokens.sidebarSecondaryText)
                }
                .pageFlowGlassControlLabel()
                .padding(.vertical, DesignTokens.spacingXS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pageFlowClickCursor(when: editingBookmarkID == nil)

            Button {
                bookmarkManager.removeBookmark(bookmark.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DesignTokens.sidebarSecondaryText)
                    .frame(width: DesignTokens.tabCloseButtonSize, height: DesignTokens.tabCloseButtonSize)
                    .pageFlowGlassControlLabel()
            }
            .buttonStyle(.plain)
            .pageFlowClickCursor()
            .opacity(0.6)
        }
    }

    // MARK: - Bookmark Editing

    private func startEditingBookmark(_ bookmark: BookmarkModel) {
        editingBookmarkID = bookmark.id
        editingTitle = bookmark.title
        isEditingBookmarkFocused = true
    }

    private func commitBookmarkEdit(_ id: UUID) {
        let trimmed = editingTitle.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            bookmarkManager.renameBookmark(id, to: trimmed)
        }
        editingBookmarkID = nil
        editingTitle = ""
    }

    private func cancelBookmarkEdit() {
        editingBookmarkID = nil
        editingTitle = ""
    }
}
