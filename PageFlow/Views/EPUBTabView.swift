import AppKit
import EPUBKit
import SwiftUI

@MainActor
struct EPUBTabView: View {
    let tabID: UUID
    @Bindable var content: EPUBContent
    let isActive: Bool
    let isDisplayed: Bool
    @Binding var showingSearch: Bool
    let searchFocusRequest: Int
    let tabManager: TabManager
    @State private var shownNotices: Set<String> = []
    /// The whole view's size; the pages get it less the Notes panel.
    @State private var viewSize: CGSize = .zero
    /// Pages show only once this view has told the book its size: the first
    /// frame of a rebuilt tab can't be pages laid out for another window.
    @State private var hasReportedSize = false
    /// The Find bar's width while it shows; the page chip stays clear of it.
    @State private var findBarWidth: CGFloat = 0
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The tab's own chrome (sidebar, Find, page chip) takes the page theme,
    /// as Markdown's forced scheme does; window chrome stays the Mac's.
    private var chromeScheme: ColorScheme { content.requestedPalette == .dark ? .dark : .light }

    private var showingContents: Bool {
        get { tabManager.showingOutline(for: tabID) }
        nonmutating set { tabManager.setShowingOutline(newValue, for: tabID) }
    }

    /// What the sidebar shows, kept with the tab.
    private var sidebarSection: Binding<EPUBReaderSidebar.Section> {
        Binding(
            get: { tabManager.epubSidebarSection(for: tabID) },
            set: { tabManager.setEPUBSidebarSection($0, for: tabID) }
        )
    }

    /// The tab's Go to Page slot, shared with the Go menu (⌥⌘G). Gated on
    /// isActive: a hidden warm tab's sheet would strand over the visible tab.
    private var showingGoToPage: Binding<Bool> {
        Binding(
            get: { isActive && tabManager.showingGoToPage(for: tabID) },
            set: { tabManager.setShowingGoToPage($0, for: tabID) }
        )
    }

    /// Active, displayed pages request the keyboard with Find closed. The deferred
    /// claim rechecks this intent and the current native annotation responder;
    /// an open draft alone does not veto focus.
    var wantsKeyFocus: Bool {
        guard case .ready = content.state else { return false }
        return FindOverlay.documentTakesKeyboard(isShown: isActive && isDisplayed, findIsOpen: showingSearch)
    }

    private var topChromeHeight: CGFloat {
        TopChromeView.height(toolbarScale: SettingsManager.shared.toolbarScale)
    }

    private var showsNotesPanel: Bool { isActive && content.highlights.isPanelShown && content.book != nil }

    /// The room the Notes panel takes at the trailing edge: the pages give it
    /// up and reflow or fit into the rest, so the panel never covers text.
    /// Kept while the tab is in the background, so switching tabs never
    /// re-lays out the book.
    private var notesPanelInset: CGFloat {
        content.highlights.isPanelShown && content.book != nil
            ? DesignTokens.commentSidebarWidth + DesignTokens.spacingXS : 0
    }

