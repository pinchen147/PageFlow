import AppKit
import EPUBKit
import Foundation
import Observation

nonisolated struct EPUBLocation: Equatable, Sendable {
    var chapterIndex: Int
    var characterOffset: Int
}

/// A request for the surface to show a page, optionally selecting a range
/// (a Find match) on it.
struct EPUBNavigationRequest: Equatable {
    let page: Int
    let findMatch: (chapter: Int, range: NSRange)?
    let generation: Int
    /// Where in the page to show, for a re-layout; a jump lands on the page's top.
    var spot: EPUBReadingSpot?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.generation == rhs.generation }
}

/// The EPUB document: metadata, whole-book pagination into fixed pages, a
/// bounded cache of styled chapters, and the reader's page, layout,
/// typography, page size and zoom (saved in `DocumentStateStore`), and the
/// reader's bookmarks and highlights (saved in `EPUBAnnotationStore`).
/// Surfaces draw pages; they never see the archive or the renderer.
///
/// Nothing is shown before it is ready: the book appears once its reading
/// chapter is styled and paginated, neighbouring chapters and nearby images
/// are prepared ahead of the reader, jumps wait for their chapter, and text
/// settings swap in only when the new pages are ready.
@Observable
@MainActor
final class EPUBContent: TabDocument {
    enum LoadState {
        case loading
        case ready
        case failed(String)
    }

    /// A book's saved page breaks for these settings. Called off the main thread.
    typealias SavedPages = @Sendable (URL, EPUBTypography, EPUBPageGeometry, Int) -> [[NSRange]]?

    /// The book's file; Save As moves the tab to the copy.
    @ObservationIgnored private(set) var documentURL: URL
    let searchManager: EPUBSearchManager
    let undo = UndoAvailabilityMirror()

    private(set) var state: LoadState = .loading
    /// Opened with its reading pages laid out: what the file commands wait for.
    var isReady: Bool {
        if case .ready = state { true } else { false }
    }
    /// Why the book failed to open, when the open-failure toast can say.
    @ObservationIgnored private(set) var failureReason: OpenFailureReason?
    private(set) var book: EPUBBook?
    private(set) var layout: EPUBPageLayout
    /// The settings the pages are laid out in.
    private(set) var typography: EPUBTypography
    /// The colours the pages are drawn in: the theme, with System settled
    /// for the Mac's appearance.
    private(set) var palette: EPUBPagePalette
    /// Whether the Mac is in Dark Mode, as the reader's view last saw it.
    private var isDarkAppearance: Bool
    /// The settings the controls show: ahead of `typography` while new pages
    /// are prepared.
    private(set) var requestedTypography: EPUBTypography
    /// The page size the book is laid out in.
    private(set) var geometry: EPUBPageGeometry
    /// The page size and layout asked for: ahead of `geometry` and `layout`
    /// while new pages are prepared.
    @ObservationIgnored private var requestedGeometry: EPUBPageGeometry
    @ObservationIgnored private var requestedLayout: EPUBPageLayout
    /// False until the reader has chosen a layout for this book.
    @ObservationIgnored private let hasSavedLayout: Bool
    /// How the pages are sized and scaled to the window.
    private(set) var zoom: EPUBZoom {
        didSet { if zoom.pageScale == nil { fittedZoom = zoom } }
    }
    /// The fitted mode (reflow or fit) a zoom near the fit snaps back to.
    @ObservationIgnored private var fittedZoom: EPUBZoom = .reflow
    private var viewport: CGSize?
    private var nativeRailFitsViewport: (owner: ObjectIdentifier, fits: Bool)?
    @ObservationIgnored private var topInset: CGFloat = 0
    @ObservationIgnored private var reflowTask: Task<Void, Never>?
    /// A new surface is waiting on pages for its window, off screen.
    private(set) var isReflowingBeforeShowing = false
    /// The reader's bookmarks and highlights live in the annotation store,
    /// filed under the book's identity, and arrive once the book has opened.
    private(set) var bookmarks: [EPUBBookmark] = []
    /// Highlights and notes, and the text selection they are made from.
    let highlights: EPUBHighlights
    /// Read Aloud, from the selection or the page's top (EPUBContent+ReadAloud).
    let readAloud = EPUBReadAloud()
    private(set) var pagination = EPUBPagination(chapterCount: 0)
    /// The print edition's page labels, placed once the book has opened.
    var pageLabels = EPUBPageLabels(marks: [])
    /// A supplement (a linear="no" spine item) open in its own reader over
    /// the pages; the reading flow never pages into it.
    var aside: EPUBAside?
    @ObservationIgnored var asideOpenTask: Task<Void, Never>?
    @ObservationIgnored var asideRefreshTask: Task<Void, Never>?
    @ObservationIgnored var asideOpenRevision = 0
    @ObservationIgnored var asideRefreshRevision = 0
    /// A closed document can never receive auxiliary work from its previous lifetime.
    @ObservationIgnored var asideLifetime: UUID? = UUID()
    /// The first page shown (the left page of a spread).
    private(set) var currentPage = 0
    private(set) var navigationRequest: EPUBNavigationRequest?
    /// Where Back and Forward go: places the reader jumped away from.
    private var trail = NavigationTrail<EPUBLocation>()
    /// A jump's target while its chapter is being prepared.
    @ObservationIgnored private var pendingTarget: EPUBLocation?
    /// The selection Find made, which goes when its results do.
    @ObservationIgnored private var findSelection: EPUBTextSelection?
    /// The book's contents, nested for the sidebar.
    @ObservationIgnored private(set) var contentsTree: [EPUBContentsNode] = []
    /// Where contents entries' anchors fall in chapters not in memory.
    private var contentsOffsets: [String: Int] = [:]
    /// Bumps when one of the reader's chapters lands, so visible pages fill in.
    private(set) var chapterRevision = 0
    /// Bumps when any chapter lands, so only the rail preview redraws.
    private(set) var thumbnailRevision = 0

    @ObservationIgnored private(set) var location: EPUBLocation {
        didSet { chapters.protected = (location.chapterIndex - 1)...(location.chapterIndex + 1) }
    }
    /// Where in the page the reader's view was last seen, to come back to.
    @ObservationIgnored private var readingPlace: EPUBReadingPlace?
    /// The live view, read on demand as PDF's live destination is.
    @ObservationIgnored private weak var readingSurface: (any EPUBReadingSurface)?
    @ObservationIgnored private var activationLocation: EPUBLocation
    /// Hidden long enough to give back what reading elsewhere doesn't need;
    /// the background pass then paginates without refilling the cache.
    @ObservationIgnored private var hasReleasedCaches = false
    /// What the annotation store holds for this book, once read or written.
    @ObservationIgnored private var savedAnnotations: EPUBAnnotations?
    @ObservationIgnored private var loadingTask: Task<Void, Never>?
    @ObservationIgnored private var paginationTask: Task<Void, Never>?
    @ObservationIgnored private var refillTask: Task<Void, Never>?
    @ObservationIgnored private var navigationTask: Task<Void, Never>?
    @ObservationIgnored private var typographyTask: Task<Void, Never>?
    @ObservationIgnored private var bookSearchTask: Task<EPUBSearchOutcome, Error>?
    @ObservationIgnored private(set) var paginationGeneration = 0
    @ObservationIgnored private var navigationGeneration = 0
    @ObservationIgnored private var scopedAccess = false
    @ObservationIgnored private let chapters = EPUBChapterCache()
    @ObservationIgnored private let stateStore: DocumentStateStore
    @ObservationIgnored private let annotationStore: EPUBAnnotationStore
    /// Where a new book takes its theme and font from, and the reader's last choice goes.
    @ObservationIgnored private let settings: SettingsManager
    /// Where the book's annotations are filed; nil until it has opened, so
    /// nothing is saved over them before they are read.
    @ObservationIgnored private var annotationKey: EPUBAnnotationStore.Key?
    /// Highlights and bookmarks an earlier build kept in the reading state,
    /// moved to the annotation store the first time the book opens.
    @ObservationIgnored private var legacyAnnotations: EPUBAnnotations
    @ObservationIgnored private let savedPages: SavedPages
    /// The open is still reading saved page breaks, and lays the book out next.
    @ObservationIgnored private var isAwaitingSavedPages = false
    /// What each chapter costs to style, read once off the main thread; empty
    /// until then, when no far page is styled in the moment.
    @ObservationIgnored private var chapterCosts: [EPUBChapterCost] = []
    @ObservationIgnored private var chapterCostsTask: Task<Void, Never>?
    /// Find asked before the book was ready.
    @ObservationIgnored private var searchWaitsForBook = false
    /// The chapter whose neighbours were last prepared.
    @ObservationIgnored private var preparedAround: Int?

