//
//  PDFManager.swift
//  PageFlow
//
//  Manages PDF document state, navigation, and operations
//

import Foundation
import AppKit
import PDFKit
import Observation
import os.log

enum InteractionMode {
    case select
    case pan
}

/// A one-shot request to fit the current page to the view, owned by `PDFManager`
/// and consumed by the projector once applied. Transient — this is *not* the
/// durable Auto-Scale mode (which hands sizing to PDFKit's `autoScales`).
struct FitRequest: Equatable {
    /// Scroll to the top of the page after fitting.
    var scrollToTop: Bool
}

enum DocumentLoadResult {
    case success
    case failed
    case needsPassword
}

enum PageMutation: Equatable {
    case inserted(at: Int)
    case deleted(at: Int)
    case moved(from: Int, to: Int)
}

struct PageThumbnailRevision: Equatable {
    let structureVersion: Int
    let pageVersion: Int
}

@Observable
@MainActor
final class PDFManager {
    // MARK: - Properties

    private let logger = Logger(subsystem: "com.pageflow", category: "PDFManager")

    typealias FileWriter = @Sendable (Data, URL) throws -> Void
    typealias WriteScheduler = @Sendable (@escaping @Sendable () -> Void) -> Void
    @ObservationIgnored private let fileSession: PDFFileSession
    @ObservationIgnored private let scheduleWrite: WriteScheduler

    init(
        fileWriter: @escaping FileWriter = { data, url in try data.write(to: url, options: .atomic) },
        scheduleWrite: @escaping WriteScheduler = { work in
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        },
        pageClipboard: PDFPageClipboard = .shared
    ) {
        self.fileSession = PDFFileSession(writer: fileWriter)
        self.scheduleWrite = scheduleWrite
        self.pageClipboard = pageClipboard
    }

    // Deferred native work belongs to the intent that admitted it. Increment
    // on every command, including equal-valued fit requests (the ABA case).
    @ObservationIgnored private(set) var viewIntentRevision: UInt64 = 0
    @ObservationIgnored private var isIngestingPageChange = false
    var document: PDFDocument? {
        didSet {
            viewIntentRevision &+= 1
            if oldValue !== document {
                suppressesNavigationRail = false
                navigationRailFitsViewport = false
                navigationRailPageRects = []
            }
        }
    }
    /// In-session reading intent, independent of the consumed fit request and scale.
    private(set) var suppressesNavigationRail = false
    /// Native fit and visible-paper clearance, independently of fitted intent.
    var navigationRailFitsViewport = false
    /// Current visible paper in window coordinates, measured by the native owner.
    var navigationRailPageRects: [NSRect] = []
    var currentPage: PDFPage? { didSet { if !isIngestingPageChange { viewIntentRevision &+= 1 } } }
    var currentPageIndex: Int = 0 { didSet { if !isIngestingPageChange { viewIntentRevision &+= 1 } } }
    var scaleFactor: CGFloat = 1.0 { didSet { viewIntentRevision &+= 1 } }
    var isAutoScaling: Bool = false { didSet { viewIntentRevision &+= 1 } }
    /// One-shot fit request consumed by the projector; nil when no fit is pending.
    var pendingFit: FitRequest? { didSet { viewIntentRevision &+= 1 } }
    /// One-shot exact-scroll restore (page + point) consumed by the projector to
    /// land the user where they left off; nil when none pending. Transient.
    @ObservationIgnored var pendingScrollRestore: PDFDestination? { didSet { viewIntentRevision &+= 1 } }
    /// One-shot "jump to" target (page + point) for explicit navigation such as
    /// clicking a comment in the sidebar. Observable — unlike `pendingScrollRestore`
    /// it must drive a projection pass even when the destination is on the page
    /// already showing; consumed and cleared by the projector.
    var pendingNavigation: PDFDestination? { didSet { viewIntentRevision &+= 1 } }
    /// Reads the live `PDFView`'s current destination for persistence. Set by the
    /// view coordinator while a live view is mounted; nil otherwise.
    @ObservationIgnored var liveDestinationProvider: (() -> PDFDestination?)?
    /// Identity of the coordinator that installed `liveDestinationProvider`, so a
    /// lazily-run dismantle of an old view can't clear a successor's provider.
    @ObservationIgnored var liveDestinationProviderOwner: ObjectIdentifier?
    /// The tab left its window, and its view there no longer speaks for it. Cleared by
    /// the view made in the next one.
    @ObservationIgnored private(set) var awaitsNewView = false
    @ObservationIgnored private var releasedView: (destination: (() -> PDFDestination?)?, owner: ObjectIdentifier?, selection: (() -> PDFSelection?)?)?
    /// Reads the live `PDFView`'s text selection. Set alongside `liveDestinationProvider`.
    @ObservationIgnored var liveSelectionProvider: (() -> PDFSelection?)?
    /// The text selected in a view torn down, selected again by the view that
    /// replaces it; nil when none pending. Transient.
    @ObservationIgnored var pendingSelectionRestore: PDFSelection?
    /// Source of restored reading positions. Defaults to the app-wide store;
    /// overridable in tests.
    @ObservationIgnored var documentStateStore: DocumentStateStore = .shared
    var documentURL: URL?
    var isDirty: Bool = false {
        didSet {
            if isDirty {
                editRevision &+= 1
                markdownExportJob.cancel()
            }
        }
    }
    @ObservationIgnored private let markdownExportJob = MarkdownExportJob()
    @ObservationIgnored private var editRevision: UInt64 = 0
    @ObservationIgnored private var documentEpoch: UInt64 = 0
    @ObservationIgnored private var savingDocumentID: ObjectIdentifier?
    @ObservationIgnored private var lastAppliedWrite: UInt64 = 0
    var closeRevision: UInt64 { editRevision }
    private var pendingWrites = 0
    var hasPendingWrites: Bool { pendingWrites > 0 }
    var usesSecurityScopedAccess: Bool { fileAccess?.isSecurityScoped == true }
    var interactionMode: InteractionMode = .select
    var displayMode: PDFDisplayMode = .singlePageContinuous { didSet { viewIntentRevision &+= 1 } }

