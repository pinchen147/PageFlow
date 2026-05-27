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
        VStack(alignment: .leading, spacing: DesignTokens.spacingSM) {
            SidebarHeaderView(
                mode: $mode,
                isEditingPages: $isEditingPages,
                onClose: onClose
            )
                .padding(.leading, DesignTokens.spacingMD)
                .padding(.trailing, DesignTokens.spacingSM)
                .padding(.top, DesignTokens.spacingSM)

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
        .padding(.horizontal, DesignTokens.spacingXS)
        .padding(.vertical, DesignTokens.spacingXS)
        .frame(width: DesignTokens.sidebarWidth)
        .pageFlowLiquidGlassPanel(
            cornerRadius: DesignTokens.floatingToolbarCornerRadius,
            tint: .light,
            tintOpacity: DesignTokens.sidebarGlassTintOpacity,
            variant: .clear,
            strokeOpacity: 0.22,
            shadowRadius: 4,
            shadowY: -2
        )
    }
    
    private var outlineView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if items.isEmpty {
                     Text("No Outline Available")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.sidebarSecondaryText)
                        .pageFlowGlassControlLabel()
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
        .scrollContentBackground(.hidden)
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
        .disabled(item.pageIndex == nil)
        .onHover { hovering in
            if item.pageIndex != nil {
                (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
        }
        .contextMenu {
            if item.pageIndex != nil {
                Button("Copy Section as Markdown") {
                    copySectionAsMarkdown(item)
                }
            }
        }
    }

    private func copySectionAsMarkdown(_ item: OutlineItem) {
        guard let document = pdfManager.document,
              let siblings = siblings(for: item, within: items) else { return }

        let markdown = MarkdownExporter.export(
            scope: .outlineSection(item, siblings),
            document: document
        )

        guard !markdown.isEmpty else { return }
        MarkdownExporter.copyToClipboard(markdown)
    }

    private func siblings(for target: OutlineItem, within candidates: [OutlineItem]) -> [OutlineItem]? {
        if candidates.contains(where: { $0.id == target.id }) {
            return candidates
        }

        for candidate in candidates {
            guard let children = candidate.children,
                  let nestedSiblings = siblings(for: target, within: children) else {
                continue
            }
            return nestedSiblings
        }

        return nil
    }

    // MARK: - Bookmarks View

    private var bookmarksView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if bookmarkManager.bookmarks.isEmpty {
                    Text("No Bookmarks")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.sidebarSecondaryText)
                        .pageFlowGlassControlLabel()
                        .padding(DesignTokens.spacingMD)
                } else {
                    ForEach(bookmarkManager.sortedBookmarks) { bookmark in
                        bookmarkRow(bookmark)
                    }
                }
            }
            .padding(.horizontal, DesignTokens.spacingMD + DesignTokens.spacingSM)
            .padding(.bottom, DesignTokens.spacingMD)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .scrollContentBackground(.hidden)
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
            .onHover { hovering in
                (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
            }

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
            .opacity(0.6)
            .onHover { hovering in
                (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
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