    init(url: URL, isSecurityScoped: Bool, stateStore: DocumentStateStore = .shared,
         annotationStore: EPUBAnnotationStore = .shared, settings: SettingsManager = .shared,
         savedPages: @escaping SavedPages = { EPUBPaginationCache.load(for: $0, typography: $1, geometry: $2, chapterCount: $3) }) {
        documentURL = url
        self.savedPages = savedPages
        self.stateStore = stateStore
        self.annotationStore = annotationStore
        self.settings = settings
        let persisted = stateStore.state(for: url)
        let restored = persisted?.epubReaderState
        let layout = restored?.layout ?? .singlePageContinuous
        self.layout = layout
        requestedLayout = layout
        hasSavedLayout = restored?.layout != nil
        let typography = restored?.typography ?? settings.newBookTypography
        self.typography = typography
        requestedTypography = typography
        // The view reports the appearance once mounted; until then, the app's.
        let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        isDarkAppearance = isDark
        palette = typography.theme.palette(isDark: isDark)
        let geometry = (restored?.pageSize.map { EPUBPageGeometry(pageSize: $0) } ?? .standard)
            .measured(for: typography)
        self.geometry = geometry
        requestedGeometry = geometry
        // A book opens reflowed to the window unless the reader zoomed or fitted it.
        let zoom = restored?.zoom ?? .reflow
        self.zoom = zoom
        if zoom.pageScale == nil { fittedZoom = zoom }
        legacyAnnotations = EPUBAnnotations(highlights: restored?.highlights ?? [], bookmarks: restored?.bookmarks ?? [])
        highlights = EPUBHighlights()
        let restoredLocation = EPUBLocation(
            chapterIndex: restored?.chapterIndex ?? 0,
            characterOffset: restored?.characterOffset ?? persisted?.epubCharacterOffset ?? 0
        )
        location = restoredLocation
        activationLocation = restoredLocation
        readingPlace = restored?.place
        if isSecurityScoped {
            scopedAccess = url.startAccessingSecurityScopedResource()
        }
        searchManager = EPUBSearchManager()
        searchManager.searchProvider = { [weak self] query in
            // Nothing to search or show a match on yet: searched again once ready.
            guard let self, let book = self.book, case .ready = self.state else {
                self?.searchWaitsForBook = true
                return EPUBSearchOutcome(results: [])
            }
            self.bookSearchTask?.cancel()
            let task = Task.detached(priority: .userInitiated) { try book.searchBook(query) }
            self.bookSearchTask = task
            // A detached scan doesn't inherit cancellation; forward it.
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }
        searchManager.canReveal = { [weak self] in !(self?.pagination.isExcluded($0.chapterIndex) ?? false) }
        searchManager.willStep = { [weak self] in
            self?.recordJump(to: EPUBLocation(chapterIndex: $0.chapterIndex, characterOffset: $0.range.location))
        }
        searchManager.reveal = { [weak self] result in
            self?.navigate(
                to: EPUBLocation(chapterIndex: result.chapterIndex, characterOffset: result.range.location),
                findMatch: result.range
            )
        }
        searchManager.resultsWentAway = { [weak self] in self?.dropFindSelection() }
        searchManager.matchText = { [weak self] in self?.book?.searchExcerpt(for: $0)?.match }
        // Highlights, notes and bookmarks undo through the tab's Edit menu,
        // each change its own step: grouped by hand, not by event, so two
        // changes made in one event (Add Note's highlight, then its note)
        // still undo one at a time.
        undo.manager.groupsByEvent = false
        highlights.undoManager = undo.manager
        chapters.protected = (restoredLocation.chapterIndex - 1)...(restoredLocation.chapterIndex + 1)
        chapters.onInsert = { [weak self] in self?.chapterLanded($0) }
        highlights.excerpt = { [weak self] in self?.excerpt(chapter: $0, range: $1) ?? "" }
        // A supplement is read outside the flow, so a selection over it leaves it out.
        highlights.chapterText = { [weak self] chapter in
            guard let self, !pagination.isExcluded(chapter) else { return nil }
            return chapters.styledNow(chapter)?.text
        }
        highlights.chapterLength = { [weak self] chapter in
            guard let self else { return nil }
            if pagination.isExcluded(chapter) { return 0 }
            return chapters.peek(chapter)?.text.length ?? pagination.pages(ofChapter: chapter)?.last.map(NSMaxRange)
        }
        highlights.isChapterAtHand = { [weak self] chapter in
            guard let self else { return false }
            return pagination.isExcluded(chapter) || chapters.peek(chapter) != nil
        }
        highlights.plainText = { [weak self] selection in await self?.plainText(of: selection) }
        highlights.flowChapters = { [weak self] in
            guard let self, let book,
                  let first = book.chapters.indices.first(where: { !self.pagination.isExcluded($0) }),
                  let last = book.chapters.indices.last(where: { !self.pagination.isExcluded($0) }) else { return nil }
            return first...last
        }
        highlights.pageIndex = { [weak self] in self?.pagination.globalPage(chapter: $0.chapter, offset: $0.offset) }
        readAloud.chapterText = { [weak self] in await self?.chapters.styled($0)?.text.string }
        readAloud.chapterClips = { [weak self] chapter in
            // A footnote left out of the text isn't read, by voice or recording.
            guard let overlay = self?.book?.mediaOverlays.chapters[chapter],
                  let styled = await self?.chapters.styled(chapter) else { return [] }
            return EPUBNarrationClip.clips(of: overlay, text: styled.text.string as NSString, anchors: styled.anchors,
                                           hidden: Set(styled.detachedNotes.keys))
        }
        setUpReadAloud()
        highlights.onChange = { [weak self] in self?.saveAnnotations() }
    }

    deinit {
        loadingTask?.cancel()
        paginationTask?.cancel()
        refillTask?.cancel()
        navigationTask?.cancel()
        typographyTask?.cancel()
        asideOpenTask?.cancel()
        asideRefreshTask?.cancel()
        reflowTask?.cancel()
        bookSearchTask?.cancel()
        chapterCostsTask?.cancel()
        if scopedAccess { documentURL.stopAccessingSecurityScopedResource() }
    }

    func load() -> Task<Void, Never> {
        if let loadingTask { return loadingTask }
        if asideLifetime == nil { asideLifetime = UUID() }
        let url = documentURL
        let task = Task { [weak self] in
            do {
                let parsed = try await Task.detached(priority: .userInitiated) { try EPUBBook.open(url: url) }.value
                guard let self, !Task.isCancelled else { return }
                book = parsed
                contentsTree = EPUBContentsNode.tree(of: parsed.contents)
                readChapterCosts(of: parsed)
                setUpNarration(of: parsed)
                restoreAnnotations(of: parsed)
                resolvePageLabels(of: parsed)
                if !parsed.chapters.indices.contains(location.chapterIndex) {
                    location = EPUBLocation(chapterIndex: 0, characterOffset: 0)
                    readingPlace = nil
                }
                // A place saved inside a supplement reads on from the flow after it.
                if !parsed.chapters[location.chapterIndex].isLinear {
                    let next = parsed.chapters.indices.first { $0 > location.chapterIndex && parsed.chapters[$0].isLinear }
                        ?? parsed.chapters.firstIndex { $0.isLinear } ?? 0
                    location = EPUBLocation(chapterIndex: next, characterOffset: 0)
                    activationLocation = location
                    readingPlace = nil
                }
                // A fixed-layout book reads a page at a time unless asked otherwise.
                if !hasSavedLayout, parsed.fixedPageSize != nil {
                    layout = .singlePage
                    requestedLayout = .singlePage
                }
                // The window is known by now: lay out for it from the start.
                if parsed.fixedPageSize != nil || zoom == .reflow, let viewport {
                    geometry = fittedGeometry(viewport, layout: layout)
                    requestedGeometry = geometry
                } else if let sheet = fixedSheet {
                    geometry = measured(sheet)
                    requestedGeometry = geometry
                }
                let (typography, geometry, generation) = (typography, geometry, paginationGeneration)
                let savedPages = savedPages
                isAwaitingSavedPages = true
                let saved = await Task.detached(priority: .userInitiated) {
                    savedPages(url, typography, geometry, parsed.chapters.count)
                }.value
                isAwaitingSavedPages = false
                // A relayout still under way (a resize, new text settings) lays
                // the book out itself, finishing the open. One already settled
                // changed nothing the saved breaks depend on.
                guard !Task.isCancelled, paginationGeneration == generation,
                      requestedTypography == self.typography, requestedPalette == palette,
                      requestedGeometry == self.geometry,
                      requestedLayout == layout else { return }
                // Stays loading (the viewer background) until the reading pages are ready.
                repaginate(saved.map(PageSource.saved) ?? .fresh(seeded: [:]))
            } catch {
                guard let self, !Task.isCancelled else { return }
                if case EPUBError.drmProtected = error { failureReason = .drmProtected }
                state = .failed(Self.message(for: error))
            }
        }
        loadingTask = task
        return task
    }

    // MARK: - Pagination

    /// Where a pagination's page breaks come from.
    enum PageSource {
        /// Computed now: the reader's chapters (`seeded`, when already
        /// paginated) first, the rest in the background, then saved.
        case fresh(seeded: [Int: [NSRange]])
        /// Saved for this book and these text settings.
        case saved([[NSRange]])
        /// Unchanged: only the theme changed.
        case kept
    }

    #if DEBUG
    /// Whole-book layout passes begun, for `CountBudgetTests`.
    private(set) static var debugPaginationPasses = 0
    #endif

