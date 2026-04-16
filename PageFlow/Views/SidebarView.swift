//
//  SidebarView.swift
//  PageFlow
//
//  Displays the PDF sidebar with Outline (Table of Contents) and Thumbnails.
//

import SwiftUI
import PDFKit

struct SidebarView: View {
    @Bindable var pdfManager: PDFManager
    @Bindable var bookmarkManager: BookmarkManager
    @Bindable var tabManager: TabManager
    let items: [OutlineItem]
    let onClose: () -> Void

    enum SidebarMode {
        case outline
        case thumbnails
        case bookmarks
    }

    @State private var mode: SidebarMode = .outline
    @State private var editingBookmarkID: UUID?
    @State private var editingTitle: String = ""
    @FocusState private var isEditingBookmarkFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingSM) {
            header
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
                        isEditing: tabManager.isEditingPages
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
        .frame(width: DesignTokens.sidebarWidth)
    }

    private var header: some View {
        HStack {
            Text(headerTitle)
                .font(.headline)

            Spacer()

            // Done button - only show in thumbnail mode when editing
            if mode == .thumbnails && tabManager.isEditingPages {
                Button {
                    withAnimation(.easeInOut(duration: DesignTokens.animationFast)) {
                        tabManager.isEditingPages = false
                    }
                } label: {
                    Text("Done")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.primary)
                .buttonStyle(.plain)
            }

            modeToggle

            Button {
                tabManager.isEditingPages = false
                onClose()
            } label: {
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

    private var headerTitle: String {
        switch mode {
        case .outline: return "Contents"
        case .thumbnails: return "Thumbnails"
        case .bookmarks: return "Bookmarks"
        }
    }
    
    private var modeToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: DesignTokens.animationFast)) {
                tabManager.isEditingPages = false
                switch mode {
                case .outline: mode = .thumbnails
                case .thumbnails: mode = .bookmarks
                case .bookmarks: mode = .outline
                }
            }
        } label: {
            Image(systemName: modeIcon)
                .font(.system(size: DesignTokens.sidebarToggleIconSize))
                .foregroundStyle(.primary)
                .frame(
                    width: DesignTokens.sidebarToggleButtonSize,
                    height: DesignTokens.sidebarToggleButtonSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(modeHelpText)
    }

    private var modeIcon: String {
        switch mode {
        case .outline: return "square.grid.2x2"
        case .thumbnails: return "bookmark"
        case .bookmarks: return "list.bullet"
        }
    }

    private var modeHelpText: String {
        switch mode {
        case .outline: return "Show Thumbnails"
        case .thumbnails: return "Show Bookmarks"
        case .bookmarks: return "Show Contents"
        }
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
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)

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
                        .foregroundStyle(.secondary)
                }
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
                    .foregroundStyle(.secondary)
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
