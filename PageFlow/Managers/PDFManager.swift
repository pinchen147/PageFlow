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
    /// Scroll to the top of the page after fitting (used on document load).
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

    var document: PDFDocument?
    var currentPage: PDFPage?
    var currentPageIndex: Int = 0
    var scaleFactor: CGFloat = 1.0
    var isAutoScaling: Bool = false
    /// One-shot fit request consumed by the projector; nil when no fit is pending.
    var pendingFit: FitRequest?
    /// One-shot exact-scroll restore (page + point) consumed by the projector to
    /// land the user where they left off; nil when none pending. Transient.
    @ObservationIgnored var pendingScrollRestore: PDFDestination?
    /// One-shot "jump to" target (page + point) for explicit navigation such as
    /// clicking a comment in the sidebar. Observable — unlike `pendingScrollRestore`
    /// it must drive a projection pass even when the destination is on the page
    /// already showing; consumed and cleared by the projector.
    var pendingNavigation: PDFDestination?
    /// Reads the live `PDFView`'s current destination for persistence. Set by the
    /// view coordinator while a live view is mounted; nil otherwise.
    @ObservationIgnored var liveDestinationProvider: (() -> PDFDestination?)?
    /// Identity of the coordinator that installed `liveDestinationProvider`, so a
    /// lazily-run dismantle of an old view can't clear a successor's provider.
    @ObservationIgnored var liveDestinationProviderOwner: ObjectIdentifier?
    /// Source of restored reading positions. Defaults to the app-wide store;
    /// overridable in tests.
    @ObservationIgnored var documentStateStore: DocumentStateStore = .shared
    var documentURL: URL?
    var isDirty: Bool = false
    var interactionMode: InteractionMode = .select
    var displayMode: PDFDisplayMode = .singlePageContinuous

    /// Increments whenever pages are added/removed/reordered - triggers UI refresh
    var pageVersion: Int = 0
    private var thumbnailStructureVersion: Int = 0
    private var thumbnailPageVersions: [Int: Int] = [:]
    @ObservationIgnored private var cachedOutlineRoot: PDFOutline?
    @ObservationIgnored private var cachedOutlineItems: [OutlineItem]?

    /// Copied page for paste operation (same-document only)
    private(set) var copiedPage: PDFPage?
    
    // Password-protected PDF state
    var pendingLockedDocument: PDFDocument?
    var pendingLockedURL: URL?
    var pendingIsSecurityScoped: Bool = false

    // Back/forward page history (pure value type; see NavigationHistory).
    private var navigationHistory = NavigationHistory()

    private var isAccessingSecurityScopedResource = false
    @ObservationIgnored private var securityScopedURL: URL?

    var undoManagerProvider: (() -> UndoManager?)?
    var pageMutationHandler: ((PageMutation) -> Void)?

    func clearUndoHistory() {
        guard let undoManager = undoManagerProvider?() else { return }
        undoManager.removeAllActions()
        NotificationCenter.default.post(name: .NSUndoManagerCheckpoint, object: undoManager)
    }

    deinit {
        if let url = securityScopedURL {
            url.stopAccessingSecurityScopedResource()
        }
        #if DEBUG
        Swift.print("[deinit] PDFManager")
        #endif
    }

    private func getUndoManager(for action: String) -> UndoManager? {
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
            structureVersion: thumbnailStructureVersion,
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

    private func markThumbnailStructureDirty() {
        thumbnailStructureVersion += 1
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

    // MARK: - Document Loading

    func loadDocument(from url: URL, isSecurityScoped: Bool = false) -> DocumentLoadResult {
        guard url.pathExtension.lowercased() == "pdf" else {
            return .failed
        }

        discardPendingLockedDocument()

        let startedSecurityScopedAccess: Bool
        if isSecurityScoped {
            guard url.startAccessingSecurityScopedResource() else {
                return .failed
            }
            startedSecurityScopedAccess = true
        } else {
            startedSecurityScopedAccess = false
        }

        guard let pdfDocument = PDFDocument(url: url) else {
            if startedSecurityScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
            return .failed
        }

        // Check if document is locked (password-protected)
        if pdfDocument.isLocked {
            pendingLockedDocument = pdfDocument
            pendingLockedURL = url
            pendingIsSecurityScoped = startedSecurityScopedAccess
            return .needsPassword
        }

        finalizeDocumentLoad(
            pdfDocument,
            url: url,
            securityScopedURL: startedSecurityScopedAccess ? url : nil
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

        finalizeDocumentLoad(
            pdfDocument,
            url: url,
            securityScopedURL: pendingIsSecurityScoped ? url : nil
        )
        resetPendingLockedDocument()
        return true
    }

    func cancelPendingUnlock() {
        discardPendingLockedDocument()
    }

    private func resetPendingLockedDocument() {
        pendingLockedDocument = nil
        pendingLockedURL = nil
        pendingIsSecurityScoped = false
    }

    private func discardPendingLockedDocument() {
        if pendingIsSecurityScoped, let url = pendingLockedURL {
            url.stopAccessingSecurityScopedResource()

            if securityScopedURL == url {
                isAccessingSecurityScopedResource = false
                securityScopedURL = nil
            }
        }

        resetPendingLockedDocument()
    }

    private func finalizeDocumentLoad(_ pdfDocument: PDFDocument, url: URL, securityScopedURL: URL?) {
        // Clear previous document's undo actions to prevent stale references
        clearUndoHistory()
        clearNavigationHistory()
        stopAccessingCurrentResource()

        document = pdfDocument
        documentURL = url
        applyInitialViewState(for: pdfDocument, url: url)
        isDirty = false
        copiedPage = nil  // Clear to prevent cross-document paste corruption
        isAccessingSecurityScopedResource = securityScopedURL != nil
        self.securityScopedURL = securityScopedURL
        markThumbnailStructureDirty()
    }

    private func stopAccessingCurrentResource() {
        if isAccessingSecurityScopedResource, let oldURL = documentURL {
            oldURL.stopAccessingSecurityScopedResource()
            isAccessingSecurityScopedResource = false
            securityScopedURL = nil
        }
    }

    func closeDocument() {
        clearUndoHistory()
        discardPendingLockedDocument()
        clearNavigationHistory()

        if isAccessingSecurityScopedResource, let url = documentURL {
            url.stopAccessingSecurityScopedResource()
            isAccessingSecurityScopedResource = false
            securityScopedURL = nil
        }

        document = nil
        documentURL = nil
        currentPage = nil
        currentPageIndex = 0
        scaleFactor = 1.0
        isDirty = false
        copiedPage = nil
        pendingScrollRestore = nil
        pendingNavigation = nil
        markThumbnailStructureDirty()
    }

    // MARK: - Reading-Position Persistence

    /// Restores the saved reading state for `url` if present and still valid,
    /// otherwise falls back to first-page, fit-to-width defaults. The single
    /// place document-load view state is initialized.
    private func applyInitialViewState(for document: PDFDocument, url: URL) {
        if let saved = documentStateStore.state(for: url),
           saved.pageIndex >= 0, saved.pageIndex < document.pageCount,
           let page = document.page(at: saved.pageIndex) {
            currentPageIndex = saved.pageIndex
            currentPage = page
            isAutoScaling = saved.isAutoScaling
            scaleFactor = min(max(saved.scaleFactor, DesignTokens.pdfMinScale), DesignTokens.pdfMaxScale)
            pendingFit = nil
            pendingScrollRestore = saved.scrollPoint.map { PDFDestination(page: page, at: $0) }
        } else {
            currentPageIndex = 0
            currentPage = document.page(at: 0)
            isAutoScaling = false
            scaleFactor = DesignTokens.pdfDefaultScale
            pendingFit = FitRequest(scrollToTop: true)
            pendingScrollRestore = nil
        }
    }

    /// Snapshots the current reading state for persistence and arms an in-session
    /// exact-scroll restore (so returning to this tab lands at the same point).
    /// Returns nil when no document is loaded.
    func captureViewState() -> DocumentViewState? {
        guard let document, documentURL != nil else { return nil }

        let destination = liveDestinationProvider?()
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
            scrollPoint: destination?.point
        )
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

    func goToFirstPage() {
        goToPage(0)
    }

    func goToLastPage() {
        guard pageCount > 0 else { return }
        goToPage(pageCount - 1)
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
        if currentPageIndex != index || currentPage !== page {
            pushNavigationState()
            goToPageWithoutHistory(index)
        }
        // An explicit jump supersedes any still-pending reading-position
        // restore — otherwise the restore's settle retry can land after this
        // navigation and yank the view away from the target.
        pendingScrollRestore = nil
        pendingNavigation = destination
    }

    // MARK: - Zoom

    func zoomIn() {
        isAutoScaling = false
        pendingFit = nil
        scaleFactor = min(scaleFactor + DesignTokens.pdfZoomStep, DesignTokens.pdfMaxScale)
    }

    func zoomOut() {
        isAutoScaling = false
        pendingFit = nil
        scaleFactor = max(scaleFactor - DesignTokens.pdfZoomStep, DesignTokens.pdfMinScale)
    }

    func resetZoom() {
        isAutoScaling = false
        pendingFit = nil
        scaleFactor = DesignTokens.pdfDefaultScale
    }

    func setZoom(_ scale: CGFloat) {
        isAutoScaling = false
        pendingFit = nil
        scaleFactor = max(DesignTokens.pdfMinScale, min(scale, DesignTokens.pdfMaxScale))
    }

    func toggleAutoScale() {
        isAutoScaling.toggle()
        pendingFit = nil
    }

    func requestFitOnce() {
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
        if currentPageIndex != index { currentPageIndex = index }
        if currentPage !== page { currentPage = page }
    }

    /// PDFKit reported the scale changed (user pinch / control-scroll / internal).
    func ingestScaleChange(_ scale: CGFloat) {
        if scaleFactor != scale { scaleFactor = scale }
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
        guard let document = document,
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

    /// Whether a page is available to paste
    var canPaste: Bool { copiedPage != nil }

    /// Copies the page at the given index for later paste
    func copyPage(at index: Int) {
        guard let page = document?.page(at: index),
              let pageCopy = page.copy() as? PDFPage else { return }
        copiedPage = pageCopy
    }

    /// Cuts the page at the given index (copy + delete)
    func cutPage(at index: Int) {
        guard let document = document, document.pageCount > 1 else { return }
        copyPage(at: index)
        deletePage(at: index)
    }

    /// Pastes the copied page after the given index
    /// Returns true if paste succeeded
    func pastePage(after index: Int) -> Bool {
        guard let page = copiedPage,
              let document = document,
              index >= 0, index < document.pageCount else { return false }

        let insertIndex = index + 1
        let pageCountBefore = document.pageCount

        document.insert(page, at: insertIndex)

        // Validate insert succeeded (PDFKit doesn't report failures)
        guard document.pageCount == pageCountBefore + 1 else { return false }

        // Create new copy for future pastes (page can only be in doc once)
        guard let newCopy = page.copy() as? PDFPage else {
            // Rollback: remove the inserted page if copy fails
            document.removePage(at: insertIndex)
            return false
        }
        copiedPage = newCopy

        isDirty = true
        currentPageIndex = insertIndex
        currentPage = document.page(at: insertIndex)
        pageVersion += 1
        markThumbnailStructureDirty()
        pageMutationHandler?(.inserted(at: insertIndex))

        if let undoManager = getUndoManager(for: "Paste Page") {
            undoManager.registerUndo(withTarget: self) { target in
                target.deletePage(at: insertIndex)
            }
            undoManager.setActionName("Paste Page")
        }

        return true
    }

    func deletePage(at index: Int) {
        guard let document = document,
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
        guard let document = document,
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
        guard let document = document,
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
        guard let document = document,
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
        guard let document = document,
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

    // MARK: - Save

    /// Async save - use for normal save operations to prevent UI freeze
    func save() async -> Bool {
        guard let targetURL = documentURL,
              let data = document?.dataRepresentation() else {
            return false
        }

        let log = logger

        // File I/O on background thread. Serialization stays on MainActor to avoid PDFKit races.
        let result = await Task.detached(priority: .userInitiated) {
            do {
                try data.write(to: targetURL, options: .atomic)
                return true
            } catch {
                log.error("Save failed: \(error.localizedDescription)")
                return false
            }
        }.value

        // Update state on main thread
        if result {
            isDirty = false
        }

        return result
    }

    /// Synchronous save - use only for quit-time saves where we can't await
    func saveSync() -> Bool {
        guard let document = document,
              let url = documentURL else {
            return false
        }

        guard let data = document.dataRepresentation() else {
            return false
        }

        do {
            try data.write(to: url, options: .atomic)
            isDirty = false
            return true
        } catch {
            logger.error("Sync save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Async save as - use for Save As operations
    func saveAs(to url: URL) async -> Bool {
        guard let data = document?.dataRepresentation() else {
            return false
        }

        let targetURL = url
        let log = logger

        // File I/O on background thread. Serialization stays on MainActor to avoid PDFKit races.
        let result = await Task.detached(priority: .userInitiated) {
            do {
                try data.write(to: targetURL, options: .atomic)
                return true
            } catch {
                log.error("Save As failed: \(error.localizedDescription)")
                return false
            }
        }.value

        // Update state on main thread
        if result {
            stopAccessingCurrentResource()
            documentURL = url
            isDirty = false
        }

        return result
    }

}