    /// Lays the book out for the current typography and page size. `seed` holds chapters
    /// already styled for it. The reader's chapters are prepared first; the
    /// background then paginates the rest outward from the reader and keeps
    /// their styled text while it fits.
    private func repaginate(_ source: PageSource, seed: [Int: EPUBStyledChapter] = [:]) {
        guard let book else { return }
        #if DEBUG
        Self.debugPaginationPasses += 1
        #endif
        paginationTask?.cancel()
        paginationGeneration &+= 1
        preparedAround = nil
        let generation = paginationGeneration
        let (typography, palette, geometry) = (typography, palette, geometry)
        chapters.reset(book: book, typography: typography, palette: palette, geometry: geometry, seed: seed)
        var savesPages = false
        switch source {
        case .kept:
            break
        case .saved(let pages):
            pagination = EPUBPagination(pages: pages, excluded: book.excludedChapters, sides: book.pageSides,
                                        rightToLeft: book.pageProgression == .rightToLeft)
        case .fresh(let seeded):
            pagination = EPUBPagination(chapterCount: book.chapters.count, excluded: book.excludedChapters,
                                        sides: book.pageSides, rightToLeft: book.pageProgression == .rightToLeft)
            for (chapter, pages) in seeded { pagination.set(pages, forChapter: chapter) }
            savesPages = true
        }
        followReader()
        let movesView: Bool = if case .kept = source { false } else { true }
        // Only the layout the hold waits for ends it, not one already under way.
        let endsHold = isReflowingBeforeShowing
        let first = location.chapterIndex
        let url = documentURL
        paginationTask = Task { [weak self] in
            await self?.prepareReadingChapters(around: first)
            self?.showReader(movingView: movesView, generation: generation, endingHold: endsHold)
            for chapter in Self.outward(from: first, count: book.chapters.count) {
                // Holds the tab for one chapter at most; closing it cancels the pass.
                guard let self, !Task.isCancelled else { return }
                guard let step = backgroundStep(for: chapter) else { continue }
                let result = await Task.detached(priority: .utility) {
                    let text = step.cached
                        ?? EPUBStyledChapter.make(book: book, chapter: chapter, typography: typography,
                                                  palette: palette, geometry: geometry)
                    let pages = step.paginates ? text.pages(fitting: geometry.textSize) : nil
                    return (text: text, pages: pages)
                }.value
                guard paginationGeneration == generation else { return }
                if let pages = result.pages {
                    pagination.set(pages, forChapter: chapter)
                    followReader()
                }
                if !hasReleasedCaches { chapters.admitIfRoom(result.text, for: chapter) }
            }
            guard savesPages, let pages = self?.pagination.completePages else { return }
            await Task.detached(priority: .utility) {
                EPUBPaginationCache.save(pages, for: url, typography: typography, geometry: geometry)
            }.value
        }
    }

    /// Chapters ordered by distance from the reader's, nearest (and later) first.
    private static func outward(from first: Int, count: Int) -> [Int] {
        guard count > 1 else { return [] }
        return (1..<count).flatMap { [first + $0, first - $0] }.filter { (0..<count).contains($0) }
    }

    /// What the background pass does for a chapter, or nil when it is done:
    /// paginate it (from its cached text when there is one), and style it
    /// while the cache has room.
    private func backgroundStep(for chapter: Int) -> (cached: EPUBStyledChapter?, paginates: Bool)? {
        let cached = chapters.peek(chapter)
        let paginates = !pagination.isPaginated(chapter)
        guard paginates || (cached == nil && chapters.hasRoom && !hasReleasedCaches) else { return nil }
        return (cached, paginates)
    }

    /// Keeps the reader's page on its passage as page numbers shift.
    private func followReader() {
        currentPage = alignedToSpread(pagination.globalPage(chapter: location.chapterIndex, offset: location.characterOffset))
        // The page number moved, not the reader: Read Aloud keeps following.
        readAloud.pageFollow.followed(to: currentPage)
    }

    /// Shows the book once its reading pages are ready, on the page holding
    /// the reader's passage. The passage itself is kept, so re-laying out
    /// never walks the reader back to a spread's first page. A theme change
    /// keeps the reader exactly where they are.
    private func showReader(movingView: Bool, generation: Int, endingHold: Bool) {
        guard paginationGeneration == generation else { return }
        if endingHold { isReflowingBeforeShowing = false }
        if movingView {
            followReader()
            readAloud.viewRelaidOut()
            navigationGeneration &+= 1
            navigationRequest = EPUBNavigationRequest(page: currentPage, findMatch: nil, generation: navigationGeneration,
                                                      spot: readingSpot)
            prepareAroundReader()
        }
        if case .loading = state {
            state = .ready
            if searchWaitsForBook {
                searchWaitsForBook = false
                searchManager.runSearch()
            }
        }
    }

    // MARK: - Preparing chapters

    private func readChapterCosts(of book: EPUBBook) {
        chapterCostsTask = Task.detached(priority: .utility) { [weak self] in
            let costs = book.chapterCosts()
            guard !Task.isCancelled else { return }
            await self?.applyChapterCosts(costs)
        }
    }

    private func applyChapterCosts(_ costs: [EPUBChapterCost]) { chapterCosts = costs }

    /// The reader's chapter and its neighbours, prepared together, so a
    /// spread, a page by a chapter edge, or a turn back shows text at once.
    private func prepareReadingChapters(around chapter: Int, decoding page: EPUBWantedPage? = nil) async {
        preparedAround = chapter
        let before = pagination.flowChapter(from: chapter, forward: false) ?? -1
        let after = pagination.flowChapter(from: chapter, forward: true) ?? -1
        async let previous: Void = prepare(before)
        async let current: Void = prepare(chapter, decoding: page)
        async let next: Void = prepare(after)
        _ = await (previous, current, next)
    }

    /// Styles and paginates a chapter now, ahead of the background pass.
    /// Saved breaks that run past the styled text (a stale cache) are redone.
    private func prepare(_ chapter: Int, decoding page: EPUBWantedPage? = nil) async {
        guard let book, book.chapters.indices.contains(chapter) else { return }
        let generation = paginationGeneration
        guard let styled = await chapters.styled(chapter, decoding: page), paginationGeneration == generation else { return }
        if let pages = pagination.pages(ofChapter: chapter) {
            guard let last = pages.last, NSMaxRange(last) > styled.text.length else { return }
            let (url, typography, geometry) = (documentURL, typography, geometry)
            Task.detached(priority: .background) {
                EPUBPaginationCache.remove(for: url, typography: typography, geometry: geometry)
            }
        }
        let textSize = geometry.textSize
        let pages = await Task.detached(priority: .userInitiated) {
            styled.pages(fitting: textSize)
        }.value
        guard paginationGeneration == generation else { return }
        pagination.set(pages, forChapter: chapter)
        followReader()
    }

    private func isReady(_ chapter: Int) -> Bool {
        chapters.peek(chapter) != nil && pagination.isPaginated(chapter)
    }

    /// The styled text a page draws. A chapter that isn't cached is styled here
    /// if that takes moments, so a far scroll never finds blank paper; a longer
    /// one starts styling and the page fills in on `chapterRevision`, its images
    /// decoded by then. Over the stall bar is worse than a moment of blank paper.
    func cachedChapter(_ chapter: Int, page: NSRange? = nil) -> EPUBStyledChapter? {
        if let cached = chapters.chapter(chapter) { return cached }
        if stylesAtOnce(chapter) { return chapters.styledNow(chapter) }
        let wanted = page.map { EPUBWantedPage(range: $0, pixels: pixelsPerPoint) }
        Task { _ = await chapters.styled(chapter, decoding: wanted) }
        return nil
    }

    /// Most a far page may hold the main thread styling and drawing, by the
    /// chapter's estimate (`EPUBChapterCost`): well inside the 100 ms stall bar.
    private static let styledAtOnceBudget = 50.0

    /// Whether the chapter's length and cost are known and small. Never for a
    /// tab out of sight, which has no page to show, or one already being styled.
    private func stylesAtOnce(_ chapter: Int) -> Bool {
        guard !hasReleasedCaches, !chapters.isStyling(chapter), let book, chapterCosts.indices.contains(chapter),
              let last = pagination.pages(ofChapter: chapter)?.last else { return false }
        return book.stylingMilliseconds(chapterCosts[chapter], characters: NSMaxRange(last)) <= Self.styledAtOnceBudget
    }

    /// The chapter nearest the reader that `isFilled` says is missing, later
    /// ones first.
    static func nearestUnfilledChapter(to reader: Int, count: Int, isFilled: (Int) -> Bool) -> Int? {
        for distance in 0..<max(count, reader + 1) {
            for chapter in [reader + distance, reader - distance] where (0..<count).contains(chapter) && !isFilled(chapter) {
                return chapter
            }
        }
        return nil
    }

    /// The chapter text a rail thumbnail draws, queued at low priority when
    /// missing; it fills in on `thumbnailRevision`.
    func thumbnailChapter(_ chapter: Int) -> EPUBStyledChapter? {
        if let cached = chapters.peek(chapter) { return cached }
        chapters.request(chapter)
        return nil
    }