    /// Increments whenever pages are added/removed/reordered - triggers UI refresh
    var pageVersion: Int = 0
    private(set) var pageStructureVersion: Int = 0
    private var thumbnailPageVersions: [Int: Int] = [:]
    @ObservationIgnored private var cachedOutlineRoot: PDFOutline?
    @ObservationIgnored private var cachedOutlineItems: [OutlineItem]?

    /// Copy/Cut/Paste Page go through the app-wide clipboard, so a page
    /// copied in one PDF pastes into another.
    let pageClipboard: PDFPageClipboard

    /// What the open document's security handler permits (see `PDFPermissions`).
    var permissions: PDFPermissions { PDFPermissions(document) }
    
    // Password-protected PDF state
    var pendingLockedDocument: PDFDocument?
    var pendingLockedURL: URL?
    private var pendingLockedPageIndex: Int?

    // Back/forward page history (pure value type; see NavigationHistory).
    private var navigationHistory = NavigationHistory()

    @ObservationIgnored private var fileAccess: PDFFileAccess?
    @ObservationIgnored private var pendingFileAccess: PDFFileAccess?

    var undoManagerProvider: (() -> UndoManager?)?
    var pageMutationHandler: ((PageMutation) -> Void)?

    func clearUndoHistory() {
        guard let undoManager = undoManagerProvider?() else { return }
        undoManager.removeAllActions()
        NotificationCenter.default.post(name: .NSUndoManagerCheckpoint, object: undoManager)
    }

    deinit {
        #if DEBUG
        Swift.print("[deinit] PDFManager")
        #endif
    }

    func getUndoManager(for action: String) -> UndoManager? {
        guard let undoManager = undoManagerProvider?() else {
            logger.error("UndoManager unavailable for action: \(action)")
            return nil
        }
        return undoManager
    }

    var pageCount: Int {
        document?.pageCount ?? 0
    }

    var hasDocument: Bool {
        document != nil
    }

    /// A security-scoped bookmark for the currently open document when it is held
    /// under a security scope (sandboxed open), or `nil` otherwise. The PDF peer of
    /// `MarkdownDocumentManager.securityScopedBookmark`, consumed by session restore (S8).
    /// A pure read of existing state — it does NOT change the load/close control
    /// flow. Non-scoped (Finder-opened / non-sandbox) documents return `nil` here;
    /// the capture path then mints one from the live document URL, else the path.
    var securityScopedBookmark: Data? {
        usesSecurityScopedAccess ? fileAccess?.bookmark : nil
    }

    /// Safe page accessor with bounds validation
    func page(at index: Int) -> PDFPage? {
        guard let document = document,
              index >= 0,
              index < document.pageCount else {
            return nil
        }
        return document.page(at: index)
    }

    func thumbnailRevision(for pageIndex: Int) -> PageThumbnailRevision {
        PageThumbnailRevision(
            structureVersion: pageStructureVersion,
            pageVersion: thumbnailPageVersions[pageIndex, default: 0]
        )
    }

    func markThumbnailDirty(at pageIndex: Int) {
        guard pageIndex >= 0 else { return }
        thumbnailPageVersions[pageIndex, default: 0] += 1
    }

