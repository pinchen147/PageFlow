import AppKit
import EPUBKit
import SwiftUI

// MARK: - Sidebar

/// The book's contents, bookmarks and highlights in the shared glass sidebar,
/// the same panel, header and rows as PDF's outline and bookmarks.
struct EPUBReaderSidebar: View {
    let book: EPUBBook
    @Bindable var content: EPUBContent
    /// What it shows: the tab's, since this view unmounts while the tab is hidden.
    @Binding var section: Section
    let close: () -> Void
    let selectEntry: (EPUBContentsEntry) -> Void

    /// PDF's sidebar modes, in PDF's order, then the book's highlights and
    /// Find's results.
    enum Section {
        case contents, thumbnails, bookmarks, highlights, search

        var title: String {
            switch self {
            case .contents: "Contents"
            case .thumbnails: "Thumbnails"
            case .bookmarks: "Bookmarks"
            case .highlights: "Highlights"
            case .search: "Search"
            }
        }

        var next: Section {
            switch self {
            case .contents: .thumbnails
            case .thumbnails: .bookmarks
            case .bookmarks: .highlights
            case .highlights: .search
            case .search: .contents
            }
        }

        /// What the sidebar opens on next after closing on this mode: Search
        /// lists one Find's results, so it is only shown when asked for.
        var afterClosing: Section { self == .search ? .contents : self }

        /// The header toggle shows where it goes next, like PDF's.
        var toggleIcon: String {
            switch self {
            case .contents: "square.grid.2x2"
            case .thumbnails: "bookmark"
            case .bookmarks: "highlighter"
            case .highlights: "magnifyingglass"
            case .search: "list.bullet"
            }
        }
    }

    @State private var editingBookmarkID: UUID?
    @Environment(\.epubHighlightsExport) private var exportActions

    private var sortedBookmarks: [EPUBBookmark] {
        content.bookmarks.sorted {
            ($0.chapterIndex, $0.characterOffset) < ($1.chapterIndex, $1.characterOffset)
        }
    }

    /// The entry the reader is in: the last one at or before their chapter.
    /// Sections count by where their anchor falls, so a chapter's own
    /// sections (or a one-file book's chapters) light up as they are read.
    private var currentEntryID: String? {
        guard let shown = content.pagination.page(at: content.currentPage) else { return nil }
        let pageEnd = shown.range.map(NSMaxRange) ?? 1
        return book.contents.last { entry in
            entry.chapterIndex == shown.chapter
                ? content.offset(of: entry) < pageEnd
                : entry.chapterIndex < shown.chapter
        }?.id
    }

    var body: some View {
        GlassSidebarShell {
            HStack {
                GlassSidebarTitle(text: section.title)
                Spacer()
                if section == .highlights, let exportActions {
                    EPUBHighlightsExportMenu(actions: exportActions, isEnabled: !content.highlights.items.isEmpty)
                }
                sectionToggle
                GlassSidebarCloseButton(action: close)
                    .help("Close")
                    .accessibilityLabel("Close Sidebar")
            }
        } content: {
            switch section {
            case .contents: GlassSidebarList { contentsRows }
            case .thumbnails: EPUBThumbnailColumn(content: content)
            case .bookmarks: GlassSidebarList { bookmarkRows }
            case .highlights: GlassSidebarList { highlightRows }
            case .search: EPUBSearchResultsList(book: book, content: content)
            }
        }
    }

    /// Like PDF's header toggle: one button steps through the modes.
    private var sectionToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: DesignTokens.animationFast)) {
                section = section.next
            }
        } label: {
            Image(systemName: section.toggleIcon)
                .font(.system(size: DesignTokens.sidebarToggleIconSize))
                .foregroundStyle(.primary)
                .frame(width: DesignTokens.sidebarToggleButtonSize, height: DesignTokens.sidebarToggleButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pageFlowClickCursor()
        .help("Show \(section.next.title)")
        .accessibilityLabel("Show \(section.next.title)")
    }

    @ViewBuilder
    private var contentsRows: some View {
        if book.contents.isEmpty {
            GlassSidebarEmptyState(text: "No Contents")
        } else {
            let current = currentEntryID
            let sections = Set(EPUBContentsNode.sections(holding: current, in: book.contents))
            // PDF's outline: sections collapse, rows take one line.
            OutlineGroup(content.contentsTree, children: \.children) { node in
                EPUBContentsRow(
                    title: node.entry.title,
                    pageLabel: content.contentsPageLabel(of: node.entry),
                    accent: node.entry.id == current ? .current : sections.contains(node.entry.id) ? .section : .none
                ) {
                    selectEntry(node.entry)
                }
            }
            .task { await content.resolveContentsOffsets() }
        }
        if !book.landmarks.isEmpty {
            EPUBLandmarkRows(landmarks: book.landmarks, select: content.selectLandmark)
        }
    }

    @ViewBuilder
    private var bookmarkRows: some View {
        if sortedBookmarks.isEmpty {
            GlassSidebarEmptyState(text: "No Bookmarks")
        } else {
            ForEach(sortedBookmarks) { bookmark in
                bookmarkRow(bookmark)
            }
        }
    }

    /// PDF's bookmark row, with the passage it marks underneath.
    private func bookmarkRow(_ bookmark: EPUBBookmark) -> some View {
        SidebarBookmarkRow(
            id: bookmark.id,
            title: bookmark.title,
            excerpt: bookmark.excerpt,
            pageLabel: content.pageListLabel(of: bookmark),
            editingID: $editingBookmarkID,
            onSelect: {
                content.jump(to: EPUBLocation(chapterIndex: bookmark.chapterIndex,
                                              characterOffset: bookmark.characterOffset))
            },
            onRename: { content.renameBookmark(bookmark, to: $0) },
            onRemove: { content.removeBookmark(bookmark) }
        )
    }

    @ViewBuilder
    private var highlightRows: some View {
        if content.highlights.items.isEmpty {
            GlassSidebarEmptyState(text: "No Highlights")
        } else {
            ForEach(content.highlights.items) { highlight in
                EPUBHighlightRow(
                    highlight: highlight,
                    pageLabel: content.pageListLabel(of: highlight),
                    onSelect: { content.jump(to: highlight) },
                    onRemove: { content.highlights.remove(highlight.id) }
                )
            }
        }
    }
}