    /// Whether the book's chapter costs have been read (tests).
    var knowsChapterCosts: Bool { !chapterCosts.isEmpty }

    /// Whether a chapter's styled text is cached (tests).
    func isStyled(_ chapter: Int) -> Bool { chapters.peek(chapter) != nil }

    /// A chapter's styled text if cached; never starts styling it.
    func styledChapterIfReady(_ chapter: Int) -> EPUBStyledChapter? { chapters.peek(chapter) }

    /// A chapter for work away from the reader: styled now if it isn't in
    /// memory, and first to leave so it never pushes out the reader's chapters.
    func styledChapter(_ chapter: Int) async -> EPUBStyledChapter? {
        await chapters.styled(chapter, asLeastRecent: true)
    }

    private func chapterLanded(_ chapter: Int) {
        thumbnailRevision &+= 1
        guard chapters.protected.contains(chapter) else { return }
        chapterRevision &+= 1
        prefetchImagesNearReader()
    }

    /// Prepares the chapters around the reader before they are scrolled or
    /// turned to, and the images on the pages nearby.
    private func prepareAroundReader() {
        let chapter = location.chapterIndex
        if book != nil, preparedAround != chapter {
            Task { await prepareReadingChapters(around: chapter) }
        }
        prefetchImagesNearReader()
    }

    private var pixelsPerPoint: CGFloat { currentScale * (NSScreen.main?.backingScaleFactor ?? 2) }

    /// Decodes the images on the pages around the reader ahead of display.
    private func prefetchImagesNearReader() {
        let last = min(pagination.pageCount - 1, currentPage + layout.pagesPerRow + 3)
        guard last >= 0 else { return }
        // A fixed page's images decode for the pixels it fills at this scale.
        let pixels = pixelsPerPoint
        for page in max(0, currentPage - 2)...max(0, last) {
            guard let shown = pagination.page(at: page), let range = shown.range,
                  let styled = chapters.peek(shown.chapter) else { continue }
            if let fixed = styled.fixedPage {
                fixed.prefetch(pixelsPerPoint: pixels * fixed.frame(in: geometry.pageSize).width / fixed.size.width)
            } else {
                styled.text.prefetchEPUBImages(in: range)
            }
        }
    }

    // MARK: - Navigation

    func selectContentsEntry(_ entry: EPUBContentsEntry) {
        recordJump(toChapter: entry.chapterIndex, fragment: entry.fragment)
        navigate(to: EPUBLocation(chapterIndex: entry.chapterIndex, characterOffset: 0), fragment: entry.fragment)
    }

    /// A link's `#heading`: goes to the first contents entry it names, matched
    /// as a note's headings are.
    func goToContentsEntry(headed fragment: String) {
        guard let contents = book?.contents,
              let index = HeadingSlug.firstIndex(of: fragment, in: contents.map(\.title)) else { return }
        selectContentsEntry(contents[index])
    }

    func selectLandmark(_ landmark: EPUBLandmark) {
        recordJump(toChapter: landmark.chapterIndex, fragment: landmark.fragment)
        navigate(to: EPUBLocation(chapterIndex: landmark.chapterIndex, characterOffset: 0), fragment: landmark.fragment)
    }

    /// A link on a page. A note reference shows its note at the link and
    /// leaves the reader where they are; any other book link jumps, and
    /// Back returns.
    func followLink(_ url: URL) -> EPUBLinkResult {
        guard url.scheme == EPUBBook.internalLinkScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
              let chapter = book?.chapters.firstIndex(where: { $0.path == path }) else {
            return .unhandled
        }
        guard let reference = url.epubNoteReference, let fragment = components.fragment else {
            jumpToLink(chapter: chapter, fragment: components.fragment)
            return .followed
        }
        let generation = navigationGeneration
        let page = currentPage
        return .footnote(Task { [weak self] in
            guard let self else { return nil }
            if let note = await footnote(chapter: chapter, fragment: fragment, reference: reference) { return note }
            // Read as no note, the link jumps instead, unless the reader
            // moved on while it was being read: a late jump would take
            // them from wherever they went.
            guard navigationGeneration == generation, currentPage == page, pendingTarget == nil else { return nil }
            jumpToLink(chapter: chapter, fragment: fragment)
            return nil
        })
    }

    func jumpToLink(chapter: Int, fragment: String?) {
        recordJump(toChapter: chapter, fragment: fragment)
        navigate(to: EPUBLocation(chapterIndex: chapter, characterOffset: 0), fragment: fragment)
    }

    /// The note a reference points to, styled as the pages are; nil when
    /// the target reads as no note (a whole section, a missing id).
    private func footnote(chapter: Int, fragment: String, reference: EPUBNoteReference) async -> EPUBFootnote? {
        guard let styled = await chapters.styled(chapter, asLeastRecent: true) else { return nil }
        // A note left out of the pages is only a pop-up: nowhere to go to.
        if let detached = styled.detachedNotes[fragment] {
            let text = EPUBFootnote.trimmed(detached)
            return text.length > 0 ? EPUBFootnote(text: text, palette: palette, goToNote: nil) : nil
        }
        guard let target = styled.noteTargets[fragment], target.showsAsNote(for: reference),
              NSMaxRange(target.range) <= styled.text.length else { return nil }
        let text = EPUBFootnote.trimmed(styled.text.attributedSubstring(from: target.range))
        guard text.length > 0 else { return nil }
        return EPUBFootnote(text: text, palette: palette) { [weak self] in
            self?.jumpToLink(chapter: chapter, fragment: fragment)
        }
    }

    /// A jump the reader can come back from with Back (⌘[): a bookmark.
    func jump(to target: EPUBLocation) {
        recordJump(to: target)
        navigate(to: target)
    }

    /// A jump to a page the reader can come back from: Go to Page, First or
    /// Last Page, the rail.
    func jump(toPage page: Int) {
        recordJump(toPageAt: page)
        goToPage(page)
    }

    /// A jump to one of Find's matches from the results list: it becomes
    /// Find's current match, and Back returns.
    func jump(toMatch index: Int) {
        guard searchManager.results.indices.contains(index) else { return }
        searchManager.setCurrentIndex(index)
        let result = searchManager.results[index]
        recordJump(to: EPUBLocation(chapterIndex: result.chapterIndex, characterOffset: result.range.location))
        navigate(to: EPUBLocation(chapterIndex: result.chapterIndex, characterOffset: result.range.location),
                 findMatch: result.range)
    }

    var canGoBack: Bool { trail.canGoBack }
    var canGoForward: Bool { trail.canGoForward }

    func goBack() {
        guard let previous = trail.goBack(from: here) else { return }
        navigate(to: previous)
    }

    func goForward() {
        guard let next = trail.goForward(from: here) else { return }
        navigate(to: next)
    }

    /// Where the reader is, or is on the way to while a jump's chapter is
    /// still being prepared: what Back and Forward remember.
    private var here: EPUBLocation { pendingTarget ?? location }

    /// Where a contents entry starts in its chapter, once that chapter is styled.
    func offset(of entry: EPUBContentsEntry) -> Int {
        entry.fragment.flatMap { chapters.peek(entry.chapterIndex)?.anchors[$0] ?? contentsOffsets[entry.id] } ?? 0
    }

    /// Places every contents entry in its chapter, so sections read their own
    /// pages before their chapters are in memory. Asked for by the Contents list.
    func resolveContentsOffsets() async {
        guard let book, contentsOffsets.isEmpty else { return }
        let entries = book.contents.filter { $0.fragment != nil && chapters.peek($0.chapterIndex) == nil }
        guard !entries.isEmpty else { return }
        contentsOffsets = await Task.detached(priority: .utility) {
            var offsets: [String: Int] = [:]
            for entry in entries where !Task.isCancelled {
                guard let fragment = entry.fragment else { continue }
                offsets[entry.id] = book.anchorOffset(chapter: entry.chapterIndex, fragment: fragment)
            }
            return offsets
        }.value
    }

    /// Remembers where the reader was before a jump; a new jump drops the
    /// forward trail, as in a browser. `BackRule` says which jumps; one into a
    /// supplement leaves the reader where they are, so it records nothing.
    private func recordJump(to target: EPUBLocation) {
        guard !pagination.isExcluded(target.chapterIndex) else { return }
        recordJump(toPageAt: pagination.globalPage(chapter: target.chapterIndex, offset: target.characterOffset))
    }

    /// A contents entry's or link's target, by its anchor once its chapter is
    /// at hand; a jump into another chapter changes the page regardless.
    private func recordJump(toChapter chapter: Int, fragment: String?) {
        let anchor = fragment.flatMap { chapters.peek(chapter)?.anchors[$0] }
        recordJump(to: EPUBLocation(chapterIndex: chapter, characterOffset: anchor ?? 0))
    }

    private func recordJump(toPageAt page: Int) {
        let target = min(max(0, page), max(0, pagination.pageCount - 1))
        guard pendingTarget != nil || BackRule.records(from: currentPage, to: alignedToSpread(target)) else { return }
        trail.recordJump(from: here)
    }

