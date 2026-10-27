//
//  PDFViewWrapper.swift
//  PageFlow
//
//  SwiftUI wrapper for PDFKit's PDFView using StablePDFView for resize stability.
//

import SwiftUI
import PDFKit
import AppKit

fileprivate struct SearchHighlightSignature: Equatable {
    let documentID: ObjectIdentifier?
    let selectionIDs: [ObjectIdentifier]
    let currentResultIndex: Int

    init(pdfView: PDFView, searchManager: SearchManager) {
        documentID = pdfView.document.map { ObjectIdentifier($0) }
        selectionIDs = searchManager.searchResults.map { ObjectIdentifier($0) }
        currentResultIndex = searchManager.currentResultIndex
    }
}

struct PDFViewWrapper: NSViewRepresentable {
    @Bindable var pdfManager: PDFManager
    var searchManager: SearchManager
    @Bindable var annotationManager: AnnotationManager
    @Bindable var commentManager: CommentManager
    @Bindable var bookmarkManager: BookmarkManager
    var tabUndoManager: UndoManager
    var isActive: Bool
    var isDisplayed: Bool
    var onRequestFocus: () -> Void = {}

    func makeNSView(context: Context) -> PDFViewHost {
        let pdfView = StablePDFView()
        configureInitialState(pdfView, context: context)
        configureAnnotationCallbacks(pdfView, context: context)
        configureZoomCallbacks(pdfView, context: context)
        configureContextMenuCallbacks(pdfView)
        configureManagers(pdfView, context: context)
        configureNotificationObservers(pdfView, context: context)
        return PDFViewHost(pdfView: pdfView)
    }

    // MARK: - makeNSView Helpers

