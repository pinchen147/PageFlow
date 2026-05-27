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

        pdfView.setupRightClickMonitor()

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
            guard let pdfManager = pdfManager,
                  let document = pdfManager.document else { return }

            let markdown = MarkdownExporter.export(
                scope: .currentPage(pdfManager.currentPageIndex),
                document: document,
                comments: commentManager?.comments ?? []
            )
            guard !markdown.isEmpty else { return }
            MarkdownExporter.copyToClipboard(markdown)
        }

        pdfView.onCopyDocumentAsMarkdown = { [weak pdfManager, weak commentManager] in
            guard let pdfManager = pdfManager,
                  let document = pdfManager.document else { return }

            let markdown = MarkdownExporter.export(
                scope: .entireDocument,
                document: document,
                comments: commentManager?.comments ?? []
            )
            guard !markdown.isEmpty else { return }
            MarkdownExporter.copyToClipboard(markdown)
        }

        pdfView.onToggleBookmark = { [weak pdfManager, weak bookmarkManager] in
            guard let pdfManager = pdfManager,
                  let bookmarkManager = bookmarkManager else { return }
            bookmarkManager.toggleBookmark(at: pdfManager.currentPageIndex)
        }
    }

    private func configureManagers(_ pdfView: StablePDFView, context: Context) {
        let tabUndoManager = self.tabUndoManager
        #if DEBUG
        Swift.print("[PDFViewWrapper] configureManagers with tabUndoManager=\(ObjectIdentifier(tabUndoManager))")
        #endif
        let undoManagerProvider: () -> UndoManager? = {
            tabUndoManager
        }

        pdfManager.undoManagerProvider = undoManagerProvider

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

        context.coordinator.setupScrollMonitor(for: pdfView)
    }

    func updateNSView(_ hostView: PDFViewHost, context: Context) {
        let pdfView = hostView.pdfView
        context.coordinator.isActive = isActive
        context.coordinator.handleActivationChange(isActive: isActive, pdfView: pdfView)

        if pdfView.document !== pdfManager.document {
            pdfView.document = pdfManager.document

            // Go to first page (scroll to top handled after fit)
            if let currentPage = pdfManager.currentPage {
                pdfView.go(to: currentPage)
            }

            if let document = pdfManager.document {
                annotationManager.loadAnnotations(from: document)
                commentManager.loadComments(from: document)
            } else {
                annotationManager.clearAnnotations()
                commentManager.clearComments()
            }

            pdfView.autoScales = false
            if pdfManager.fitOnceRequested {
                performOneTimeFit(on: pdfView, scrollToTop: true)
            } else {
                pdfView.scaleFactor = pdfManager.scaleFactor
                scheduleCenterContent(in: pdfView, scrollToTop: true)
            }
        } else if let currentPage = pdfManager.currentPage,
                  pdfView.currentPage !== currentPage {
            // Only update page if it actually changed in the manager
            pdfView.go(to: currentPage)
        }

        // Sync displayMode BEFORE autoScales to prevent PDFKit side effects
        context.coordinator.applyManagerDisplayMode(to: pdfView, shouldFit: true)

        if pdfView.autoScales != pdfManager.isAutoScaling {
            pdfView.autoScales = pdfManager.isAutoScaling
        }

        if pdfView.interactionMode != pdfManager.interactionMode {
            pdfView.interactionMode = pdfManager.interactionMode
        }

        if pdfManager.fitOnceRequested {
            performOneTimeFit(on: pdfView)
        } else if pdfManager.scaleNeedsUpdate {
            // Only update scale if explicitly requested AND not auto-scaling
            if !pdfView.autoScales {
                pdfView.scaleFactor = pdfManager.scaleFactor
            }
            pdfManager.scaleNeedsUpdate = false
        }

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

        // Clear all callbacks to prevent any lingering references
        pdfView.onAnnotationClick = nil
        pdfView.onAnnotationDeselect = nil
        pdfView.onAnnotationRemove = nil
        pdfView.onAnnotationColorChange = nil
        pdfView.onCommentColorChange = nil
        pdfView.onControlScroll = nil
        pdfView.onLinkNavigation = nil
        pdfView.onCopyPageAsMarkdown = nil
        pdfView.onCopyDocumentAsMarkdown = nil
        pdfView.onToggleBookmark = nil

    }

    // MARK: - Private

    private func performOneTimeFit(on pdfView: StablePDFView, scrollToTop: Bool = false) {
        performFit(on: pdfView, retryCount: 0, scrollToTop: scrollToTop)
    }

    private func performFit(on pdfView: StablePDFView, retryCount: Int, scrollToTop: Bool = false) {
        DispatchQueue.main.async { [weak pdfView] in
            guard let pdfView else { return }
            guard self.pdfManager.fitOnceRequested else { return }

            // Check if view is ready
            if (pdfView.bounds.isEmpty || pdfView.document == nil) && retryCount < DesignTokens.maxReadinessRetries {
                retryFitWhenReady(on: pdfView, retryCount: retryCount, scrollToTop: scrollToTop)
                return
            }

            guard let currentPage = pdfView.currentPage ?? self.pdfManager.currentPage else {
                self.pdfManager.fitOnceRequested = false
                return
            }

            // Calculate fit scale + zoom bump for comfortable reading
            let baseScale = Self.calculateFitScale(for: pdfView, page: currentPage)
            let fitScale = baseScale + DesignTokens.pdfFitZoomBump

            if fitScale > 0 {
                let clampedScale = min(max(fitScale, DesignTokens.pdfMinScale), DesignTokens.pdfMaxScale)
                pdfView.scaleFactor = clampedScale
                self.pdfManager.scaleFactor = clampedScale
            }

            self.pdfManager.fitOnceRequested = false
            self.pdfManager.scaleNeedsUpdate = false

            self.scheduleCenterContent(in: pdfView, scrollToTop: scrollToTop)
        }
    }

    private func retryFitWhenReady(on pdfView: StablePDFView, retryCount: Int, scrollToTop: Bool) {
        // Delay: wait for PDFView to finish initial layout before calculating fit scale.
        DispatchQueue.main.asyncAfter(deadline: .now() + DesignTokens.pdfViewReadyRetryInterval) { [weak pdfView] in
            guard let pdfView else { return }
            self.performFit(on: pdfView, retryCount: retryCount + 1, scrollToTop: scrollToTop)
        }
    }

    private func scheduleCenterContent(in pdfView: StablePDFView, scrollToTop: Bool) {
        // Delay: PDFKit needs a layout pass before scroll/center position is meaningful.
        DispatchQueue.main.asyncAfter(deadline: .now() + DesignTokens.pdfLayoutSettleDelay) { [weak pdfView] in
            guard let pdfView else { return }
            self.centerContent(in: pdfView, scrollToTop: scrollToTop)
        }
    }

    private func centerContent(in pdfView: StablePDFView, scrollToTop: Bool = false) {
        guard let scrollView = pdfView.documentScrollView,
              let documentView = scrollView.documentView else { return }

        let docWidth = documentView.bounds.width
        let clipWidth = scrollView.contentView.bounds.width
        let docHeight = documentView.bounds.height
        let clipHeight = scrollView.contentView.bounds.height

        // Calculate horizontal center if content is wider than view
        let centeredX: CGFloat
        if docWidth > clipWidth {
            centeredX = (docWidth - clipWidth) / 2.0
        } else {
            centeredX = scrollView.contentView.bounds.origin.x
        }

        // Scroll to top (max Y in flipped coordinates) or preserve current Y
        let targetY: CGFloat
        if scrollToTop {
            targetY = max(0, docHeight - clipHeight)
        } else {
            targetY = scrollView.contentView.bounds.origin.y
        }

        let origin = NSPoint(x: centeredX, y: targetY)
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private static func calculateFitScale(for pdfView: PDFView, page: PDFPage) -> CGFloat {
        let viewBounds = pdfView.bounds
        guard viewBounds.width > 0, viewBounds.height > 0 else { return 1.0 }

        let pageBounds = page.bounds(for: .mediaBox)
        let pageWidth = pageBounds.width
        let pageHeight = pageBounds.height
        guard pageWidth > 0, pageHeight > 0 else { return 1.0 }

        let availableWidth = viewBounds.width - DesignTokens.pdfViewPadding
        let availableHeight = viewBounds.height - DesignTokens.pdfViewPadding

        switch pdfView.displayMode {
        case .singlePage:
            let widthScale = availableWidth / pageWidth
            let heightScale = availableHeight / pageHeight
            return min(widthScale, heightScale)

        case .singlePageContinuous:
            return availableWidth / pageWidth

        case .twoUp:
            let twoPageWidth = pageWidth * 2 + DesignTokens.pdfTwoPageGap
            let widthScale = availableWidth / twoPageWidth
            let heightScale = availableHeight / pageHeight
            return min(widthScale, heightScale)

        case .twoUpContinuous:
            let twoPageWidth = pageWidth * 2 + DesignTokens.pdfTwoPageGap
            return availableWidth / twoPageWidth

        @unknown default:
            return availableWidth / pageWidth
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, PDFViewDelegate {
        let pdfManager: PDFManager
        let annotationManager: AnnotationManager
        let commentManager: CommentManager
        var isActive: Bool = true
        private var scrollMonitor: Any?
        private var lastKnownScale: CGFloat?
        private var lastKnownDisplayMode: PDFDisplayMode
        private var wasActive: Bool = true
        var lastNavigatedSearchIndex: Int = -1
        var lastSearchResultCount: Int = 0
        fileprivate var lastAppliedSearchHighlightSignature: SearchHighlightSignature?
        var searchHighlightsAreClear = true

        init(pdfManager: PDFManager, annotationManager: AnnotationManager, commentManager: CommentManager, isActive: Bool) {
            self.pdfManager = pdfManager
            self.annotationManager = annotationManager
            self.commentManager = commentManager
            self.isActive = isActive
            self.lastKnownDisplayMode = pdfManager.displayMode
            super.init()
        }

        func setupScrollMonitor(for pdfView: StablePDFView) {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak pdfView] event in
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
            let handled = processControlScroll(event: event, pdfView: pdfView)
            return handled ? nil : event
        }

        func handleActivationChange(isActive: Bool, pdfView: StablePDFView) {
            guard wasActive != isActive else { return }
            wasActive = isActive

            guard isActive else { return }

            // When becoming active, sync displayMode FIRST to prevent PDFKit side effects
            applyManagerDisplayMode(to: pdfView, shouldFit: false)

            // Then sync scale settings
            pdfView.autoScales = pdfManager.isAutoScaling
            if !pdfView.autoScales {
                let targetScale = pdfManager.scaleFactor
                if pdfView.scaleFactor != targetScale {
                    pdfView.scaleFactor = targetScale
                }
            }
            lastKnownScale = pdfView.scaleFactor
        }

        func processControlScroll(event: NSEvent, pdfView: StablePDFView) -> Bool {
            guard isActive,
                  event.modifierFlags.contains(.control),
                  let pointInView = convertEventPoint(event, in: pdfView),
                  pdfView.bounds.contains(pointInView) else {
                return false
            }

            pdfView.autoScales = false
            pdfManager.isAutoScaling = false

            let delta = event.scrollingDeltaY
            guard delta != 0 else { return true }

            let oldScale = pdfView.scaleFactor
            let zoomFactor = DesignTokens.pdfControlScrollZoomFactor
            var newScale: CGFloat = delta > 0 ? oldScale * zoomFactor : oldScale / zoomFactor

            newScale = max(DesignTokens.pdfMinScale, min(newScale, DesignTokens.pdfMaxScale))

            guard newScale != oldScale else {
                pdfManager.scaleFactor = newScale
                return true
            }

            guard let page = pdfView.page(for: pointInView, nearest: true) else {
                pdfView.scaleFactor = newScale
                pdfManager.scaleFactor = newScale
                return true
            }

            let pointInPage = pdfView.convert(pointInView, to: page)

            pdfView.scaleFactor = newScale

            let pointInViewAfterZoom = pdfView.convert(pointInPage, from: page)

            let offsetX = pointInViewAfterZoom.x - pointInView.x
            let offsetY = pointInViewAfterZoom.y - pointInView.y

            if let scrollView = pdfView.documentScrollView,
               let documentView = scrollView.documentView {
                let visibleRect = scrollView.documentVisibleRect
                let docBounds = documentView.bounds

                var newOrigin = NSPoint(
                    x: visibleRect.origin.x + offsetX,
                    y: visibleRect.origin.y + offsetY
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

            pdfManager.scaleFactor = newScale

            return true
        }

        private func convertEventPoint(_ event: NSEvent, in pdfView: StablePDFView) -> NSPoint? {
            if event.window != nil {
                return pdfView.convert(event.locationInWindow, from: nil)
            }

            // Fallback to screen location if window is unavailable (rare during monitoring)
            let screenPoint = NSEvent.mouseLocation
            guard let window = pdfView.window else { return nil }
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            return pdfView.convert(windowPoint, from: nil)
        }

        func removeScrollMonitor() {
            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
                scrollMonitor = nil
            }
        }

        func applyManagerDisplayMode(to pdfView: StablePDFView, shouldFit: Bool) {
            guard pdfView.displayMode != pdfManager.displayMode else { return }

            pdfView.displayMode = pdfManager.displayMode
            recordDisplayMode(pdfView.displayMode, on: pdfView, shouldFit: shouldFit)
        }

        @objc func pageChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let currentPage = pdfView.currentPage,
                  let document = pdfView.document else {
                return
            }

            let pageIndex = document.index(for: currentPage)
            if pdfManager.currentPageIndex != pageIndex {
                pdfManager.currentPageIndex = pageIndex
            }

            if pdfManager.currentPage !== currentPage {
                pdfManager.currentPage = currentPage
            }

            let newScale = pdfView.scaleFactor
            if pdfManager.scaleFactor != newScale {
                pdfManager.scaleFactor = newScale
            }
            lastKnownScale = newScale
        }

        @objc func scaleChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView else { return }
            let newScale = pdfView.scaleFactor

            guard lastKnownScale != newScale else { return }
            lastKnownScale = newScale

            pdfManager.scaleFactor = newScale
        }

        @objc func displayModeChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? StablePDFView else { return }

            guard pdfView.displayMode != lastKnownDisplayMode else { return }

            recordDisplayMode(pdfView.displayMode, on: pdfView, shouldFit: true)

            // Sync manager to match PDFView (user may have changed via context menu)
            if pdfManager.displayMode != pdfView.displayMode {
                pdfManager.displayMode = pdfView.displayMode
            }
        }

        private func recordDisplayMode(_ displayMode: PDFDisplayMode, on pdfView: StablePDFView, shouldFit: Bool) {
            lastKnownDisplayMode = displayMode

            guard shouldFit else { return }
            performFitForDisplayModeChange(on: pdfView)
        }

        private func performFitForDisplayModeChange(on pdfView: StablePDFView) {
            // Delay: PDFKit needs time to update its internal layout for the new display mode
            DispatchQueue.main.asyncAfter(deadline: .now() + DesignTokens.pdfDisplayModeSettleDelay) { [weak self, weak pdfView] in
                guard let self = self,
                      let pdfView = pdfView,
                      let currentPage = pdfView.currentPage ?? self.pdfManager.currentPage else {
                    return
                }

                let baseScale = self.calculateFitScaleForMode(pdfView: pdfView, page: currentPage)
                let fitScale = baseScale + DesignTokens.pdfFitZoomBump

                guard fitScale > 0 else { return }

                let clampedScale = min(max(fitScale, DesignTokens.pdfMinScale), DesignTokens.pdfMaxScale)
                pdfView.scaleFactor = clampedScale
                self.pdfManager.scaleFactor = clampedScale

                let pageBounds = currentPage.bounds(for: .mediaBox)
                let topLeft = CGPoint(x: pageBounds.minX, y: pageBounds.maxY)
                pdfView.go(to: PDFDestination(page: currentPage, at: topLeft))

                // Delay: PDFKit needs a layout pass before scroll/center position is meaningful
                DispatchQueue.main.asyncAfter(deadline: .now() + DesignTokens.pdfLayoutSettleDelay) { [weak self, weak pdfView] in
                    guard let self = self, let pdfView = pdfView else { return }
                    self.centerContentAfterFit(in: pdfView)
                }
            }
        }

        private func calculateFitScaleForMode(pdfView: StablePDFView, page: PDFPage) -> CGFloat {
            PDFViewWrapper.calculateFitScale(for: pdfView, page: page)
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