    /// A supplement opens in its own reader; anything else in the flow.
    func navigate(to target: EPUBLocation, fragment: String? = nil, findMatch: NSRange? = nil) {
        guard let book, book.chapters.indices.contains(target.chapterIndex) else { return }
        if findMatch == nil { searchManager.cancelPendingReveal() }
        if pagination.isExcluded(target.chapterIndex) {
            openAside(chapter: target.chapterIndex, fragment: fragment, match: findMatch,
                      offset: target.characterOffset)
            return
        }
        navigationTask?.cancel()
        pendingTarget = target
        navigationTask = Task { [weak self] in
            guard let self else { return }
            let landing = pagination.page(at: pagination.globalPage(chapter: target.chapterIndex, offset: target.characterOffset))?.range
            await prepareReadingChapters(around: target.chapterIndex,
                                         decoding: landing.map { EPUBWantedPage(range: $0, pixels: pixelsPerPoint) })
            var resolved = target
            if let fragment, let anchor = chapters.peek(target.chapterIndex)?.anchors[fragment] {
                resolved.characterOffset = anchor
            }
            guard !Task.isCancelled else { return }
            showPage(
                pagination.globalPage(chapter: resolved.chapterIndex, offset: resolved.characterOffset),
                findMatch: findMatch.map { (resolved.chapterIndex, $0) }
            )
        }
    }

    /// Shows a page at once when every page it brings into view is ready;
    /// otherwise the current pages stay until they are, so a jump never
    /// shows blank paper.
    func goToPage(_ page: Int) {
        let target = alignedToSpread(min(max(0, page), max(0, pagination.pageCount - 1)))
        guard let shown = pagination.page(at: target) else { return }
        searchManager.cancelPendingReveal()
        let spread = spreads.row(holding: target).pages.compactMap(pagination.page(at:))
        if spread.allSatisfy({ isReady($0.chapter) }) {
            navigationTask?.cancel()
            showPage(target, findMatch: nil)
        } else {
            navigate(to: EPUBLocation(chapterIndex: shown.chapter, characterOffset: shown.range?.location ?? 0))
        }
    }

    private func showPage(_ page: Int, findMatch: (chapter: Int, range: NSRange)?) {
        // Any page shown settles a jump that was still on its way.
        pendingTarget = nil
        readingPlace = nil
        setCurrentPage(page)
        navigationGeneration &+= 1
        navigationRequest = EPUBNavigationRequest(page: currentPage, findMatch: findMatch, generation: navigationGeneration)
        if let findMatch { select(findMatch) }
    }

    /// As in a PDF, the current match is the selection: Copy and Highlight act on it.
    private func select(_ match: (chapter: Int, range: NSRange)) {
        findSelection = EPUBTextSelection(chapter: match.chapter, range: match.range)
        highlights.select(findSelection)
    }

    /// A selection the reader made since stays.
    private func dropFindSelection() {
        if highlights.selection == findSelection { highlights.select(nil) }
        findSelection = nil
    }

    // MARK: Reading place

    /// The surface showing this book; a rebuilt view replaces the last.
    func attachReadingSurface(_ surface: any EPUBReadingSurface) {
        guard readingSurface !== surface else { return }
        readingSurface = surface
        if let stack = surface as? EPUBPageStackScrollView {
            stack.onFitWidthChanged = { [weak self, weak stack] fits in
                guard let self, let stack, self.readingSurface === stack,
                      stack.window != nil, !stack.isHiddenOrHasHiddenAncestor else { return }
                self.nativeRailFitsViewport = (ObjectIdentifier(stack), fits)
            }
            stack.scheduleFitWidthPublication()
        }
        // A view can go with no notice: a tab moved, or rebuilt.
        surface.onLeaving = { [weak self, weak surface] place in
            guard let self, surface === readingSurface else { return }
            readingPlace = place
            readingSurface = nil
            nativeRailFitsViewport = nil
        }
    }

    /// Where a view of this book should show: the reader's own place, while
    /// there is one. A view built afresh comes back here.
    var readingSpot: EPUBReadingSpot? {
        readingPlace.map {
            EPUBReadingSpot(page: pagination.globalPage(chapter: $0.chapter, offset: $0.offset), place: $0)
        }
    }

    /// Takes the place from the live view, which goes on showing it until
    /// the reader moves or the view is gone.
    private func captureReadingPlace() {
        if let readingSurface { readingPlace = readingSurface.readingPlace }
    }

    /// Reported by the continuous surfaces as the reader scrolls.
    func updateVisiblePage(_ page: Int) {
        guard page != currentPage else { return }
        // What was read off the view has gone by; it is read again when needed.
        readingPlace = nil
        setCurrentPage(page)
    }

    private func setCurrentPage(_ page: Int) {
        currentPage = alignedToSpread(page)
        if let shown = pagination.page(at: currentPage) {
            location = EPUBLocation(chapterIndex: shown.chapter, characterOffset: shown.range?.location ?? 0)
        }
        prepareAroundReader()
    }

    private func alignedToSpread(_ page: Int) -> Int {
        spreads.row(holding: page).first
    }

    /// Which pages share a row in the current layout.
    var spreads: EPUBSpreadTable { pagination.spreads(pagesPerRow: layout.pagesPerRow) }

    /// The pages in view from the current page.
    var currentRow: EPUBSpreadTable.Row { spreads.row(holding: currentPage) }

    // MARK: - Page turning

    func canTurn(forward: Bool) -> Bool {
        forward ? currentRow.pages.upperBound < pagination.pageCount : currentPage > 0
    }

    /// Returns whether there was a page to turn to.
    @discardableResult
    func turnPage(forward: Bool) -> Bool {
        guard canTurn(forward: forward) else { return false }
        goToPage(forward ? currentRow.pages.upperBound : currentPage - 1)
        return true
    }

    /// "Page 5 of 300", or "Pages 5–6 of 300" for a spread showing two,
    /// then the print page when the book has labels: "· p. iv".
    var pageLabel: String {
        let total = pagination.isComplete ? "\(pagination.pageCount)" : "~\(pagination.pageCount)"
        let last = min(pagination.pageCount, currentRow.pages.upperBound)
        let shown = (currentPage..<max(currentPage, last)).compactMap(printedPageLabel(forPage:))
        let printed = EPUBPageLabels.span(shown).map { " · p. \($0)" } ?? ""
        guard last > currentPage + 1 else { return "Page \(currentPage + 1) of \(total)" + printed }
        return "Pages \(currentPage + 1)–\(last) of \(total)" + printed
    }

    /// The page chip's labels, longest first: page and progress, page alone,
    /// then compact page counts. Before the book has pages, its name.
    var pageChipLabels: [String] {
        // No pages yet: the chip says what is opening, never "Page 1 of ~0".
        guard pagination.pageCount > 0 else { return [documentTitle] }
        let page = pageLabel
        let progressLabels = readingProgress.map { ["\(page) · \($0.percentLabel)"] } ?? []
        let total = pagination.isComplete ? "\(pagination.pageCount)" : "~\(pagination.pageCount)"
        let last = min(pagination.pageCount, currentRow.pages.upperBound)
        let shown = last > currentPage + 1 ? "\(currentPage + 1)–\(last)" : "\(currentPage + 1)"
        return progressLabels + [page, "\(shown) / \(total)"]
    }

    // MARK: - Layout, typography, zoom

    /// While reflowing, the new layout's pages (two share the window one page
    /// filled) are prepared first and switch in together with it.
    func setLayout(_ newLayout: EPUBPageLayout) {
        guard newLayout != requestedLayout else { return }
        requestedLayout = newLayout
        persistReadingPosition()
        if zoom == .reflow, book != nil, let viewport {
            requestedGeometry = fittedGeometry(viewport, layout: newLayout)
            relayout()
            return
        }
        captureReadingPlace()
        layout = newLayout
        showReaderInNewLayout()
    }

    /// The words at the top of the view stay at the top. A continuous view's page is the
    /// one a quarter of the way down it, which short rows make a row further on.
    private func showReaderInNewLayout() {
        guard let spot = readingSpot else { return showPage(currentPage, findMatch: nil) }
        pendingTarget = nil
        setCurrentPage(spot.page)
        readingPlace = spot.place
        navigationGeneration &+= 1
        navigationRequest = EPUBNavigationRequest(page: currentPage, findMatch: nil, generation: navigationGeneration, spot: spot)
    }

    /// The colours the requested theme draws in, for the Mac's appearance.
    var requestedPalette: EPUBPagePalette { requestedTypography.theme.palette(isDark: isDarkAppearance) }

    /// The Mac switched Light/Dark (or the view first reports it): a
    /// System-themed book recolours its pages; page breaks stay.
    func appearanceChanged(isDark: Bool) {
        guard isDark != isDarkAppearance else { return }
        isDarkAppearance = isDark
        guard requestedTypography.theme == .system else { return }
        auxiliaryAppearanceChanged()
        relayout()
    }

    /// The sheet of a book that is mostly fixed pages. Its pages keep their
    /// proportions in every layout: Reflow to Fit has nothing to re-flow and fits.
    private var fixedSheet: EPUBPageGeometry? { book?.fixedPageSize.map(EPUBPageGeometry.fixedSheet) }