    private func configureInitialState(_ pdfView: StablePDFView, context: Context) {
        pdfView.wantsLayer = true
        pdfView.layer?.isOpaque = true
        pdfView.layer?.backgroundColor = DesignTokens.viewerBackground.cgColor
        pdfView.backgroundColor = DesignTokens.viewerBackground
        pdfView.displaysPageBreaks = true
        pdfView.displayMode = pdfManager.displayMode
        pdfView.displayDirection = .vertical
        pdfView.autoScales = false
        pdfView.minScaleFactor = DesignTokens.pdfMinScale
        pdfView.maxScaleFactor = DesignTokens.pdfMaxScale
        pdfView.scaleFactor = pdfManager.scaleFactor
        // Crisp resampling for the settled view; control-scroll zoom temporarily
        // drops this to .low per frame and restores it on settle (see Coordinator).
        pdfView.interpolationQuality = .high
        if #unavailable(macOS 15.0) {
            pdfView.enableDataDetectors = true
        }
        pdfView.delegate = context.coordinator
    }

    private func configureAnnotationCallbacks(_ pdfView: StablePDFView, context: Context) {
        pdfView.onAnnotationClick = { [weak commentManager, weak annotationManager] annotation in
            guard let commentManager = commentManager,
                  let annotationManager = annotationManager else { return }

            if !commentManager.selectAnnotation(annotation) {
                annotationManager.selectedAnnotation = annotation
            }
        }

        pdfView.onAnnotationDeselect = { [weak annotationManager] in
            annotationManager?.selectedAnnotation = nil
        }

        pdfView.onAnnotationRemove = { [weak pdfView, weak annotationManager, weak commentManager] annotation in
            // Route through the appropriate manager's undo system
            if let commentManager = commentManager,
               let uuid = commentManager.commentID(for: annotation) {
                commentManager.deleteComment(uuid)
            } else {
                annotationManager?.removeAnnotation(annotation)
            }

            pdfView?.needsDisplay = true
            pdfView?.layoutDocumentView()
        }

        pdfView.onAnnotationColorChange = { [weak pdfView, weak annotationManager] annotation, color in
            let previousSelection = annotationManager?.selectedAnnotation
            annotationManager?.selectedAnnotation = annotation
            annotationManager?.updateSelectedAnnotationColor(color)
            annotationManager?.selectedAnnotation = previousSelection

            pdfView?.needsDisplay = true
            pdfView?.layoutDocumentView()
        }

        pdfView.onCommentColorChange = { [weak pdfView, weak commentManager] annotation, color in
            if let commentManager = commentManager,
               let uuid = commentManager.commentID(for: annotation) {
                commentManager.updateCommentColor(uuid, color: color)
            }

            pdfView?.needsDisplay = true
            pdfView?.layoutDocumentView()
        }
    }

    private func configureZoomCallbacks(_ pdfView: StablePDFView, context: Context) {
        pdfView.onRequestFocus = onRequestFocus
        context.coordinator.configureUserZoom(on: pdfView)

        pdfView.onControlScroll = { [weak pdfView, weak coordinator = context.coordinator] event in
            guard let pdfView = pdfView,
                  let coordinator = coordinator else { return false }
            return coordinator.processControlScroll(event: event, pdfView: pdfView)
        }

        pdfView.onLinkNavigation = { [weak pdfManager] in
            pdfManager?.pushNavigationState()
        }
    }

    private func configureContextMenuCallbacks(_ pdfView: StablePDFView) {
        pdfView.onCopyPageAsMarkdown = { [weak pdfManager, weak commentManager] in
            guard let pdfManager else { return }
            pdfManager.copyMarkdown(scope: .currentPage(pdfManager.currentPageIndex), comments: commentManager?.comments ?? [])
        }

        pdfView.onCopyDocumentAsMarkdown = { [weak pdfManager, weak commentManager] in
            pdfManager?.copyMarkdown(scope: .entireDocument, comments: commentManager?.comments ?? [])
        }

        pdfView.onToggleBookmark = { [weak pdfManager, weak bookmarkManager] in
            guard let pdfManager = pdfManager,
                  let bookmarkManager = bookmarkManager else { return }
            bookmarkManager.toggleBookmark(at: pdfManager.currentPageIndex)
        }
    }

    private func configureManagers(_ pdfView: StablePDFView, context: Context) {
        let tabUndoManager = self.tabUndoManager
        let undoManagerProvider: () -> UndoManager? = {
            tabUndoManager
        }

        pdfManager.undoManagerProvider = undoManagerProvider

        // Lets persistence read the live scroll position (page + point) on demand.
        pdfManager.liveDestinationProvider = { [weak pdfView] in pdfView?.currentDestination }
        pdfManager.liveDestinationProviderOwner = ObjectIdentifier(context.coordinator)

        annotationManager.configure(
            pdfManager: pdfManager,
            selectionProvider: { [weak pdfView] in
                guard let pdfView = pdfView,
                      let selection = pdfView.currentSelection else { return (nil, nil) }
                let page = selection.pages.first ?? pdfView.currentPage
                return (selection, page)
            },
            undoManagerProvider: undoManagerProvider
        )

        commentManager.configure(
            pdfManager: pdfManager,
            selectionProvider: { [weak pdfView] in
                guard let pdfView = pdfView else { return (nil, nil) }
                if let selection = pdfView.currentSelection {
                    let page = selection.pages.first ?? pdfView.currentPage
                    return (selection, page)
                }
                return (nil, pdfView.currentPage)
            },
            undoManagerProvider: undoManagerProvider
        )

        bookmarkManager.configure(
            pdfManager: pdfManager,
            undoManagerProvider: undoManagerProvider
        )
    }

    private func configureNotificationObservers(_ pdfView: StablePDFView, context: Context) {
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scaleChanged(_:)),
            name: .PDFViewScaleChanged,
            object: pdfView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.displayModeChanged(_:)),
            name: .PDFViewDisplayModeChanged,
            object: pdfView
        )

        // The window-wide scroll-zoom and right-click monitors are installed by
        // `setActive` in updateNSView, so kept-warm inactive tabs hold none — only
        // the active tab does. (PDFKit notification observers above are scoped to
        // this pdfView object, so they stay regardless.)
    }

    func updateNSView(_ hostView: PDFViewHost, context: Context) {
        // Gate native input now and defer AppKit hiding until this update
        // finishes, so key-view traversal cannot re-enter SwiftUI focus layout.
        hostView.setContentActive(isDisplayed)

        let pdfView = hostView.pdfView
        pdfView.onRequestFocus = onRequestFocus
        let coordinator = context.coordinator
        coordinator.setActive(isFocused: isActive, isDisplayed: isDisplayed, pdfView: pdfView)

        // Structural: load/replace the document and its markup.
        let documentDidChange = pdfView.document !== pdfManager.document
        if documentDidChange {
            pdfView.document = pdfManager.document
            annotationManager.resetSelection()
            if let document = pdfManager.document {
                commentManager.loadComments(from: document)
            } else {
                commentManager.clearComments()
            }
        }

        // Single writer: reconcile the live view to the manager's desired state.
        coordinator.project(pdfView, documentDidChange: documentDidChange)

        updateSearchHighlights(pdfView, context: context)
    }

    private func updateSearchHighlights(_ pdfView: StablePDFView, context: Context) {
        let coord = context.coordinator

        if searchManager.hasResults {
            let highlightSignature = SearchHighlightSignature(pdfView: pdfView, searchManager: searchManager)
            if coord.lastAppliedSearchHighlightSignature != highlightSignature {
                pdfView.highlightedSelections = searchManager.highlightedSelections(
                    currentColor: DesignTokens.searchCurrentResult,
                    othersColor: DesignTokens.searchOtherResults
                )
                coord.lastAppliedSearchHighlightSignature = highlightSignature
                coord.searchHighlightsAreClear = false
            }

            let resultIndex = searchManager.currentResultIndex
            let resultCount = searchManager.searchResults.count
            if let currentSelection = searchManager.currentSelection(),
               resultIndex != coord.lastNavigatedSearchIndex || resultCount != coord.lastSearchResultCount {
                coord.lastNavigatedSearchIndex = resultIndex
                coord.lastSearchResultCount = resultCount
                coord.invalidateDeferredProjection()
                pdfView.go(to: currentSelection)
                pdfView.setCurrentSelection(currentSelection, animate: true)
            }
        } else {
            context.coordinator.lastNavigatedSearchIndex = -1
            context.coordinator.lastSearchResultCount = 0
            context.coordinator.lastAppliedSearchHighlightSignature = nil

            if !context.coordinator.searchHighlightsAreClear {
                pdfView.highlightedSelections = nil
                pdfView.setCurrentSelection(nil, animate: false)
                context.coordinator.searchHighlightsAreClear = true
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            pdfManager: pdfManager,
            annotationManager: annotationManager,
            commentManager: commentManager,
            isActive: isActive
        )
    }

    static func dismantleNSView(_ hostView: PDFViewHost, coordinator: Coordinator) {
        let pdfView = hostView.pdfView
        coordinator.invalidateDeferredProjection(dismantled: true)
        NotificationCenter.default.removeObserver(
            coordinator,
            name: .PDFViewPageChanged,
            object: pdfView
        )
        NotificationCenter.default.removeObserver(
            coordinator,
            name: .PDFViewScaleChanged,
            object: pdfView
        )
        NotificationCenter.default.removeObserver(
            coordinator,
            name: .PDFViewDisplayModeChanged,
            object: pdfView
        )
        coordinator.removeScrollMonitor()
        pdfView.removeRightClickMonitor()

        // Clear all callbacks to prevent any lingering references
        pdfView.onAnnotationClick = nil
        pdfView.onAnnotationDeselect = nil
        pdfView.onAnnotationRemove = nil
        pdfView.onAnnotationColorChange = nil
        pdfView.onCommentColorChange = nil
        pdfView.onControlScroll = nil
        pdfView.onUserZoom = nil
        pdfView.onLinkNavigation = nil
        pdfView.onCopyPageAsMarkdown = nil
        pdfView.onCopyDocumentAsMarkdown = nil
        pdfView.onToggleBookmark = nil
        pdfView.onRequestFocus = nil

        // The live view is gone; persistence must fall back to manager state.
        // Guarded by owner: after a cross-window tab move the destination's
        // makeNSView may have installed its provider before this (lazily run)
        // dismantle — clearing unconditionally would blind persistence for the
        // tab's new window.
        if coordinator.pdfManager.liveDestinationProviderOwner == ObjectIdentifier(coordinator) {
            coordinator.pdfManager.liveDestinationProvider = nil
            coordinator.pdfManager.liveDestinationProviderOwner = nil
        }
    }

    // MARK: - Private

    /// Relative-tolerance scale comparison. PDFKit re-rounds `scaleFactor` during
    /// layout, so an exact `!=` would churn; only a change beyond 0.5% is treated
    /// as meaningful by the projector and by scale-change ingestion.
    static func scalesDiffer(_ a: CGFloat, _ b: CGFloat) -> Bool {
        abs(a - b) / max(abs(b), 0.0001) > 0.005
    }

    /// Gathers live geometry from the view and delegates to the pure `FitEngine`.
    /// The view-touching part (reading bounds + page media box) stays here; the
    /// formula itself lives in `FitEngine` so it can be unit-tested in isolation.
    private static func calculateFitScale(for pdfView: PDFView, page: PDFPage) -> CGFloat {
        let viewBounds = pdfView.bounds
        let pageBounds = page.bounds(for: .mediaBox)
        let inputs = FitEngine.FitInputs(
            viewWidth: viewBounds.width,
            viewHeight: viewBounds.height,
            pageWidth: pageBounds.width,
            pageHeight: pageBounds.height,
            displayMode: pdfView.displayMode,
            padding: DesignTokens.pdfViewPadding,
            twoPageGap: DesignTokens.pdfTwoPageGap
        )
        return FitEngine.scale(for: inputs)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, PDFViewDelegate {
        let pdfManager: PDFManager
        let annotationManager: AnnotationManager
        let commentManager: CommentManager
        var isActive: Bool = true
        private var scrollMonitor: Any?
        /// True only while `project(_:documentDidChange:)` is writing the live view,
        /// so a PDFKit notification posted synchronously by our own write defers its
        /// ingest instead of mutating @Observable state during a SwiftUI view update.
        private var isProjecting = false
        /// Bumped each time `scrollTo` applies a destination, so a superseding scroll
        /// invalidates an earlier one's pending settle-reapply (prevents a stale
        /// delayed go(to:) from yanking the user back after they navigate away).
        private var scrollApplyToken = 0
        var lastNavigatedSearchIndex: Int = -1
        var lastSearchResultCount: Int = 0
        fileprivate var lastAppliedSearchHighlightSignature: SearchHighlightSignature?
        var searchHighlightsAreClear = true
        private var zoomQualityRestore: DispatchWorkItem?
        private var deferredProjectionGeneration: UInt64 = 0
        private var isDismantled = false

        private struct DeferredProjection {
            let generation: UInt64
            let intentRevision: UInt64
            let documentID: ObjectIdentifier?
        }

        func invalidateDeferredProjection(dismantled: Bool = false) {
            deferredProjectionGeneration &+= 1
            isDismantled = isDismantled || dismantled
            scrollApplyToken &+= 1
        }

        private func deferredProjection(for pdfView: PDFView) -> DeferredProjection {
            DeferredProjection(
                generation: deferredProjectionGeneration,
                intentRevision: pdfManager.viewIntentRevision,
                documentID: pdfView.document.map(ObjectIdentifier.init)
            )
        }

        private func accepts(_ work: DeferredProjection, from pdfView: PDFView, requiresDisplayed: Bool = true) -> Bool {
            !isDismantled && (!requiresDisplayed || lastDisplayed != false)
                && work.generation == deferredProjectionGeneration
                && work.intentRevision == pdfManager.viewIntentRevision
                && work.documentID == pdfView.document.map(ObjectIdentifier.init)
                && pdfView.document === pdfManager.document
                && (pdfManager.liveDestinationProviderOwner == nil
                    || pdfManager.liveDestinationProviderOwner == ObjectIdentifier(self))
        }

        init(pdfManager: PDFManager, annotationManager: AnnotationManager, commentManager: CommentManager, isActive: Bool) {
            self.pdfManager = pdfManager
            self.annotationManager = annotationManager
            self.commentManager = commentManager
            self.isActive = isActive
            super.init()
        }

        deinit {
            // Backstop teardown. SwiftUI does not guarantee `dismantleNSView` runs
            // promptly (or at all) before the coordinator is released, so we also
            // release here: drop the PDFKit notification observers and the window-wide
            // scroll-wheel monitor. Without this they outlive the view and keep firing
            // for the life of the window. Idempotent with `dismantleNSView`.
            NotificationCenter.default.removeObserver(self)
            removeScrollMonitor()
        }

        /// Reconciles event monitors and keyboard focus along two axes:
        /// - Monitors (scroll-zoom, right-click) track **visibility**: the on-screen
        ///   view keeps its own, routing to itself via its own hit-test. Hidden warm
        ///   tabs install none (the long-session accumulation guard).
        /// - First responder tracks **focus**: the focused, on-screen view takes the
        ///   keyboard (so tab switching gives arrows to it without a click). Both run
        ///   only on genuine transitions.
        ///
        /// The warm stack displays only the active tab, so today `isDisplayed ==
        /// isFocused`: the active tab installs monitors + takes focus; a hidden warm
        /// tab does neither and hands focus back.
        private var lastDisplayed: Bool?
        private var lastFocused: Bool?

        func setActive(isFocused: Bool, isDisplayed: Bool, pdfView: StablePDFView) {
            isActive = isFocused

            if lastDisplayed != isDisplayed {
                invalidateDeferredProjection()
                lastDisplayed = isDisplayed
                if isDisplayed {
                    setupScrollMonitor(for: pdfView)
                    pdfView.setupRightClickMonitor()
                } else {
                    removeScrollMonitor()
                    pdfView.removeRightClickMonitor()
                    // A pane going hidden hands the keyboard back if it still holds it.
                    DispatchQueue.main.async { [weak pdfView] in
                        guard let pdfView, let window = pdfView.window,
                              let responder = window.firstResponder as? NSView,
                              responder === pdfView || responder.isDescendant(of: pdfView) else { return }
                        window.makeFirstResponder(nil)
                    }
                }
            }

            if lastFocused != isFocused {
                lastFocused = isFocused
                // Deferred a turn — responder changes inside a SwiftUI update re-enter AppKit.
                if isFocused, isDisplayed {
                    DispatchQueue.main.async { [weak pdfView] in
                        guard let pdfView, let window = pdfView.window,
                              !pdfView.isHiddenOrHasHiddenAncestor else { return }
                        window.makeFirstResponder(pdfView)
                    }
                }
            }
        }

        func setupScrollMonitor(for pdfView: StablePDFView) {
            guard scrollMonitor == nil else { return }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self, weak pdfView] event in
                guard let self = self,
                      let pdfView = pdfView,
                      let eventWindow = event.window,
                      eventWindow === pdfView.window else {
                    return event
                }

                return self.handleZoomScroll(event: event, pdfView: pdfView)
            }
        }

        private func handleZoomScroll(event: NSEvent, pdfView: StablePDFView) -> NSEvent? {
            if event.type == .magnify {
                _ = processMagnification(event: event, pdfView: pdfView)
                return event
            }
            let handled = processControlScroll(event: event, pdfView: pdfView)
            return handled ? nil : event
        }

        // MARK: Projection (manager -> live view; the only writer)

        /// Reconciles the live `PDFView` to the manager's desired state. This is the
        /// only place that writes page / scale / display mode / autoScales. Order
        /// matters: display mode first (PDFKit reflows on it), then page, then the
        /// single sizing owner — Auto-Scale *or* an explicit scale/fit, never both.
        func project(_ pdfView: StablePDFView, documentDidChange: Bool) {
            isProjecting = true
            defer { isProjecting = false }

            applyDisplayMode(pdfManager.displayMode, to: pdfView)

            if pdfView.interactionMode != pdfManager.interactionMode {
                pdfView.interactionMode = pdfManager.interactionMode
            }

            if let page = pdfManager.currentPage,
               documentDidChange || pdfView.currentPage !== page {
                // Durable page navigation supersedes any in-flight settle
                // re-apply (comment jump / position restore): bump the token so
                // a stale delayed go(to:) can't yank the view back.
                scrollApplyToken += 1
                pdfView.go(to: page)
            }

            if pdfManager.isAutoScaling {
                // Auto-Scale mode: PDFKit owns sizing; never write scaleFactor.
                if !pdfView.autoScales { pdfView.autoScales = true }
                if let destination = pdfManager.pendingScrollRestore {
                    restoreScrollPosition(destination, on: pdfView, retryCount: 0)
                }
            } else {
                if pdfView.autoScales { pdfView.autoScales = false }
                if let request = pdfManager.pendingFit {
                    performFit(on: pdfView, request: request, retryCount: 0)
                } else {
                    applyScale(pdfManager.scaleFactor, to: pdfView)
                    if let destination = pdfManager.pendingScrollRestore {
                        // Land the user back where they left off (page + scroll point).
                        restoreScrollPosition(destination, on: pdfView, retryCount: 0)
                    } else if documentDidChange {
                        scheduleCenterContent(in: pdfView, scrollToTop: true)
                    }
                }
            }

            // Explicit jump-to (e.g. clicking a comment): scroll to the target
            // point once page/scale have settled. `pendingNavigation` is observable,
            // so this also runs when the destination is on the page already showing.
            if let destination = pdfManager.pendingNavigation {
                scrollTo(destination, on: pdfView, retryCount: 0, oneShot: \.pendingNavigation)
            }
        }

        /// Writes `targetScale` to the view only when it meaningfully differs.
        private func applyScale(_ targetScale: CGFloat, to pdfView: PDFView) {
            guard PDFViewWrapper.scalesDiffer(targetScale, pdfView.scaleFactor) else { return }
            pdfView.scaleFactor = targetScale
        }

        /// Applies a display-mode change to the view and re-fits for the new geometry.
        private func applyDisplayMode(_ mode: PDFDisplayMode, to pdfView: StablePDFView) {
            guard pdfView.displayMode != mode else { return }
            pdfView.displayMode = mode
            scheduleFitForDisplayModeChange(on: pdfView)
        }

        // MARK: Ingest (live view -> manager)

        /// Runs `work` now when safe, or on the next runloop turn if a projector
        /// write is in flight (so we never mutate @Observable state mid view-update).
        private func ingestOrDefer(from pdfView: PDFView, _ work: @escaping () -> Void) {
            let state = deferredProjection(for: pdfView)
            let ingest = { [weak self, weak pdfView] in
                guard let self, let pdfView, self.accepts(state, from: pdfView, requiresDisplayed: false) else { return }
                work()
            }
            if isProjecting { DispatchQueue.main.async(execute: ingest) }
            else { ingest() }
        }

        func configureUserZoom(on pdfView: StablePDFView) {
            pdfView.onUserZoom = { [weak self, weak pdfView] intent in
                guard let self, let pdfView, self.ownsUserInput(in: pdfView) else { return false }
                switch intent {
                case .manual: self.pdfManager.beginManualZoom()
                case .autoScaling(let enabled): self.pdfManager.setAutoScaling(enabled)
                }
                return true
            }
        }

        private func ownsUserInput(in pdfView: PDFView) -> Bool {
            !isDismantled && !isProjecting && lastDisplayed != false
                && pdfView.document != nil && pdfView.document === pdfManager.document
                && (pdfManager.liveDestinationProviderOwner == nil
                    || pdfManager.liveDestinationProviderOwner == ObjectIdentifier(self))
        }

        func processMagnification(event: NSEvent, pdfView: StablePDFView) -> Bool {
            guard ownsUserInput(in: pdfView), event.type == .magnify else { return false }
            return pdfView.beginUserMagnification(with: event)
        }

        func processControlScroll(event: NSEvent, pdfView: StablePDFView) -> Bool {
            // Input follows the pointer's actual native hit, independently of focus.
            guard ownsUserInput(in: pdfView),
                  event.modifierFlags.contains(.control), event.scrollingDeltaY != 0,
                  let pointInView = pdfView.frontmostEventPoint(event) else {
                return false
            }

            beginInteractiveZoomQuality(on: pdfView)
            pdfView.autoScales = false
            pdfManager.beginManualZoom()

            let delta = event.scrollingDeltaY

            let oldScale = pdfView.scaleFactor
            let zoomFactor = DesignTokens.pdfControlScrollZoomFactor
            var newScale: CGFloat = delta > 0 ? oldScale * zoomFactor : oldScale / zoomFactor

            newScale = max(DesignTokens.pdfMinScale, min(newScale, DesignTokens.pdfMaxScale))

            // Manager is the source of truth; set it first so the resulting
            // PDFViewScaleChanged notification is recognised as our own echo.
            pdfManager.scaleFactor = newScale

            guard newScale != oldScale else {
                return true
            }

            guard let page = pdfView.page(for: pointInView, nearest: true) else {
                pdfView.scaleFactor = newScale
                return true
            }

            let pointInPage = pdfView.convert(pointInView, to: page)

            pdfView.scaleFactor = newScale

            let pointInViewAfterZoom = pdfView.convert(pointInPage, from: page)

            if let scrollView = pdfView.documentScrollView,
               let documentView = scrollView.documentView {
                let visibleRect = scrollView.documentVisibleRect
                let docBounds = documentView.bounds
                // In the document's own coordinates, whichever way they run.
                let offset = PDFDocumentScroll.zoomAnchorDelta(pointer: pointInView, pageAfterZoom: pointInViewAfterZoom,
                                                               in: pdfView, documentView: documentView)

                var newOrigin = NSPoint(
                    x: visibleRect.origin.x + offset.x,
                    y: visibleRect.origin.y + offset.y
                )

                // Center horizontally if document is narrower than view
                if docBounds.width <= visibleRect.width {
                    newOrigin.x = (docBounds.width - visibleRect.width) / 2.0
                } else {
                    let maxX = docBounds.width - visibleRect.width
                    newOrigin.x = max(0, min(newOrigin.x, maxX))
                }

                // Clamp vertical position
                let maxY = max(0, docBounds.height - visibleRect.height)
                newOrigin.y = max(0, min(newOrigin.y, maxY))

                scrollView.contentView.scroll(to: newOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }

            return true
        }

        /// While a control-scroll zoom is in flight, render at `.low` interpolation
        /// so each frame is cheap on image-heavy/scanned pages, then restore `.high`
        /// ~150ms after the last zoom tick. Vector content is unaffected by
        /// interpolation and the settled frame is always `.high`, so this is
        /// invisible at rest while keeping the zoom itself fluid.
        private func beginInteractiveZoomQuality(on pdfView: StablePDFView) {
            if pdfView.interpolationQuality != .low {
                pdfView.interpolationQuality = .low
            }
            zoomQualityRestore?.cancel()
            let restore = DispatchWorkItem { [weak pdfView] in
                pdfView?.interpolationQuality = .high
            }
            zoomQualityRestore = restore
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: restore)
        }

        func removeScrollMonitor() {
            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
                scrollMonitor = nil
            }
        }

        @objc func pageChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let currentPage = pdfView.currentPage,
                  let document = pdfView.document else {
                return
            }
            let pageIndex = document.index(for: currentPage)
            guard pageIndex != NSNotFound else { return }
            scrollApplyToken &+= 1
            ingestOrDefer(from: pdfView) { [weak self, weak pdfView] in
                guard pdfView?.currentPage === currentPage else { return }
                self?.pdfManager.ingestPageChange(index: pageIndex, page: currentPage)
            }
        }

        @objc func scaleChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView else { return }
            let viewScale = pdfView.scaleFactor
            // Ignore the echo of our own projector write.
            guard PDFViewWrapper.scalesDiffer(viewScale, pdfManager.scaleFactor) else { return }
            ingestOrDefer(from: pdfView) { [weak self, weak pdfView] in
                guard let pdfView, !PDFViewWrapper.scalesDiffer(pdfView.scaleFactor, viewScale) else { return }
                self?.pdfManager.ingestScaleChange(viewScale)
            }
        }

        @objc func displayModeChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? StablePDFView else { return }
            let viewMode = pdfView.displayMode
            // Ignore the echo of our own projector write (view already matches intent).
            guard viewMode != pdfManager.displayMode else { return }
            // User changed mode via PDFKit's own context menu: adopt it and re-fit.
            ingestOrDefer(from: pdfView) { [weak self] in
                self?.pdfManager.ingestDisplayModeChange(viewMode)
            }
            scheduleFitForDisplayModeChange(on: pdfView)
        }

        // MARK: Fit execution

        /// Resolves a one-shot `FitRequest` once the view is laid out, writes the
        /// scale through the single projector path, then clears the request.
        private func performFit(on pdfView: StablePDFView, request: FitRequest, retryCount: Int) {
            let state = deferredProjection(for: pdfView)
            DispatchQueue.main.async { [weak self, weak pdfView] in
                guard let self, let pdfView, self.accepts(state, from: pdfView) else { return }
                // Bail if a newer command (zoom, mode change) superseded this fit.
                guard self.pdfManager.pendingFit == request else { return }

                // Wait for the view to finish initial layout before measuring.
                if (pdfView.bounds.isEmpty || pdfView.document == nil),
                   retryCount < DesignTokens.maxReadinessRetries {
                    DispatchQueue.main.asyncAfter(deadline: .now() + DesignTokens.pdfViewReadyRetryInterval) { [weak self, weak pdfView] in
                        guard let self, let pdfView, self.accepts(state, from: pdfView) else { return }
                        self.performFit(on: pdfView, request: request, retryCount: retryCount + 1)
                    }
                    return
                }

                guard let currentPage = pdfView.currentPage ?? self.pdfManager.currentPage else {
                    self.pdfManager.pendingFit = nil
                    return
                }

                let baseScale = PDFViewWrapper.calculateFitScale(for: pdfView, page: currentPage)
                let fitScale = baseScale + DesignTokens.pdfFitZoomBump
                if fitScale > 0 {
                    let clamped = min(max(fitScale, DesignTokens.pdfMinScale), DesignTokens.pdfMaxScale)
                    self.pdfManager.ingestFitCompletion(scale: clamped) // source of truth first
                    self.applyScale(clamped, to: pdfView)   // then mirror onto the view
                }

                self.pdfManager.pendingFit = nil
                self.scheduleCenterContent(in: pdfView, scrollToTop: request.scrollToTop)
            }
        }

        /// Restores a saved reading position (page + exact scroll point) once the
        /// view is laid out, then re-applies after PDFKit's async relayout settles
        /// (which can otherwise snap scroll back to the page top). One-shot.
        private func restoreScrollPosition(_ destination: PDFDestination, on pdfView: StablePDFView, retryCount: Int) {
            scrollTo(destination, on: pdfView, retryCount: retryCount, oneShot: \.pendingScrollRestore)
        }

        /// Scrolls to an exact destination once the view is laid out, then re-applies
        /// after PDFKit's async relayout settles (which can otherwise snap scroll back
        /// to the page top). `oneShot` is the manager property that armed this scroll:
        /// a newer value there supersedes an in-flight scroll, and it is cleared once
        /// applied. One-shot.
        private func scrollTo(_ destination: PDFDestination,
                              on pdfView: StablePDFView,
                              retryCount: Int,
                              oneShot: ReferenceWritableKeyPath<PDFManager, PDFDestination?>) {
            let state = deferredProjection(for: pdfView)
            DispatchQueue.main.async { [weak self, weak pdfView] in
                guard let self, let pdfView, self.accepts(state, from: pdfView) else { return }
                // Bail if a newer request superseded this one.
                guard self.pdfManager[keyPath: oneShot] === destination else { return }

                // Wait for the view to finish initial layout before scrolling, mirroring `performFit`.
                if (pdfView.bounds.isEmpty || pdfView.document == nil),
                   retryCount < DesignTokens.maxReadinessRetries {
                    DispatchQueue.main.asyncAfter(deadline: .now() + DesignTokens.pdfViewReadyRetryInterval) { [weak self, weak pdfView] in
                        guard let self, let pdfView, self.accepts(state, from: pdfView) else { return }
                        self.scrollTo(destination, on: pdfView, retryCount: retryCount + 1, oneShot: oneShot)
                    }
                    return
                }

                pdfView.go(to: destination)
                self.pdfManager[keyPath: oneShot] = nil
                self.scrollApplyToken &+= 1
                let token = self.scrollApplyToken
                let settledState = self.deferredProjection(for: pdfView)

                // Re-apply after the layout settles; PDFKit can reset scroll mid-relayout.
                // Skip if a newer scroll superseded this one, so a stale delayed reapply
                // can't yank the user back after they've navigated elsewhere.
                DispatchQueue.main.asyncAfter(deadline: .now() + DesignTokens.pdfLayoutSettleDelay) { [weak self, weak pdfView] in
                    guard let self, let pdfView, self.scrollApplyToken == token,
                          self.accepts(settledState, from: pdfView) else { return }
                    pdfView.go(to: destination)
                }
            }
        }

        /// Re-fits after a display-mode change. PDFKit reflows asynchronously, so we
        /// wait for the settle delay before measuring, then scroll to the page top.
        private func scheduleFitForDisplayModeChange(on pdfView: StablePDFView) {
            let state = deferredProjection(for: pdfView)
            DispatchQueue.main.asyncAfter(deadline: .now() + DesignTokens.pdfDisplayModeSettleDelay) { [weak self, weak pdfView] in
                guard let self,
                      let pdfView, self.accepts(state, from: pdfView),
                      let currentPage = pdfView.currentPage ?? self.pdfManager.currentPage else {
                    return
                }

                let baseScale = PDFViewWrapper.calculateFitScale(for: pdfView, page: currentPage)
                let fitScale = baseScale + DesignTokens.pdfFitZoomBump
                guard fitScale > 0 else { return }

                let clamped = min(max(fitScale, DesignTokens.pdfMinScale), DesignTokens.pdfMaxScale)
                self.pdfManager.ingestFitCompletion(scale: clamped)
                self.applyScale(clamped, to: pdfView)

                let pageBounds = currentPage.bounds(for: .mediaBox)
                let topLeft = CGPoint(x: pageBounds.minX, y: pageBounds.maxY)
                pdfView.go(to: PDFDestination(page: currentPage, at: topLeft))

                let settledState = self.deferredProjection(for: pdfView)
                DispatchQueue.main.asyncAfter(deadline: .now() + DesignTokens.pdfLayoutSettleDelay) { [weak self, weak pdfView] in
                    guard let self, let pdfView, self.accepts(settledState, from: pdfView) else { return }
                    self.centerContentAfterFit(in: pdfView)
                }
            }
        }

        private func scheduleCenterContent(in pdfView: StablePDFView, scrollToTop: Bool) {
            let state = deferredProjection(for: pdfView)
            // Delay: PDFKit needs a layout pass before scroll/center position is meaningful.
            DispatchQueue.main.asyncAfter(deadline: .now() + DesignTokens.pdfLayoutSettleDelay) { [weak self, weak pdfView] in
                guard let self, let pdfView, self.accepts(state, from: pdfView) else { return }
                self.centerContent(in: pdfView, scrollToTop: scrollToTop)
            }
        }

        private func centerContent(in pdfView: StablePDFView, scrollToTop: Bool) {
            guard let scrollView = pdfView.documentScrollView,
                  let documentView = scrollView.documentView else { return }

            let docWidth = documentView.bounds.width
            let clipWidth = scrollView.contentView.bounds.width
            let docHeight = documentView.bounds.height
            let clipHeight = scrollView.contentView.bounds.height

            let centeredX: CGFloat
            if docWidth > clipWidth {
                centeredX = (docWidth - clipWidth) / 2.0
            } else {
                centeredX = scrollView.contentView.bounds.origin.x
            }

            let targetY: CGFloat
            if scrollToTop {
                targetY = PDFDocumentScroll.topOriginY(documentHeight: docHeight, clipHeight: clipHeight,
                                                       isFlipped: documentView.isFlipped)
            } else {
                targetY = scrollView.contentView.bounds.origin.y
            }

            let origin = NSPoint(x: centeredX, y: targetY)
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func centerContentAfterFit(in pdfView: StablePDFView) {
            guard let scrollView = pdfView.documentScrollView,
                  let documentView = scrollView.documentView else { return }

            let docWidth = documentView.bounds.width
            let clipWidth = scrollView.contentView.bounds.width

            guard docWidth > clipWidth else { return }

            let centeredX = (docWidth - clipWidth) / 2.0
            let currentY = scrollView.contentView.bounds.origin.y
            let origin = NSPoint(x: centeredX, y: currentY)

            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}