    /// Reflow to Fit and Zoom to Fit size the pages to the view less the panel.
    private func reportViewport(fromNewView: Bool = false) {
        content.viewportChanged(CGSize(width: viewSize.width - notesPanelInset, height: viewSize.height),
                                topInset: topChromeHeight, fromNewView: fromNewView)
    }

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()
            switch content.state {
            case .loading:
                // The viewer background only: a book never shows it is loading.
                EmptyView()
            case .failed(let message):
                ContentUnavailableView(
                    "Couldn’t Open EPUB",
                    systemImage: "book.closed",
                    description: Text(message)
                )
                // On the viewer's dark background, like the pages it replaces.
                .environment(\.colorScheme, .dark)
            case .ready:
                if hasReportedSize, !content.isReflowingBeforeShowing { readyContent }
            }
        }
        // Full-bleed like PDF: pages run under the tabs and toolbar, which
        // float over them and reveal on hover.
        .ignoresSafeArea(.all, edges: .all)
        // Reflow to Fit sizes the pages to this.
        .onGeometryChange(for: CGSize.self, of: \.size) { size in
            viewSize = size
            guard size.width > 0, size.height > 0 else { return }
            reportViewport(fromNewView: !hasReportedSize)
            hasReportedSize = true
        }
        .onChange(of: notesPanelInset) { reportViewport() }
        .overlay(alignment: .topTrailing) {
            // PDF's comments slot: notes open beside the pages, never over them.
            ZStack(alignment: .topTrailing) {
                if showsNotesPanel {
                    EPUBNotesPanel(content: content, highlights: content.highlights) {
                        content.highlights.closePanel()
                    }
                    .onExitCommand { content.highlights.closePanel() }
                    .padding(.top, topChromeHeight + DesignTokens.spacingXS)
                    .padding(.bottom, DesignTokens.spacingMD)
                    .padding(.trailing, DesignTokens.spacingXS)
                    .pageFlowPanelTransition(edge: .trailing)
                }
            }
            .animation(.easeInOut(duration: DesignTokens.animationFast), value: content.highlights.isPanelShown)
            .environment(\.colorScheme, chromeScheme)
        }
        .overlay(alignment: .topLeading) {
            // PDF's sidebar slot: below the chrome, full height, sliding in.
            ZStack(alignment: .topLeading) {
                if isActive, showingContents, let book = content.book {
                    EPUBReaderSidebar(book: book, content: content, section: sidebarSection, close: {
                        showingContents = false
                    }, selectEntry: { entry in
                        // Stays open, like PDF's and Markdown's, to hop between sections.
                        content.selectContentsEntry(entry)
                    })
                    .onExitCommand { showingContents = false }
                    .environment(\.epubHighlightsExport, EPUBHighlightsExportActions(
                        content: content, tabManager: tabManager
                    ))
                    .padding(.top, topChromeHeight + DesignTokens.spacingXS)
                    .padding(.bottom, DesignTokens.spacingMD)
                    .padding(.leading, DesignTokens.spacingXS)
                    .pageFlowPanelTransition(edge: .leading)
                }
            }
            .animation(.easeInOut(duration: DesignTokens.animationFast), value: showingContents)
            .environment(\.colorScheme, chromeScheme)
        }
        // The Find bar's Show All Results opens the sidebar on Search.
        .onChange(of: content.searchManager.resultsListRequest) {
            sidebarSection.wrappedValue = .search
            showingContents = true
        }
        .onChange(of: showingContents) {
            if !showingContents { sidebarSection.wrappedValue = sidebarSection.wrappedValue.afterClosing }
        }
        .overlay(alignment: .bottom) {
            if isActive {
                bottomPageBar
                    .environment(\.colorScheme, chromeScheme)
            }
        }
        // Initial too: a tab rebuilt after the Mac switched catches up.
        .onChange(of: systemColorScheme, initial: true) { _, scheme in content.appearanceChanged(isDark: scheme == .dark) }
        // Read Aloud is the shown book's: switching tabs stops it.
        .onChange(of: isActive) { _, active in if !active { content.readAloud.stop() } }
        // What fell back shows once, in the window's pill, when the tab comes
        // into view rather than over the text; the chip's info button shows it again.
        .onChange(of: visibleNoticesMessage, initial: true) { _, message in
            guard let message, !shownNotices.contains(message) else { return }
            shownNotices.insert(message)
            showNotice(message)
        }
        .sheet(isPresented: showingGoToPage) {
            goToPageDialog.preferredColorScheme(chromeScheme)
        }
        // A supplement (linear="no") reads in its own sheet; Back closes it.
        .sheet(item: Binding(get: { isActive ? content.aside : nil }, set: { if $0 == nil { content.closeAside() } })) {
            EPUBLiveAsideView(content: content, id: $0.id)
                .preferredColorScheme(chromeScheme)
        }
        .overlay {
            FindOverlay(
                driver: content.searchManager,
                isActive: isActive,
                showingSearch: $showingSearch,
                focusRequest: searchFocusRequest,
                onBarWidthChange: { findBarWidth = $0 }
            )
            .environment(\.colorScheme, chromeScheme)
        }
        .pageFlowFileDropTarget(tabManager: tabManager)
    }

    private var backgroundColor: Color { Color(nsColor: DesignTokens.viewerBackground) }

    /// The pages sliding aside for the Notes panel; at once under Reduce Motion.
    static func notesReflowAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: DesignTokens.animationFast)
    }

    private var readyContent: some View {
        readingSurface
            // The pages make room for the Notes panel rather than run under it.
            .padding(.trailing, notesPanelInset)
            .animation(Self.notesReflowAnimation(reduceMotion: reduceMotion), value: notesPanelInset)
            .overlay {
                // Continuous pages get PDF's rail down the leading edge once the
                // reader zooms off the fit. Single pages and spreads turn
                // instead, so they never show it.
                if isActive && isDisplayed {
                    EPUBNavigationRail(
                        content: content,
                        eligible: isActive && isDisplayed && !showingContents && content.layout.isContinuous
                            && SettingsManager.shared.showNavigationRail && !content.isFitted
                            && content.navigationRailFitsViewport,
                        topInset: topChromeHeight,
                        onShowSidebar: { showingContents = true }
                    )
                }
            }
    }

    @ViewBuilder
    private var readingSurface: some View {
        if content.layout.isContinuous {
            EPUBPageStackSurface(
                pageCount: content.pagination.pageCount,
                pagesPerRow: content.layout.pagesPerRow,
                spreads: content.spreads,
                rightToLeft: content.book?.pageProgression == .rightToLeft,
                pageSize: content.geometry.pageSize,
                currentPage: content.currentPage,
                request: content.navigationRequest,
                restoring: content.readingSpot,
                onSurface: content.attachReadingSurface,
                zoom: content.zoom.pageScale,
                revision: pageRevision,
                topInset: topChromeHeight,
                isDisplayed: isDisplayed,
                pageContent: pageContent,
                onVisiblePage: content.updateVisiblePage,
                onZoom: content.setZoom,
                onOpenLink: content.followLink,
                onTurn: content.turnPage,
                onEscape: closeOnEscape,
                wantsKeyFocus: wantsKeyFocus,
                annotationDocument: content
            )
        } else {
            EPUBSpreadSurface(
                pagesPerRow: content.layout.pagesPerRow,
                spreads: content.spreads,
                pageSize: content.geometry.pageSize,
                currentPage: content.currentPage,
                pageCount: content.pagination.pageCount,
                rightToLeft: content.book?.pageProgression == .rightToLeft,
                revision: pageRevision,
                isDisplayed: isDisplayed,
                zoom: content.zoom.pageScale,
                pageContent: pageContent,
                onTurn: content.turnPage,
                onZoom: content.setZoom,
                onOpenLink: content.followLink,
                onGoToPage: content.goToPage,
                onEscape: closeOnEscape,
                wantsKeyFocus: wantsKeyFocus,
                annotationDocument: content,
                request: content.navigationRequest,
                restoring: content.readingSpot,
                onSurface: content.attachReadingSurface
            )
        }
    }

    /// Esc on the pages closes the Notes panel, then the sidebar; with
    /// neither open it is the key's to pass on. (Inside the panel or the
    /// sidebar, a field being typed in keeps Esc for itself.)
    private func closeOnEscape() -> Bool {
        if content.highlights.isPanelShown {
            content.highlights.closePanel()
        } else if showingContents {
            showingContents = false
        } else {
            return false
        }
        return true
    }

    /// Changes whenever what pages show changes: chapter text landing, the
    /// reader's highlights, or Find's matches (a new search, the next match,
    /// Find closing).
    private var pageRevision: Int {
        var hasher = Hasher()
        hasher.combine(content.chapterRevision)
        hasher.combine(content.highlights.revision)
        if showingSearch {
            hasher.combine(content.searchManager.resultsRevision)
            hasher.combine(content.navigationRequest?.generation)
        }
        return hasher.finalize()
    }

    /// What a page shows: its slice of the styled chapter, the chapter title
    /// above and the page number below, its highlights, and a Find match on it.
    private func pageContent(_ page: Int) -> EPUBPageContent {
        let palette = content.palette
        guard let book = content.book, let shown = content.pagination.page(at: page) else {
            return EPUBPageContent(header: "", footer: "", palette: palette, geometry: content.geometry)
        }
        // Matches show while Find is open: every one on the page, the current
        // one stronger, in the page's own offsets.
        var findMatch: NSRange?
        var matches: [NSRange] = []
        if showingSearch, let range = shown.range {
            func local(_ match: NSRange) -> NSRange? {
                guard NSLocationInRange(match.location, range) else { return nil }
                return NSRange(location: match.location - range.location,
                               length: min(match.length, NSMaxRange(range) - match.location))
            }
            if let current = content.navigationRequest?.findMatch, current.chapter == shown.chapter {
                findMatch = local(current.range)
            }
            matches = (content.searchManager.resultsByChapter[shown.chapter] ?? [])
                .compactMap(local)
                .filter { $0 != findMatch }
        }
        let chapter = content.cachedChapter(shown.chapter, page: shown.range)
        return EPUBPageContent(
            text: chapter?.text,
            range: shown.range,
            header: book.chapters[shown.chapter].title,
            footer: "\(page + 1)",
            palette: palette,
            findMatch: findMatch,
            matches: matches,
            findGeneration: content.navigationRequest?.generation ?? 0,
            geometry: content.geometry,
            family: content.typography.family,
            page: page,
            chapter: shown.chapter,
            highlights: shown.range.map {
                EPUBPageHighlight.onPage(content.highlights.items, chapter: shown.chapter, pageRange: $0)
            } ?? [],
            annotator: content.highlights,
            readAloud: content.readAloud,
            fixedPage: chapter?.fixedPage,
            document: content
        )
    }

    // MARK: - Notices

    private var noticesMessage: String? {
        guard case .ready = content.state, content.book != nil else { return nil }
        return content.currentNoticeMessage
    }

    /// Nil while the tab is hidden, so a tab shown later reports its book's.
    private var visibleNoticesMessage: String? { isActive ? noticesMessage : nil }

    private func showNotice(_ message: String) {
        tabManager.postTransientToast(message, duration: 5)
    }

    // MARK: - Page Indicator

    /// PDF's page indicator, with the reader's progress after the page
    /// ("Page 5 of 300 · 12%"): bottom trailing, shown on hover (or always,
    /// per Settings), shortened to stay
    /// clear of Find; clicking it opens Go to Page.
    private var bottomPageBar: some View {
        let labels = content.pageChipLabels
        return DocumentStatusBar(
            label: labels[0],
            shorterLabels: Array(labels.dropFirst()),
            centerReservation: FindOverlay.chipReservation(barWidth: findBarWidth),
            notice: noticesMessage.map { message in DocumentStatusNotice(message: message) { showNotice(message) } },
            help: "Go to page",
            height: topChromeHeight,
            action: { if content.pagination.pageCount > 0 { showingGoToPage.wrappedValue = true } }
        )
    }

    private var goToPageDialog: some View {
        // Takes a print page label ("iv") as well as a layout page number.
        GoToDialog(
            title: "Go to Page",
            prompt: content.goToPagePrompt,
            onSubmit: { content.goToPage(typed: "\($0)") },
            isPresented: showingGoToPage,
            onSubmitText: content.goToPage(typed:)
        )
    }

}

/// The sheet presentation owns identity; its body observes the current snapshot.
struct EPUBLiveAsideView: View {
    let content: EPUBContent
    let id: UUID

    var body: some View {
        if let aside = content.aside, aside.id == id {
            EPUBAsideView(aside: aside, onBack: content.closeAside, onLink: content.followAsideLink,
                          chromePalette: content.requestedPalette)
        }
    }
}