    /// The page Reflow to Fit makes for a window: the window's, or a fixed book's own.
    private func fittedGeometry(_ viewport: CGSize, layout: EPUBPageLayout) -> EPUBPageGeometry {
        measured(fixedSheet ?? .filling(viewport, layout: layout, topInset: topInset))
    }

    /// A page with the reading measure and margins for the requested text settings.
    private func measured(_ geometry: EPUBPageGeometry) -> EPUBPageGeometry {
        geometry.measured(for: requestedTypography)
    }

    /// A typography change built from the requested settings, so it never
    /// drops the reader's other choices.
    func updateTypography(_ mutate: (inout EPUBTypography) -> Void) {
        var typography = requestedTypography
        mutate(&typography)
        setTypography(typography)
    }

    /// The reader picks a theme: for this book, and any new book after it.
    func chooseTheme(_ theme: EPUBReaderTheme) {
        settings.bookTheme = theme
        updateTypography { $0.theme = theme }
    }

    /// The reader picks a font: for this book, and any new book after it.
    func chooseFont(_ choice: EPUBFontChoice) {
        updateTypography { choice.apply(to: &$0) }
        settings.bookFontFamily = requestedTypography.family
        settings.bookFontName = requestedTypography.fontName
    }

    func setTypography(_ newTypography: EPUBTypography) {
        guard newTypography != requestedTypography else { return }
        requestedTypography = newTypography
        auxiliaryAppearanceChanged()
        // Larger text keeps the same number of characters to a line.
        requestedGeometry = measured(requestedGeometry)
        persistReadingPosition()
        relayout()
    }

    /// Auxiliary readers follow the request without changing the committed page pair.
    private func auxiliaryAppearanceChanged() {
        refreshAsidePalette()
        EPUBZoomPanel.refreshPalette(for: self)
    }

    /// Prepares the book under the requested text settings and page size off
    /// the main thread, then swaps it in at once; the old pages stay until
    /// then. A theme change recolours every cached chapter and keeps every
    /// page break; other changes style and paginate the reader's chapters first.
    private func relayout() {
        typographyTask?.cancel()
        // The old pages still show it: the new ones keep the same words at the top.
        captureReadingPlace()
        // A page at a time: the page shown is the one holding those words.
        if let readingPlace, !requestedLayout.isContinuous {
            location = EPUBLocation(chapterIndex: readingPlace.chapter, characterOffset: readingPlace.offset)
        }
        let (newTypography, newPalette, newGeometry, newLayout) = (requestedTypography, requestedPalette,
                                                                   requestedGeometry, requestedLayout)
        // Nothing to draw anew (a theme choice that draws the same, a layout
        // switch): settle the request without touching the pages.
        guard let book, !newTypography.paginatesLike(typography) || newPalette != palette
            || newGeometry != geometry else {
            isReflowingBeforeShowing = false
            typography = newTypography
            geometry = newGeometry
            if newLayout != layout {
                layout = newLayout
                showReaderInNewLayout()
            }
            // Dropping a relayout that was to finish the open: nothing else will.
            if book != nil, paginationGeneration == 0, !isAwaitingSavedPages {
                repaginate(.fresh(seeded: [:]))
            }
            return
        }
        // A new page size waits for the whole book, so the page count never
        // grows in view; the old pages stay, fitted, meanwhile. New text
        // settings show at once, from the reader's chapters.
        // Only a new page size waits for the whole book; a text size's new
        // reading measure is a text setting and shows at once.
        let pagesWholeBook = newGeometry.pageSize != geometry.pageSize && !isReflowingBeforeShowing
        let (old, oldPalette) = (typography, palette)
        let keepsPages = newGeometry == geometry && newTypography.paginatesLike(old)
        let cached = keepsPages ? chapters.all : [:]
        let center = location.chapterIndex
        let reading = [center - 1, center, center + 1].filter(book.chapters.indices.contains)
        let (url, savedPages) = (documentURL, savedPages)
        let work = Task.detached(priority: .userInitiated) { () -> (seed: [Int: EPUBStyledChapter], source: PageSource)? in
            var seed: [Int: EPUBStyledChapter] = [:]
            if keepsPages {
                for (chapter, styled) in cached {
                    guard !Task.isCancelled else { return nil }
                    seed[chapter] = styled.recolored(from: oldPalette, to: newPalette)
                }
                return (seed, .kept)
            }
            let saved = savedPages(url, newTypography, newGeometry, book.chapters.count)
            let others = pagesWholeBook && saved == nil ? book.chapters.indices.filter { !reading.contains($0) } : []
            var pages: [Int: [NSRange]] = [:]
            for chapter in reading + others {
                guard !Task.isCancelled else { return nil }
                let styled = EPUBStyledChapter.make(book: book, chapter: chapter, typography: newTypography,
                                                    palette: newPalette, geometry: newGeometry)
                if reading.contains(chapter) { seed[chapter] = styled }
                if saved == nil { pages[chapter] = styled.pages(fitting: newGeometry.textSize) }
            }
            return (seed, saved.map(PageSource.saved) ?? .fresh(seeded: pages))
        }
        typographyTask = Task { [weak self] in
            let prepared = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, let prepared, !Task.isCancelled else { return }
            typography = newTypography
            palette = newPalette
            geometry = newGeometry
            layout = newLayout
            repaginate(prepared.source, seed: prepared.seed)
        }
    }

    // MARK: Zoom (PDF's steps and Zoom to Fit, plus Reflow to Fit)

    static let zoomRange = EPUBPageGeometry.scaleRange

    /// The scale the pages are drawn at: the reader's, or the fit's.
    private var currentScale: CGFloat { zoom.pageScale ?? fitScale ?? 1 }

    private var fitScale: CGFloat? {
        guard let viewport,
              [viewport.width, viewport.height, geometry.pageSize.width, geometry.pageSize.height]
                .allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let fit = EPUBPageGeometry.fitScale(pageSize: geometry.pageSize, viewport: viewport, layout: layout)
        return fit.isFinite && fit > 0 ? fit : nil
    }

    /// Scale eligibility is independent of fitted reading intent. The mounted
    /// stack publishes native gesture geometry without committing a zoom/reflow.
    var navigationRailFitsViewport: Bool {
        if let surface = readingSurface as? EPUBPageStackScrollView {
            return nativeRailFitsViewport?.owner == ObjectIdentifier(surface) && nativeRailFitsViewport?.fits == true
        }
        guard let fitScale, let scale = zoom.pageScale ?? self.fitScale,
              scale.isFinite, scale > 0 else { return false }
        return scale <= fitScale
    }

    /// A scale within 3% of the fit is the fit: a slight pinch, or zooming in
    /// and back out, returns to it rather than leaving the pages a hair off.
    private func isNearFit(_ scale: CGFloat) -> Bool {
        guard let fitScale else { return false }
        return abs(scale - fitScale) <= fitScale * 0.03
    }

    var canZoomIn: Bool { ZoomRange.pages.canStepIn(from: currentScale) }
    var canZoomOut: Bool { ZoomRange.pages.canStepOut(from: currentScale) }
    func zoomIn() { setZoom(ZoomRange.pages.steppedIn(from: currentScale)) }
    func zoomOut() { setZoom(ZoomRange.pages.steppedOut(from: currentScale)) }

    /// The pages take the window's size at 100% and the text re-flows to fill
    /// them; they follow the window as it resizes until the reader zooms or
    /// fits.
    func reflowToFit() {
        guard zoom != .reflow else { return }
        zoom = .reflow
        persistReadingPosition()
        reflowToViewport()
    }

    /// Scales the pages, at their size, to fit the window, and keeps them
    /// fitted as it resizes: the page row's width in the continuous layouts,
    /// the whole page or spread otherwise.
    func zoomToFit() {
        guard zoom != .fit else { return }
        zoom = .fit
        keepPageSize()
        persistReadingPosition()
    }

    /// While fitted (or reflowed, which fits), the rail hides, as PDF's does.
    var isFitted: Bool { zoom.pageScale == nil }

    /// Also reported by the surface after a pinch. A scale the pages are
    /// already drawn at changes nothing, so it never leaves Reflow to Fit.
    func setZoom(_ scale: CGFloat) {
        let clamped = min(max(scale, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        if isNearFit(clamped) {
            snapToFit()
            return
        }
        guard abs(clamped - currentScale) > 0.001 else { return }
        zoom = .scale(clamped)
        keepPageSize()
        persistReadingPosition()
    }

    private func snapToFit() {
        guard zoom.pageScale != nil else { return }
        zoom = fittedZoom
        persistReadingPosition()
        reflowToViewport()
    }

    /// Leaving Reflow to Fit: a reflow still pending or under way is dropped.
    private func keepPageSize() {
        reflowTask?.cancel()
        // Keeps the page's size, not text settings chosen a moment ago.
        let kept = measured(geometry)
        guard requestedGeometry != kept || requestedLayout != layout else { return }
        requestedGeometry = kept
        requestedLayout = layout
        relayout()
    }

    /// The reader view's size and the top chrome its continuous pages start
    /// below. While reflowing, a resize re-flows the pages once it settles
    /// (the pointer released); the first size lays the book out at once.
    ///
    /// A surface built anew (the tab left the warm set or moved window) may find
    /// the window has changed: `fromNewView` re-flows at once, and its pages stay
    /// off screen until that is done, from the reader's chapters as on opening.
    func viewportChanged(_ size: CGSize, topInset: CGFloat, fromNewView: Bool = false) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size != viewport || topInset != self.topInset else { return }
        let isFirst = viewport == nil
        viewport = size
        self.topInset = topInset
        reflowTask?.cancel()
        // A book saved a hair off the fit opens fitted.
        if isFirst, let scale = zoom.pageScale, isNearFit(scale) { snapToFit() }
        guard zoom == .reflow else { return }
        if isFirst {
            reflowToViewport()
            return
        }
        if fromNewView {
            reflowToViewport(beforeShowing: true)
            return
        }
        reflowTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            // A live resize is still under way while the pointer is down.
            while NSEvent.pressedMouseButtons != 0, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            self?.reflowToViewport()
        }
    }