    func markThumbnailDirty(for page: PDFPage) {
        guard let document else { return }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return }
        markThumbnailDirty(at: pageIndex)
    }

    /// Records a visible in-place edit to `page` (annotation/comment add, remove,
    /// recolor): marks the document dirty and invalidates the page's rendered
    /// artifacts (`pageVersion` for live views, the page's thumbnail). The single
    /// fan-in for the annotation managers' edit bookkeeping; structural page
    /// changes go through `markThumbnailStructureDirty` instead.
    func noteVisibleEdit(on page: PDFPage?) {
        isDirty = true
        pageVersion += 1
        if let page { markThumbnailDirty(for: page) }
    }

    func markThumbnailStructureDirty() {
        pageStructureVersion += 1
        thumbnailPageVersions.removeAll()
        invalidateOutlineCache()
    }

    private func invalidateOutlineCache() {
        cachedOutlineRoot = nil
        cachedOutlineItems = nil
    }

    var documentTitle: String {
        guard let document = document else {
            return "PageFlow"
        }

        if let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
           !title.isEmpty {
            return title
        }

        return documentURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    var canGoBack: Bool {
        navigationHistory.canGoBack
    }

    var canGoForward: Bool {
        navigationHistory.canGoForward
    }

    // MARK: - Navigation History

    /// Push current position to history before navigating (call before goToPage for link/outline navigation)
    func pushNavigationState() {
        navigationHistory.push(currentPageIndex)
    }

    func goBack() {
        guard let target = navigationHistory.stepBack(from: currentPageIndex) else { return }
        goToPageWithoutHistory(target)
    }

    func goForward() {
        guard let target = navigationHistory.stepForward(from: currentPageIndex) else { return }
        goToPageWithoutHistory(target)
    }

    /// Navigate to page without affecting history (used by goBack/goForward)
    private func goToPageWithoutHistory(_ index: Int) {
        guard let document = document,
              index >= 0,
              index < document.pageCount else {
            return
        }

        let page = document.page(at: index)
        guard currentPageIndex != index || currentPage !== page else { return }
        currentPageIndex = index
        currentPage = page
    }

    func clearNavigationHistory() {
        navigationHistory.clear()
    }

    func copyMarkdown(scope: ExportScope, comments: [CommentModel] = []) {
        guard document != nil, permissions.copy else { return }
        let clipboard = MarkdownClipboard.shared
        let request = clipboard.beginRequest()
        exportMarkdown(scope: scope, comments: comments) {
            clipboard.copy($0, for: request)
        }
    }

    /// Admit a conversion against this exact source revision; closing, loading,
    /// editing or submitting another export cancels any older request.
    func exportMarkdown(scope: ExportScope, comments: [CommentModel] = [], completion: @escaping (String) -> Void) {
        guard let document, permissions.copy else { return }
        let epoch = documentEpoch
        let revision = editRevision
        markdownExportJob.start(scope: scope, document: document, comments: comments, isCurrent: { [weak self, weak document] in
            guard let self, let document else { return false }
            return self.document === document && self.documentEpoch == epoch && self.editRevision == revision
        }, completion: completion)
    }

    // MARK: - Document Loading

    func loadDocument(from url: URL, isSecurityScoped: Bool = false) -> DocumentLoadResult {
        guard url.pathExtension.lowercased() == "pdf" else {
            return .failed
        }

        discardPendingLockedDocument()

        let access = PDFFileAccess(url: url, requestSecurityScope: isSecurityScoped)
        guard !isSecurityScoped || access.isSecurityScoped else { return .failed }
        // Complete accepted writes before reading, including reload of the same file.
        finishPendingWrites()
        guard let pdfDocument = PDFDocument(url: url) else { return .failed }

        // Check if document is locked (password-protected)
        if pdfDocument.isLocked {
            pendingLockedDocument = pdfDocument
            pendingLockedURL = url
            pendingFileAccess = access
            return .needsPassword
        }

        finalizeDocumentLoad(
            pdfDocument,
            url: url,
            access: access
        )
        return .success
    }

    func unlockDocument(password: String) -> Bool {
        guard let pdfDocument = pendingLockedDocument,
              let url = pendingLockedURL else {
            return false
        }

        guard pdfDocument.unlock(withPassword: password) else {
            return false
        }

        let linkedPageIndex = pendingLockedPageIndex
        finishPendingWrites()
        finalizeDocumentLoad(pdfDocument, url: url,
                             access: pendingFileAccess ?? PDFFileAccess(url: url))
        resetPendingLockedDocument()
        if let linkedPageIndex { followPageLink(linkedPageIndex, for: url) }
        return true
    }

    func cancelPendingUnlock() {
        discardPendingLockedDocument()
    }

    private func resetPendingLockedDocument() {
        pendingLockedDocument = nil
        pendingLockedURL = nil
        pendingLockedPageIndex = nil
        pendingFileAccess = nil
    }

    private func discardPendingLockedDocument() {
        resetPendingLockedDocument()
    }

    private func finalizeDocumentLoad(_ pdfDocument: PDFDocument, url: URL, access: PDFFileAccess) {
        markdownExportJob.cancel()
        clearUndoHistory()
        clearNavigationHistory()
        documentEpoch &+= 1
        document = pdfDocument
        documentURL = url
        fileAccess = access
        savingDocumentID = ObjectIdentifier(pdfDocument)
        fileSession.reset(access: access)
        applyInitialViewState(for: pdfDocument, url: url)
        isDirty = false
        markThumbnailStructureDirty()
    }

    func closeDocument() {
        suppressesNavigationRail = false
        markdownExportJob.cancel()
        finishPendingWrites()
        documentEpoch &+= 1
        savingDocumentID = nil
        fileSession.reset(access: nil)
        fileAccess = nil
        clearUndoHistory()
        discardPendingLockedDocument()
        clearNavigationHistory()

        document = nil
        documentURL = nil
        currentPage = nil
        currentPageIndex = 0
        scaleFactor = 1.0
        isDirty = false
        pendingScrollRestore = nil
        pendingSelectionRestore = nil
        pendingNavigation = nil
        markThumbnailStructureDirty()
    }

    // MARK: - Reading-Position Persistence

    /// Restores the saved reading state for `url` if present and still valid,
    /// otherwise falls back to the first page, fitted with Auto-Scale. The single
    /// place document-load view state is initialized.
    private func applyInitialViewState(for document: PDFDocument, url: URL) {
        let saved = documentStateStore.state(for: url)
        // The display mode is the document's, like an EPUB's layout; a document
        // without one opens in the default mode rather than the previous one's.
        displayMode = saved?.pdfDisplayMode.flatMap(PDFDisplayMode.init(rawValue:)) ?? .singlePageContinuous
        if let saved,
           saved.pageIndex >= 0, saved.pageIndex < document.pageCount,
           let page = document.page(at: saved.pageIndex) {
            currentPageIndex = saved.pageIndex
            currentPage = page
            isAutoScaling = saved.isAutoScaling
            suppressesNavigationRail = saved.isAutoScaling
            scaleFactor = ZoomRange.pages.clamp(saved.scaleFactor)
            pendingFit = nil
            pendingScrollRestore = saved.scrollPoint.map { PDFDestination(page: page, at: $0) }
        } else {
            // A document without a usable saved state opens as Zoom to Fit
            // leaves it: Auto-Scale stays on through window resizes until the
            // reader zooms. PDFKit owns the scale; this value is the 100%
            // baseline until its first scale notification.
            currentPageIndex = 0
            currentPage = document.page(at: 0)
            scaleFactor = DesignTokens.pdfDefaultScale
            pendingScrollRestore = nil
            setAutoScaling(true)
        }
    }

    /// Snapshots the current reading state for persistence and arms an in-session
    /// exact-scroll restore (so returning to this tab lands at the same point).
    /// Returns nil when no document is loaded.
    func captureViewState() -> DocumentViewState? {
        guard let document, documentURL != nil else { return nil }

        // A restore still waiting is where the reader is: the view hasn't got there.
        let destination = pendingScrollRestore ?? liveDestinationProvider?()
        if destination != nil { pendingScrollRestore = destination }

        let pageIndex: Int
        if let page = destination?.page {
            let index = document.index(for: page)
            pageIndex = index == NSNotFound ? currentPageIndex : index
        } else {
            pageIndex = currentPageIndex
        }

        return DocumentViewState(
            pageIndex: pageIndex,
            scaleFactor: scaleFactor,
            isAutoScaling: isAutoScaling,
            scrollPoint: destination?.point,
            pdfDisplayMode: displayMode.rawValue
        )
    }

    /// Readies the live view to be torn down: its replacement lands at the
    /// same place with the same text selected.
    func prepareViewEviction() {
        _ = captureViewState()
        if let liveSelectionProvider { pendingSelectionRestore = liveSelectionProvider() }
    }

    /// The tab is leaving its window, its place already captured. Its view there still
    /// lives a while, and goes on reporting: a restore it took isn't left for the view
    /// that replaces it, and the page PDFKit names as it comes down would become the
    /// reader's.
    func releaseViewForTransfer() {
        navigationRailFitsViewport = false
        navigationRailPageRects = []
        if let liveSelectionProvider { pendingSelectionRestore = liveSelectionProvider() }
        // A move straight back finds this already released, and has nothing newer to keep.
        if liveDestinationProviderOwner != nil {
            releasedView = (liveDestinationProvider, liveDestinationProviderOwner, liveSelectionProvider)
        }
        liveDestinationProvider = nil
        liveDestinationProviderOwner = nil
        liveSelectionProvider = nil
        awaitsNewView = true
    }

    /// The move didn't happen: its window couldn't be made and the tab came straight
    /// back, within the turn, so SwiftUI keeps the view it had. No new one will come to
    /// clear the release, and the old view would stay frozen, deaf to the reader.
    func reclaimReleasedView() {
        guard awaitsNewView, let releasedView else { return }
        liveDestinationProvider = releasedView.destination
        liveDestinationProviderOwner = releasedView.owner
        liveSelectionProvider = releasedView.selection
        self.releasedView = nil
        pendingSelectionRestore = nil
        awaitsNewView = false
    }

    /// A new view took over the document.
    func noteNewView() {
        awaitsNewView = false
        releasedView = nil
    }

    // MARK: - Navigation

    func goToPage(_ index: Int) {
        guard let document = document,
              index >= 0,
              index < document.pageCount else {
            return
        }

        let page = document.page(at: index)
        guard currentPageIndex != index || currentPage !== page else { return }
        // The reader moved: a restore still waiting would only pull them back.
        pendingScrollRestore = nil
        currentPageIndex = index
        currentPage = page
    }

    func nextPage() {
        let nextIndex = currentPageIndex + 1
        guard nextIndex < pageCount else { return }
        goToPage(nextIndex)
    }

    func previousPage() {
        let previousIndex = currentPageIndex - 1
        guard previousIndex >= 0 else { return }
        goToPage(previousIndex)
    }

    /// Records leaving the page in view for `target`, by `BackRule`.
    func recordJump(toPage target: Int) {
        if BackRule.records(from: currentPageIndex, to: target) { pushNavigationState() }
    }

    func recordJump(to page: PDFPage) {
        guard let index = document?.index(for: page), index != NSNotFound else { return }
        recordJump(toPage: index)
    }

    /// A jump Back returns from.
    func jump(toPage index: Int) {
        guard let document, index >= 0, index < document.pageCount else { return }
        recordJump(toPage: index)
        goToPage(index)
    }

    func goToFirstPage() {
        jump(toPage: 0)
    }

    func goToLastPage() {
        guard pageCount > 0 else { return }
        jump(toPage: pageCount - 1)
    }

    /// A linked page belongs to this exact document, including a pending unlock.
    /// The pending target travels with the PDF manager through a window transfer.
    func followPageLink(_ pageIndex: Int, for url: URL) {
        guard pageIndex >= 0 else { return }
        let target = url.pageFlowCanonicalDocumentURL
        if pendingLockedURL?.pageFlowCanonicalDocumentURL == target {
            pendingLockedPageIndex = pageIndex
            return
        }
        guard documentURL?.pageFlowCanonicalDocumentURL == target,
              let document, pageIndex < document.pageCount,
              let page = document.page(at: pageIndex) else { return }
        let bounds = page.bounds(for: .mediaBox)
        goToDestination(PDFDestination(page: page, at: CGPoint(x: bounds.minX, y: bounds.maxY)))
    }

    /// Jump to an explicit destination (a point on a page) — e.g. bringing a
    /// clicked comment into view rather than just its page top. Records history
    /// (so Back returns) only when the page actually changes. `pendingNavigation`
    /// is observable, so the projector also runs when the destination is on the
    /// page already showing.
    func goToDestination(_ destination: PDFDestination) {
        guard let document, let page = destination.page else { return }
        let index = document.index(for: page)
        guard index != NSNotFound else { return }
        recordJump(toPage: index)
        goToPageWithoutHistory(index)
        // An explicit jump supersedes any still-pending reading-position
        // restore — otherwise the restore's settle retry can land after this
        // navigation and yank the view away from the target.
        pendingScrollRestore = nil
        pendingNavigation = destination
    }

    // MARK: - Zoom

    // Multiplicative steps, as Markdown zooms: each press changes the size by
    // the same proportion at any scale.
    func zoomIn() {
        beginManualZoom()
        scaleFactor = ZoomRange.pages.steppedIn(from: scaleFactor)
    }

    func zoomOut() {
        beginManualZoom()
        scaleFactor = ZoomRange.pages.steppedOut(from: scaleFactor)
    }

    /// The zoom commands disable at the limits, so a press always does something.
    var canZoomIn: Bool { hasDocument && ZoomRange.pages.canStepIn(from: scaleFactor) }
    var canZoomOut: Bool { hasDocument && ZoomRange.pages.canStepOut(from: scaleFactor) }
    /// Already at 100% and not fitted, Actual Size has nothing to do.
    var canResetZoom: Bool {
        hasDocument && (isAutoScaling || !ZoomRange.pages.isActualSize(scaleFactor))
    }

    func resetZoom() {
        beginManualZoom()
        scaleFactor = DesignTokens.pdfDefaultScale
    }

    func setZoom(_ scale: CGFloat) {
        beginManualZoom()
        restoreZoom(scale)
    }

    /// A restored scale is projection state, not a new manual-zoom command.
    func restoreZoom(_ scale: CGFloat) {
        scaleFactor = ZoomRange.pages.clamp(scale)
    }

    /// Begins a manual command, including native input accepted by the view.
    func beginManualZoom() {
        suppressesNavigationRail = false
        isAutoScaling = false
        pendingFit = nil
    }

    func setAutoScaling(_ enabled: Bool) {
        suppressesNavigationRail = enabled
        isAutoScaling = enabled
        pendingFit = nil
    }

    /// Zoom to Fit: hands sizing to Auto-Scale, so the page stays fitted as
    /// the window resizes until the reader zooms (the EPUB fit model).
    func zoomToFit() {
        setAutoScaling(true)
    }

    func requestFitOnce() {
        suppressesNavigationRail = true
        isAutoScaling = false
        pendingFit = FitRequest(scrollToTop: false)
    }

    // MARK: - View Event Ingest
    //
    // The projector's notification adapters call these to fold user-originated
    // PDFView changes back into the manager (the source of truth). They are no-ops
    // when the value already matches, so a projector write that echoes back as a
    // PDFKit notification resolves to nothing.

    /// PDFKit reported the visible page changed (user scroll, link, etc.).
    func ingestPageChange(index: Int, page: PDFPage) {
        // A native reflow can change the visible spread while a mode fit is
        // pending. It reports the projection, rather than issuing a new command.
        isIngestingPageChange = true
        defer { isIngestingPageChange = false }
        if currentPageIndex != index { currentPageIndex = index }
        if currentPage !== page { currentPage = page }
    }

    /// PDFKit reported the scale changed (user pinch / control-scroll / internal).
    func ingestScaleChange(_ scale: CGFloat) {
        if scaleFactor != scale { scaleFactor = scale }
    }

    /// A completed fit is fitted reading even when initiated by display reflow.
    func ingestFitCompletion(scale: CGFloat) {
        suppressesNavigationRail = true
        scaleFactor = scale
    }

    /// PDFKit reported the display mode changed (e.g. via its own context menu).
    func ingestDisplayModeChange(_ mode: PDFDisplayMode) {
        if displayMode != mode { displayMode = mode }
    }

    func rotateClockwise() {
        rotatePage(at: currentPageIndex, clockwise: true)
    }

    func rotateCounterClockwise() {
        rotatePage(at: currentPageIndex, clockwise: false)
    }

    /// Rotates page at specified index - used by both toolbar and thumbnail context menu
    func rotatePage(at index: Int, clockwise: Bool) {
        guard permissions.editPages, let document = document,
              index >= 0, index < document.pageCount,
              let page = document.page(at: index) else { return }

        let delta = clockwise ? 90 : -90
        let oldRotation = page.rotation
        let newRotation = (oldRotation + delta + 360) % 360
        page.rotation = newRotation
        isDirty = true
        pageVersion += 1
        markThumbnailDirty(at: index)

        if let undoManager = getUndoManager(for: "Rotate Page") {
            undoManager.registerUndo(withTarget: self) { target in
                target.rotatePage(at: index, clockwise: !clockwise)
            }
            undoManager.setActionName("Rotate Page")
        }
    }

    // MARK: - Page Operations

    /// Whether a page is available to paste, from this or another PDF
    var canPaste: Bool { pageClipboard.hasPage }

    /// Copies the page at the given index for later paste. Returns false when
    /// nothing was copied (no permission, no such page, or it couldn't be written).
    @discardableResult
    func copyPage(at index: Int) -> Bool {
        guard permissions.copy, let page = document?.page(at: index) else { return false }
        return pageClipboard.copy(page)
    }

    /// Cuts the page at the given index (copy + delete)
    func cutPage(at index: Int) {
        // Cut is copy then delete: a page that was not copied is not removed either.
        guard permissions.editPages, permissions.copy, let document = document, document.pageCount > 1,
              copyPage(at: index) else { return }
        deletePage(at: index)
    }

    /// Pastes the copied page after the given index
    /// Returns true if paste succeeded
    func pastePage(after index: Int) -> Bool {
        guard permissions.editPages, page(at: index) != nil,
              let page = pageClipboard.makePage() else { return false }
        return insertPages([page], at: index + 1, actionName: "Paste Page")
    }

    func deletePage(at index: Int) {
        guard permissions.editPages, let document = document,
              document.pageCount > 1,
              index >= 0, index < document.pageCount,
              let page = document.page(at: index) else { return }

        document.removePage(at: index)
        isDirty = true

        currentPageIndex = PageIndexMath.afterDeletion(current: currentPageIndex, deletedIndex: index, newPageCount: document.pageCount)
        currentPage = document.page(at: currentPageIndex)
        pageVersion += 1
        markThumbnailStructureDirty()
        pageMutationHandler?(.deleted(at: index))

        if let undoManager = getUndoManager(for: "Delete Page") {
            undoManager.registerUndo(withTarget: self) { target in
                target.insertPageForUndo(page, at: index)
            }
            undoManager.setActionName("Delete Page")
        }
    }

    func duplicatePage(at index: Int) {
        guard permissions.editPages, let document = document,
              let page = document.page(at: index),
              let pageCopy = page.copy() as? PDFPage else { return }

        let insertIndex = index + 1
        document.insert(pageCopy, at: insertIndex)
        isDirty = true

        currentPageIndex = PageIndexMath.afterInsertion(current: currentPageIndex, insertedIndex: insertIndex)
        currentPage = document.page(at: currentPageIndex)
        pageVersion += 1
        markThumbnailStructureDirty()
        pageMutationHandler?(.inserted(at: insertIndex))

        if let undoManager = getUndoManager(for: "Duplicate Page") {
            undoManager.registerUndo(withTarget: self) { target in
                target.removePageForUndo(at: insertIndex)
            }
            undoManager.setActionName("Duplicate Page")
        }
    }

    func movePage(from sourceIndex: Int, to destinationIndex: Int) {
        guard permissions.editPages, let document = document,
              sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < document.pageCount,
              destinationIndex >= 0, destinationIndex < document.pageCount,
              let page = document.page(at: sourceIndex) else { return }

        document.removePage(at: sourceIndex)
        document.insert(page, at: destinationIndex)
        isDirty = true
        pageVersion += 1
        markThumbnailStructureDirty()

        // Update current page index if affected
        currentPageIndex = PageIndexMath.afterMove(current: currentPageIndex, from: sourceIndex, to: destinationIndex)
        currentPage = document.page(at: currentPageIndex)
        pageMutationHandler?(.moved(from: sourceIndex, to: destinationIndex))

        if let undoManager = getUndoManager(for: "Reorder Page") {
            undoManager.registerUndo(withTarget: self) { target in
                target.movePage(from: destinationIndex, to: sourceIndex)
            }
            undoManager.setActionName("Reorder Page")
        }
    }

    // MARK: - Page Operation Helpers (for undo/redo)

    private func insertPageForUndo(_ page: PDFPage, at index: Int) {
        guard permissions.editPages, let document = document,
              index >= 0, index <= document.pageCount else { return }

        document.insert(page, at: index)
        isDirty = true
        pageVersion += 1
        markThumbnailStructureDirty()
        currentPageIndex = index
        currentPage = document.page(at: index)
        pageMutationHandler?(.inserted(at: index))

        if let undoManager = getUndoManager(for: "Delete Page") {
            undoManager.registerUndo(withTarget: self) { target in
                target.deletePage(at: index)
            }
            undoManager.setActionName("Delete Page")
        }
    }

    private func removePageForUndo(at index: Int) {
        guard permissions.editPages, let document = document,
              document.pageCount > 1,
              let page = document.page(at: index) else { return }

        document.removePage(at: index)
        isDirty = true
        currentPageIndex = PageIndexMath.afterDeletion(current: currentPageIndex, deletedIndex: index, newPageCount: document.pageCount)
        currentPage = document.page(at: currentPageIndex)
        pageVersion += 1
        markThumbnailStructureDirty()
        pageMutationHandler?(.deleted(at: index))

        if let undoManager = getUndoManager(for: "Duplicate Page") {
            undoManager.registerUndo(withTarget: self) { target in
                target.insertPageForUndo(page, at: index)
            }
            undoManager.setActionName("Duplicate Page")
        }
    }

    // MARK: - Outline

    func outlineItems() -> [OutlineItem] {
        guard let root = document?.outlineRoot else { return [] }
        if cachedOutlineRoot === root, let cachedOutlineItems {
            return cachedOutlineItems
        }

        let items = OutlineItem.buildRoot(from: root)
        cachedOutlineRoot = root
        cachedOutlineItems = items
        return items
    }

    /// The page of the first outline entry a link's `#heading` names, matched as
    /// a note's headings are.
    func pageIndex(ofHeading fragment: String) -> Int? {
        func flattened(_ items: [OutlineItem]) -> [OutlineItem] {
            items.flatMap { [$0] + flattened($0.children ?? []) }
        }
        let entries = flattened(outlineItems()).filter { $0.pageIndex != nil }
        return HeadingSlug.firstIndex(of: fragment, in: entries.map(\.title)).flatMap { entries[$0].pageIndex }
    }

    // MARK: - Save

    struct SaveCompletion {
        let didWrite: Bool
        fileprivate let epoch: UInt64
        fileprivate let documentID: ObjectIdentifier?
        fileprivate let sequence: UInt64
    }

    /// Evaluate at delivery time: the tab may have loaded another PDF since await.
    func acceptsSaveCompletion(_ completion: SaveCompletion) -> Bool {
        document != nil && completion.epoch == documentEpoch &&
            completion.documentID == document.map(ObjectIdentifier.init)
    }

    func isCurrentSaveCompletion(_ completion: SaveCompletion) -> Bool {
        acceptsSaveCompletion(completion) && completion.sequence >= lastAppliedWrite
    }

    func save() async -> Bool { await saveWithCompletion().didWrite }

    func saveWithCompletion() async -> SaveCompletion {
        await performAsyncWrite(target: .current)
    }

    func saveAs(to url: URL) async -> Bool { await saveAsWithCompletion(to: url).didWrite }

    func saveAsWithCompletion(to url: URL, isSecurityScoped: Bool = false) async -> SaveCompletion {
        await performAsyncWrite(target: .saveAs(PDFFileAccess(url: url, requestSecurityScope: isSecurityScoped)))
    }

    /// PDFKit never leaves MainActor. The file session receives only a snapshot.
    private func performAsyncWrite(target: PDFFileSession.Target) async -> SaveCompletion {
        prepareSavingIdentity()
        let epoch = documentEpoch
        let identity = savingDocumentID
        guard let data = document?.dataRepresentation() else {
            return SaveCompletion(didWrite: false, epoch: epoch, documentID: identity, sequence: lastAppliedWrite)
        }
        let ticket = fileSession.admit(data: data, target: target, epoch: epoch, revision: editRevision)
        pendingWrites += 1
        defer { pendingWrites -= 1 }
        let session = fileSession
        scheduleWrite { _ = session.drain(through: ticket.sequence) }
        let outcome = await ticket.value()
        applySaved(outcome.saved)
        return SaveCompletion(didWrite: outcome.didWrite, epoch: epoch, documentID: identity, sequence: ticket.sequence)
    }

    /// Modal save claims older admitted work before writing the latest snapshot.
    func saveSync() -> Bool {
        prepareSavingIdentity()
        guard let data = document?.dataRepresentation() else { return false }
        let ticket = fileSession.admit(data: data, target: .current, epoch: documentEpoch, revision: editRevision)
        applySaved(fileSession.drain(through: ticket.sequence))
        return ticket.completed?.didWrite == true
    }

    // Direct document assignment is used by document construction as well as
    // tests. Treat a different PDF object as an identity boundary too.
    private func prepareSavingIdentity() {
        let identity = document.map(ObjectIdentifier.init)
        guard savingDocumentID != identity else { return }
        finishPendingWrites()
        documentEpoch &+= 1
        savingDocumentID = identity
        if fileAccess?.url != documentURL { fileAccess = documentURL.map { PDFFileAccess(url: $0) } }
        fileSession.reset(access: fileAccess)
    }

    func finishPendingWrites() { applySaved(fileSession.drain()) }

    /// Native close/quit await physical I/O without blocking the UI actor.
    func finishPendingWritesInBackground() async {
        let session = fileSession
        let saved = await Task.detached(priority: .userInitiated) { session.drain() }.value
        applySaved(saved)
    }

    private func applySaved(_ saved: PDFFileSession.Saved?) {
        guard let saved, saved.epoch == documentEpoch, saved.sequence > lastAppliedWrite,
              savingDocumentID == document.map(ObjectIdentifier.init) else { return }
        lastAppliedWrite = saved.sequence
        fileAccess = saved.access
        documentURL = saved.access.url
        if saved.revision == editRevision { isDirty = false }
    }
}