/// PDF's thumbnail column: every page, the one in view ringed, bookmarks
/// marked. It opens scrolled to the reader's page and follows them with the
/// rail's keep-visible rule (`RailFollow`).
struct EPUBThumbnailColumn: View {
    let content: EPUBContent
    /// The pages in view, for when the page being read reaches an edge.
    @State private var visiblePages: Set<Int> = []

    var body: some View {
        // Read once here: a cell that reads the page itself redraws on every turn.
        let current = content.currentRow.pages
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(spacing: DesignTokens.spacingSM) {
                        ForEach(0..<content.pagination.pageCount, id: \.self) { page in
                            cell(page, isCurrent: current.contains(page), viewportHeight: geometry.size.height)
                        }
                    }
                    .padding(DesignTokens.thumbnailGridPadding)
                    .frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: "thumbnailScrollView")
                .scrollContentBackground(.hidden)
                // Thumbnails scroll with the trackpad and follow the reader; no bar of their own.
                .scrollIndicators(.never)
                .onPreferenceChange(VisibleIndicesPreferenceKey.self) { visiblePages = $0 }
            }
            .onAppear { proxy.scrollTo(content.currentPage, anchor: .center) }
            .onChange(of: content.currentPage) { old, new in
                guard let move = RailFollow.move(from: old, to: new, visiblePages: visiblePages) else { return }
                proxy.scrollTo(move.pageIndex, anchor: move.anchor)
            }
        }
    }

    private func cell(_ page: Int, isCurrent: Bool, viewportHeight: CGFloat) -> some View {
        let isBookmarked = content.isBookmarked(page: page)
        return EPUBPageThumbnail(content: content, page: page, isCurrent: isCurrent, isHovered: false,
                                 isBookmarked: isBookmarked)
            .id(page)
            .background { VisibilityReporter(index: page, viewportHeight: viewportHeight) }
            .onTapGesture { content.jump(toPage: page) }
            .contextMenu {
                Button { content.toggleBookmark(onPage: page) } label: {
                    Label(isBookmarked ? "Remove Bookmark" : "Add Bookmark",
                          systemImage: isBookmarked ? "bookmark.slash" : "bookmark")
                }
            }
    }
}

/// A contents entry, like PDF's outline row: its title on one line and its
/// page. The entry the reader is in shows in the accent colour, and so do the
/// sections holding it, which may be collapsed.
struct EPUBContentsRow: View {
    enum Accent { case none, section, current }

    let title: String
    let pageLabel: String
    let accent: Accent
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .fontWeight(accent == .current ? .semibold : .regular)
                    .foregroundStyle(accent == .none ? Color.primary : Color.accentColor)
                    .lineLimit(1)
                Spacer(minLength: DesignTokens.spacingXS)
                Text(pageLabel)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityLabel("page \(pageLabel)")
            }
            .padding(.vertical, DesignTokens.spacingXS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pageFlowClickCursor()
        .help(title)
        .accessibilityAddTraits(accent == .current ? .isSelected : [])
    }
}

/// A highlight in the sidebar: its colour, the words, the note under them,
/// the page, and a remove button like a bookmark row's.
struct EPUBHighlightRow: View {
    let highlight: EPUBHighlight
    let pageLabel: String
    let onSelect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Button(action: onSelect) {
                HStack(alignment: .firstTextBaseline) {
                    Circle()
                        .fill(Color(nsColor: highlight.nsColor))
                        .frame(width: DesignTokens.epubNoteMarkerSize + 3, height: DesignTokens.epubNoteMarkerSize + 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(highlight.excerpt.isEmpty ? "Highlight" : highlight.excerpt)
                            .lineLimit(3)
                        if highlight.hasNote, let note = highlight.note {
                            Label(note, systemImage: "text.bubble")
                                .labelStyle(.titleAndIcon)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    Text(pageLabel)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, DesignTokens.spacingXS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pageFlowClickCursor()
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(highlight.style.passageLabel): \(highlight.excerpt)" + (highlight.hasNote ? ", note: \(highlight.note ?? "")" : ""))
            .accessibilityValue("Page \(pageLabel)")

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: DesignTokens.tabCloseButtonSize, height: DesignTokens.tabCloseButtonSize)
            }
            .buttonStyle(.plain)
            .pageFlowClickCursor()
            .opacity(0.6)
            .help(highlight.style.removalTitle)
            .accessibilityLabel(highlight.style.removalTitle)
        }
    }
}