    private func reflowToViewport(beforeShowing: Bool = false) {
        guard zoom == .reflow, let viewport else { return }
        let target = fittedGeometry(viewport, layout: requestedLayout)
        guard target != requestedGeometry else { return }
        requestedGeometry = target
        isReflowingBeforeShowing = beforeShowing
        persistReadingPosition()
        relayout()
    }

    /// What the chapters on screen couldn't show, for a spread's second page too.
    var currentNotices: [EPUBContentNotice] {
        var chaptersShown = [location.chapterIndex]
        chaptersShown += currentRow.pages.compactMap { pagination.page(at: $0)?.chapter }
        var notices: [EPUBContentNotice] = []
        for chapter in chaptersShown {
            for notice in chapters.peek(chapter)?.notices ?? [] where !notices.contains(notice) { notices.append(notice) }
        }
        return notices
    }

    /// What fell back on screen, in words; nil when nothing did.
    var currentNoticeMessage: String? { Self.noticeMessage(for: currentNotices) }

    /// One sentence for each thing that fell back, always in the same order.
    static func noticeMessage(for notices: [EPUBContentNotice]) -> String? {
        let message = EPUBContentNotice.allCases.filter(notices.contains).map(sentence(for:)).joined(separator: " ")
        return message.isEmpty ? nil : message
    }

    private static func sentence(for notice: EPUBContentNotice) -> String {
        switch notice {
        case .fixedLayoutFallback: "This fixed page is shown as flowing text."
        case .verticalWritingFallback: "Vertical text in this chapter is shown across the page."
        case .mathMLFallback: "Some formulas in this chapter are shown as text."
        case .audioUnavailable: "Audio in this chapter can’t play here."
        case .videoUnavailable: "Video in this chapter can’t play here."
        case .remoteResourceUnavailable: "Images and media online are blocked in this chapter."
        }
    }

    // MARK: - Bookmarks

    var isCurrentLocationBookmarked: Bool { bookmarkOnCurrentPage != nil }

    /// A bookmark belongs to the page that shows its offset.
    private var bookmarkOnCurrentPage: EPUBBookmark? {
        bookmarks.first {
            alignedToSpread(pagination.globalPage(chapter: $0.chapterIndex, offset: $0.characterOffset)) == currentPage
        }
    }

    func toggleBookmarkAtCurrentLocation() {
        recordBookmarkUndo(bookmarkOnCurrentPage == nil ? "Add Bookmark" : "Remove Bookmark")
        if let existing = bookmarkOnCurrentPage {
            bookmarks.removeAll { $0.id == existing.id }
        } else {
            addBookmark(at: location)
        }
        saveAnnotations()
    }

    /// The thumbnails' menu: any page, leaving the reader where they are.
    func toggleBookmark(onPage page: Int) {
        guard let shown = pagination.page(at: page) else { return }
        let existing = bookmarks.first { self.page(of: $0) == page }
        recordBookmarkUndo(existing == nil ? "Add Bookmark" : "Remove Bookmark")
        if let existing {
            bookmarks.removeAll { $0.id == existing.id }
        } else {
            addBookmark(at: EPUBLocation(chapterIndex: shown.chapter, characterOffset: shown.range?.location ?? 0))
        }
        saveAnnotations()
    }

    func isBookmarked(page: Int) -> Bool {
        bookmarks.contains { self.page(of: $0) == page }
    }

    private func addBookmark(at place: EPUBLocation) {
        bookmarks.append(EPUBBookmark(
            chapterIndex: place.chapterIndex,
            characterOffset: place.characterOffset,
            title: book?.chapters[safe: place.chapterIndex]?.title ?? "Bookmark",
            excerpt: excerpt(at: place)
        ))
        bookmarks.sort { ($0.chapterIndex, $0.characterOffset) < ($1.chapterIndex, $1.characterOffset) }
    }

