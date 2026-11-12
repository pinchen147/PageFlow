import AppKit
import EPUBKit
import Observation
import SwiftUI

/// The EPUB navigation rail, the same as PDF's: one mark per page, a page
/// thumbnail grid on hover, and a jump on click.
struct EPUBNavigationRail: NSViewRepresentable {
    let content: EPUBContent
    let eligible: Bool
    let topInset: CGFloat
    let onShowSidebar: () -> Void

    func makeNSView(context: Context) -> NavigationRailView { NavigationRailView() }

    func updateNSView(_ rail: NavigationRailView, context: Context) {
        // Pages sit on the viewer background: just the marks, no container.
        rail.onShowSidebar = onShowSidebar
        rail.makePreview = { [weak content, weak rail] target in
            guard let content, case let .page(index) = target else { return nil }
            let position = EPUBRailPreviewPosition(page: index)
            rail?.updatePreview = { [weak position] target in
                guard case let .page(index) = target else { return }
                position?.page = index
            }
            return NSHostingView(rootView: EPUBPageGridPreview(
                content: content,
                position: position,
                onClose: { [weak rail] in _ = rail?.handleEscape() }
            ))
        }
        rail.onActivate = { [weak content, weak rail] target, generation in
            guard let content, let rail, rail.eligible, rail.generation == generation,
                  case let .page(index) = target, index != content.currentPage else { return }
            content.jump(toPage: index)
        }
        let visible = Set(content.currentRow.pages)
        rail.configure(
            kind: .pdf,
            count: content.pagination.pageCount,
            visible: visible,
            // A new pagination (text settings) is a new set of pages.
            identity: [AnyHashable(content.documentURL), AnyHashable(content.typography.layoutSignature)]
                as AnyHashable,
            eligible: eligible && content.pagination.pageCount > 0,
            topInset: topInset
        )
    }

    static func dismantleNSView(_ rail: NavigationRailView, coordinator: ()) { rail.retire() }
}

@Observable
private final class EPUBRailPreviewPosition {
    var page: Int
    init(page: Int) { self.page = page }
}

/// PDF's hover panel for EPUB: a grid of page thumbnails scrolled to the
/// hovered page; clicking one jumps there.
private struct EPUBPageGridPreview: View {
    let content: EPUBContent
    let position: EPUBRailPreviewPosition
    let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: DesignTokens.spacingSM) {
            HStack {
                Text("Pages").font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close page preview")
            }
            // In line with the thumbnails below.
            .padding(.horizontal, DesignTokens.thumbnailGridPadding)
            .padding(.top, DesignTokens.thumbnailGridPadding)
            ScrollViewReader { proxy in
                // PDF's preview: 120 pt pages in a column.
                ScrollView {
                    LazyVStack(spacing: DesignTokens.spacingSM) { thumbnails }
                        .padding(DesignTokens.thumbnailGridPadding)
                }
                // The rail drives this column; it needs no scroll bar of its own.
                .scrollIndicators(.never)
                .onAppear { proxy.scrollTo(position.page, anchor: .center) }
                .onChange(of: position.page) { _, page in proxy.scrollTo(page, anchor: .center) }
            }
        }
        // The sidebar's glass, so the preview reads as the rail's own panel.
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.floatingToolbarCornerRadius, style: .continuous))
        .pageFlowLiquidGlassPanel(.sidebar)
        .transaction { if reduceMotion { $0.disablesAnimations = true } }
    }

    private var thumbnails: some View {
        let current = content.currentRow.pages
        return ForEach(0..<content.pagination.pageCount, id: \.self) { page in
            EPUBPageThumbnail(content: content, page: page, isCurrent: current.contains(page),
                              isHovered: page == position.page)
                .id(page)
                .onTapGesture { content.jump(toPage: page); onClose() }
        }
    }
}

/// One page in a rail preview: its thumbnail and page number.
struct EPUBPageThumbnail: View {
    let content: EPUBContent
    let page: Int
    let isCurrent: Bool
    let isHovered: Bool
    /// The sidebar's column marks bookmarks, as PDF's does; a rail preview doesn't.
    var isBookmarked = false

    var body: some View {
        // PDF's thumbnail cell: a fixed card the page fits inside, on the
        // page's own paper colour, ringed while it is the page in view.
        VStack(spacing: DesignTokens.spacingXS) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: DesignTokens.thumbnailWidth, height: DesignTokens.thumbnailHeight)
                    .background(Color(nsColor: EPUBTextStyling.themeBackgroundColor(for: content.palette)))
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.thumbnailCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.thumbnailCornerRadius)
                            .strokeBorder(isHovered || isCurrent ? Color(white: 0.3) : .clear,
                                          lineWidth: DesignTokens.thumbnailBorderWidth)
                    )
                if isBookmarked {
                    ThumbnailBookmarkBadge(color: Color(nsColor: EPUBTextStyling.themeTextColor(for: content.palette)))
                }
            }
            Text("\(page + 1)").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .pointerStyle(.link)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(page + 1)")
        .accessibilityValue(isBookmarked ? "Bookmarked" : "")
        .accessibilityAddTraits(.isButton)
    }

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 120
        return cache
    }()

    /// Redrawn when its chapter's text lands (`thumbnailRevision`); cached per
    /// book, typography and page.
    private var image: NSImage {
        _ = content.thumbnailRevision
        let palette = content.palette
        // Keyed by what the page shows, so it redraws once its chapter is
        // paginated or its text arrives.
        let shown = content.pagination.page(at: page)
        let hasText = shown.map { content.thumbnailChapter($0.chapter) != nil } ?? false
        let range = shown?.range.map { "\($0.location)-\($0.length)" } ?? "pending"
        let key = "\(content.documentURL.path)|\(content.typography)|\(content.palette)|\(content.geometry.pageSize)|\(page)|\(range)|\(hasText)" as NSString
        if let cached = Self.cache.object(forKey: key) { return cached }
        let image = render(palette: palette)
        Self.cache.setObject(image, forKey: key)
        return image
    }

    private func render(palette: EPUBPagePalette) -> NSImage {
        guard let shown = content.pagination.page(at: page) else {
            return EPUBPageView.thumbnail(of: EPUBPageContent(header: "", footer: "", palette: palette, geometry: content.geometry),
                                          width: DesignTokens.thumbnailWidth)
        }
        let chapter = content.thumbnailChapter(shown.chapter)
        return EPUBPageView.thumbnail(of: EPUBPageContent(
            text: chapter?.text,
            range: shown.range,
            header: "",
            footer: "",
            palette: palette,
            geometry: content.geometry,
            fixedPage: chapter?.fixedPage
        ), width: DesignTokens.thumbnailWidth)
    }
}