    func renameBookmark(_ bookmark: EPUBBookmark, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }),
              bookmarks[index].title != trimmed else { return }
        recordBookmarkUndo("Rename Bookmark")
        bookmarks[index].title = trimmed
        saveAnnotations()
    }

    /// The page a bookmark is on, for the sidebar's page numbers.
    func page(of bookmark: EPUBBookmark) -> Int {
        pagination.globalPage(chapter: bookmark.chapterIndex, offset: bookmark.characterOffset)
    }

    func removeBookmark(_ bookmark: EPUBBookmark) {
        guard bookmarks.contains(where: { $0.id == bookmark.id }) else { return }
        recordBookmarkUndo("Remove Bookmark")
        bookmarks.removeAll { $0.id == bookmark.id }
        saveAnnotations()
    }

    /// Registers one Undo step that puts the bookmarks back as they are now.
    private func recordBookmarkUndo(_ name: String) {
        let before = bookmarks
        let manager = undo.manager
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: self) { content in
            content.recordBookmarkUndo(name)
            content.bookmarks = before
            content.saveAnnotations()
        }
        manager.setActionName(name)
        manager.endUndoGrouping()
    }

    // MARK: - Highlights

    /// The page a highlight starts on, for the sidebar's page numbers.
    func page(of highlight: EPUBHighlight) -> Int {
        pagination.globalPage(chapter: highlight.chapterIndex, offset: highlight.range.location)
    }

    /// A jump to a highlight the reader can come back from with Back.
    func jump(to highlight: EPUBHighlight) {
        jump(to: EPUBLocation(chapterIndex: highlight.chapterIndex, characterOffset: highlight.range.location))
    }

    /// A click on a note in the panel: its page, with Back to return, and the
    /// note selected, as a click on a PDF comment does.
    func goToNote(_ highlight: EPUBHighlight) {
        jump(to: highlight)
        highlights.selectNote(highlight.id)
    }

    /// Whether Add Note has somewhere to go: the selection, or the page in view.
    var canAddNote: Bool {
        if highlights.selection != nil { return highlights.canAnnotateSelection }
        return book != nil && firstWordOnCurrentPage != nil
    }

    /// Add Note: on the selection, or, as Add Comment does with none, on the
    /// page in view. A book's note needs words to sit on, so it takes the
    /// page's first, and a note already there opens.
    @discardableResult
    func addNote() -> UUID? {
        if highlights.selection == nil, let word = firstWordOnCurrentPage {
            return highlights.addNote(onWord: word)
        }
        return highlights.addNoteToSelection()
    }

    /// The current page's first word, or its first character when it has no
    /// words (a page that is all figure).
    private var firstWordOnCurrentPage: EPUBTextSelection? {
        guard let shown = pagination.page(at: currentPage), let page = shown.range, page.length > 0,
              let text = chapters.peek(shown.chapter)?.text, NSMaxRange(page) <= text.length else { return nil }
        let string = text.string as NSString
        let skipped = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FFFC}"))
        let first = string.rangeOfCharacter(from: skipped.inverted, options: [], range: page)
        guard first.location != NSNotFound else {
            return EPUBTextSelection(chapter: shown.chapter, range: NSRange(location: page.location, length: 1))
        }
        let end = min(text.nextWord(from: first.location, forward: true), NSMaxRange(page))
        return EPUBTextSelection(chapter: shown.chapter, range: NSRange(location: first.location, length: end - first.location))
    }

    /// A large selection's text, read from the book off the main thread.
    private func plainText(of selection: EPUBTextSelection) async -> String? {
        guard let book else { return nil }
        let (start, end) = (selection.start, selection.end)
        let parts = (start.chapter...end.chapter).filter { !pagination.isExcluded($0) }.map {
            (chapter: $0, lower: $0 == start.chapter ? start.offset : 0, upper: $0 == end.chapter ? end.offset : Int.max)
        }
        let task = Task.detached(priority: .userInitiated) { try book.plainText(of: parts) }
        return try? await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// The highlighted words on one line, at most 200 characters.
    private func excerpt(chapter: Int, range: NSRange) -> String {
        guard let text = chapters.styledNow(chapter)?.text.string as NSString?,
              NSMaxRange(range) <= text.length else { return "" }
        // Images are attachment characters; they have no words.
        let words = text.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.count > 200 ? String(words.prefix(200)) + "…" : words
    }

    private func excerpt(at location: EPUBLocation) -> String {
        guard let string = chapters.peek(location.chapterIndex)?.text.string else { return "" }
        let text = string as NSString
        guard location.characterOffset < text.length else { return "" }
        let raw = text.substring(with: NSRange(
            location: location.characterOffset,
            length: min(90, text.length - location.characterOffset)
        ))
        return raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func message(for error: Error) -> String {
        switch error {
        case EPUBError.invalidMimetype: return "This file is not an EPUB publication."
        case EPUBError.resourceLimit: return "This EPUB is too large to open safely."
        case EPUBError.unreadableArchive: return "The EPUB archive is damaged or unsupported."
        case EPUBError.drmProtected: return "This EPUB is protected by DRM and can’t be opened."
        default: return "PageFlow could not read this EPUB."
        }
    }

    // MARK: TabDocument
    func ownsAnnotationResponder(_ responder: NSResponder?) -> Bool {
        CommentTextView.owns(responder, owner: highlights)
    }


    var undoManager: UndoManager { undo.manager }
    var undoAvailability: UndoAvailability { undo.availability }
    var restoreBookmark: Data? {
        guard scopedAccess else { return nil }
        return try? documentURL.bookmarkData(options: .withSecurityScope)
    }
    var usesSecurityScopedAccess: Bool { scopedAccess }
    var hasContent: Bool { book != nil }
    var canReplaceWithoutPrompt: Bool { false }
    var canSave: Bool { false }
    /// A book has nothing of its own to save, but copies to a new file like a PDF.
    var canSaveAs: Bool { isReady }
    var isDirty: Bool { false }
    var documentTitle: String { book?.title ?? documentURL.deletingPathExtension().lastPathComponent }
    var needsSaveAs: Bool { false }
    var hasPendingWrites: Bool { false }

    func saveSync() -> Bool { false }
    func saveAsSync(to url: URL, isSecurityScoped: Bool) -> Bool { false }
    func finishPendingWrites() {}
    func finishPendingWritesInBackground() async {}
    func captureViewSnapshot() {
        prepareViewEviction()
        EPUBZoomPanel.close(for: self)
    }
    /// Readies a hidden tab's view to go. Its own zoom panel closed when it was
    /// hidden: the panel open now, if any, is over the tab being read.
    func prepareViewEviction() {
        activationLocation = location
        captureReadingPlace()
    }
    func restoreViewSnapshot() {
        // A warm tab still shows the reader's place, down to the scroll
        // offset within the page: re-navigating would snap to the page top.
        guard hasContent, location != activationLocation else { return }
        navigate(to: activationLocation)
    }
    func clearSearchSnapshot() { searchManager.clear() }

    /// Gives back styled chapters away from the reader and decoded images.
    /// The reader's own chapters stay, so showing the tab again never waits.
    func releaseHiddenCaches() {
        hasReleasedCaches = true
        refillTask?.cancel()
        chapters.releaseUnprotected()
        book?.releaseCaches()
    }

    /// On screen again after giving its caches back: the images around the
    /// reader decode ahead of drawing, which would otherwise decode them on the
    /// main thread, and the rest of the book fills back in, so a far scroll
    /// finds text rather than blank paper.
    func resumeReleasedCaches() {
        guard hasReleasedCaches else { return }
        hasReleasedCaches = false
        book?.resumeCaches()
        prefetchImagesNearReader()
        refillChapters()
    }

    /// Styles what a release dropped, nearest the reader first, while it fits:
    /// nearest wherever the reader is by then, so it follows a far scroll. A
    /// background pass still running fills what's ahead of it, so this follows
    /// it and takes only what it skipped.
    private func refillChapters() {
        guard let book else { return }
        let (pass, generation) = (paginationTask, paginationGeneration)
        let (typography, palette, geometry) = (typography, palette, geometry)
        let count = book.chapters.count
        refillTask = Task { [weak self] in
            await pass?.value
            while let self, !Task.isCancelled, paginationGeneration == generation, chapters.hasRoom,
                  let chapter = Self.nearestUnfilledChapter(to: location.chapterIndex, count: count,
                                                            isFilled: { self.chapters.peek($0) != nil || self.chapters.isStyling($0) }) {
                let text = await Task.detached(priority: .utility) {
                    EPUBStyledChapter.make(book: book, chapter: chapter, typography: typography,
                                           palette: palette, geometry: geometry)
                }.value
                guard !Task.isCancelled, paginationGeneration == generation else { return }
                // The reader may have asked for it meanwhile; past the budget, the fill is done.
                if chapters.peek(chapter) == nil {
                    guard chapters.fits(text) else { return }
                    chapters.admitIfRoom(text, for: chapter)
                }
            }
        }
    }

    func cleanup() {
        asideLifetime = nil
        closeAside()
        // A note left empty settles as Return would leave it, before it's saved.
        highlights.endEditing()
        readAloud.stop()
        EPUBZoomPanel.close(for: self)
        persistReadingPosition()
        loadingTask?.cancel()
        paginationTask?.cancel()
        refillTask?.cancel()
        navigationTask?.cancel()
        typographyTask?.cancel()
        reflowTask?.cancel()
        bookSearchTask?.cancel()
        chapterCostsTask?.cancel()
        // Work still in flight lands in a generation nobody reads.
        paginationGeneration &+= 1
        chapters.reset(book: nil, typography: typography, palette: palette, geometry: geometry)
        book?.closeFile()
        loadingTask = nil
        searchManager.clear()
        undoManager.removeAllActions()
        if scopedAccess {
            documentURL.stopAccessingSecurityScopedResource()
            scopedAccess = false
        }
    }

    /// Saves where and how the book is read. Its annotations are saved on
    /// their own, but an earlier build's copy in the reading state is kept
    /// there until the book has opened and moved it.
    func persistReadingPosition() {
        captureReadingPlace()
        stateStore.save(.epub(EPUBPersistedReaderState(
            chapterIndex: location.chapterIndex,
            characterOffset: location.characterOffset,
            layout: requestedLayout,
            typography: requestedTypography,
            bookmarks: legacyAnnotations.bookmarks,
            highlights: legacyAnnotations.highlights,
            zoom: zoom,
            pageSize: requestedGeometry.pageSize,
            place: readingPlace
        )), for: documentURL)
        saveAnnotations()
    }

    // MARK: - Save As

    /// What a tab showing this book is called: one still named for its file
    /// follows the file.
    func tabTitle(current: String, previousURL: URL?) -> String {
        current == previousURL?.deletingPathExtension().lastPathComponent
            ? documentURL.deletingPathExtension().lastPathComponent : documentTitle
    }

    /// This tab reads the copy now at `url`: the book follows it and the old
    /// file's access is given back. A book with no identifier is filed under
    /// its path, so its annotations are written under the new one; the reader's
    /// place and settings go with it too.
    func adoptSavedCopy(at url: URL, scopedAccess newAccess: Bool) {
        let (oldURL, oldAccess) = (documentURL, scopedAccess)
        book?.relocate(to: url)
        documentURL = url
        scopedAccess = newAccess
        if oldAccess { oldURL.stopAccessingSecurityScopedResource() }
        if let book {
            annotationKey = EPUBAnnotationStore.Key(identifier: book.identifier, url: url)
            savedAnnotations = nil
        }
        persistReadingPosition()
    }

    // MARK: - Annotations

    /// Reads the book's annotations under its identity. Highlights and
    /// bookmarks an earlier build kept in this file's reading state move
    /// over once, joining what another copy of the book already saved.
    private func restoreAnnotations(of book: EPUBBook) {
        let key = EPUBAnnotationStore.Key(identifier: book.identifier, url: documentURL)
        annotationKey = key
        let legacy = legacyAnnotations
        var restored = annotationStore.annotations(for: key) ?? EPUBAnnotations()
        let highlightIDs = Set(restored.highlights.map(\.id))
        let bookmarkIDs = Set(restored.bookmarks.map(\.id))
        restored.highlights += legacy.highlights.filter { !highlightIDs.contains($0.id) }
        restored.bookmarks += legacy.bookmarks.filter { !bookmarkIDs.contains($0.id) }
        restored.bookmarks.sort { ($0.chapterIndex, $0.characterOffset) < ($1.chapterIndex, $1.characterOffset) }
        bookmarks = restored.bookmarks
        highlights.loadSaved(restored.highlights)
        // A legacy set to fold in, or a path-keyed file to move, still needs a write.
        if legacy.isEmpty, restored.isEmpty || annotationStore.isFiled(under: key) {
            savedAnnotations = EPUBAnnotations(highlights: highlights.items, bookmarks: bookmarks)
        }
        guard !legacy.isEmpty else { return }
        legacyAnnotations = EPUBAnnotations()
        // Saved under the book first, then dropped from the reading state.
        persistReadingPosition()
    }

    /// Leaving a tab saves too, so an unchanged set skips the file write. A
    /// failed write stays unsaved, so the next save tries it again.
    private func saveAnnotations() {
        guard let annotationKey else { return }
        let annotations = EPUBAnnotations(highlights: highlights.items, bookmarks: bookmarks)
        guard annotations != savedAnnotations, annotationStore.save(annotations, for: annotationKey) else { return }
        savedAnnotations = annotations
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
