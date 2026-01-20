//
//  PDFViewWrapper.swift
//  PageFlow
//
//  SwiftUI wrapper for PDFKit's PDFView using StablePDFView for resize stability.
//

import SwiftUI
import PDFKit
import AppKit

struct PDFViewWrapper: NSViewRepresentable {
    @Bindable var pdfManager: PDFManager
    var searchManager: SearchManager
    @Bindable var annotationManager: AnnotationManager
    @Bindable var commentManager: CommentManager
    @Bindable var bookmarkManager: BookmarkManager
    var isActive: Bool

    func makeNSView(context: Context) -> StablePDFView {
        let pdfView = StablePDFView()

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
        
        // Link to manager for Thumbnail support
        pdfManager.activePDFView = pdfView

        // Setup click callbacks for annotation selection
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

        // Setup right-click event monitor for annotation removal
        pdfView.setupRightClickMonitor()

        // Setup control + scroll zoom handling
        pdfView.onControlScroll = { [weak pdfView, weak coordinator = context.coordinator] event in
            guard let pdfView = pdfView,
                  let coordinator = coordinator else { return false }
            return coordinator.processControlScroll(event: event, pdfView: pdfView)
        }

        // Setup link navigation callback for back/forward history
        pdfView.onLinkNavigation = { [weak pdfManager] in
            pdfManager?.pushNavigationState()
        }

        // Setup markdown export callbacks for page context menu
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

        // Setup bookmark toggle callback for page context menu
        pdfView.onToggleBookmark = { [weak pdfManager, weak bookmarkManager] in
            guard let pdfManager = pdfManager,
                  let bookmarkManager = bookmarkManager else { return }
            bookmarkManager.toggleBookmark(at: pdfManager.currentPageIndex)
        }

        pdfView.onAnnotationRemove = { [weak pdfView, weak annotationManager, weak pdfManager] annotation in
            guard let page = annotation.page else { return }

            // Remove annotation from page - this is the core operation
            page.removeAnnotation(annotation)

            // Mark document as dirty and trigger thumbnail refresh
            pdfManager?.isDirty = true
            pdfManager?.pageVersion += 1

            // Clear selection if this annotation was selected
            if annotationManager?.selectedAnnotation === annotation {
                annotationManager?.selectedAnnotation = nil
            }

            // Force PDFView to redraw (if still available)
            if let pdfView = pdfView {
                pdfView.needsDisplay = true
                pdfView.layoutDocumentView()
            }

            // Register undo
            if let undoManager = pdfView?.undoManager {
                undoManager.registerUndo(withTarget: page) { [weak pdfView, weak pdfManager] targetPage in
                    targetPage.addAnnotation(annotation)
                    pdfManager?.isDirty = true
                    pdfManager?.pageVersion += 1
                    pdfView?.needsDisplay = true
                    pdfView?.layoutDocumentView()
                }
                undoManager.setActionName("Remove Annotation")
            }
        }

        pdfView.onAnnotationColorChange = { [weak pdfView, weak pdfManager] annotation, color in
            let previousColor = annotation.color

            // Change the annotation color
            annotation.color = color

            // Mark document as dirty and trigger thumbnail refresh
            pdfManager?.isDirty = true
            pdfManager?.pageVersion += 1

            // Force PDFView to redraw
            pdfView?.needsDisplay = true
            pdfView?.layoutDocumentView()

            // Register undo
            if let undoManager = pdfView?.undoManager {
                undoManager.registerUndo(withTarget: annotation) { [weak pdfView, weak pdfManager] targetAnnotation in
                    targetAnnotation.color = previousColor
                    pdfManager?.isDirty = true
                    pdfManager?.pageVersion += 1
                    pdfView?.needsDisplay = true
                    pdfView?.layoutDocumentView()
                }
                undoManager.setActionName("Change Color")
            }
        }

        pdfView.onCommentColorChange = { [weak pdfView, weak pdfManager] annotation, color in
            let previousColor = annotation.color

            // Change the comment annotation color (alpha is baked into preset)
            annotation.color = color

            // Mark document as dirty and trigger thumbnail refresh
            pdfManager?.isDirty = true
            pdfManager?.pageVersion += 1

            // Force PDFView to redraw
            pdfView?.needsDisplay = true
            pdfView?.layoutDocumentView()

            // Register undo
            if let undoManager = pdfView?.undoManager {
                undoManager.registerUndo(withTarget: annotation) { [weak pdfView, weak pdfManager] targetAnnotation in
                    targetAnnotation.color = previousColor
                    pdfManager?.isDirty = true
                    pdfManager?.pageVersion += 1
                    pdfView?.needsDisplay = true
                    pdfView?.layoutDocumentView()
                }
                undoManager.setActionName("Change Comment Color")
            }
        }

        // Create the undoManagerProvider closure for all managers
        let undoManagerProvider: () -> UndoManager? = { [weak pdfView] in
            pdfView?.undoManager
        }

        pdfManager.undoManagerProvider = undoManagerProvider

        annotationManager.configure(
            pdfManager: pdfManager,
            selectionProvider: { [weak pdfView] in
                guard let pdfView = pdfView,
                      let selection = pdfView.currentSelection else { return (nil, nil) }
                // Get page from selection itself, not currentPage (fixes two-page continuous mode)
                let page = selection.pages.first ?? pdfView.currentPage
                return (selection, page)
            },
            undoManagerProvider: undoManagerProvider
        )

        commentManager.configure(
            pdfManager: pdfManager,
            selectionProvider: { [weak pdfView] in
                guard let pdfView = pdfView else { return (nil, nil) }
                // If there's a selection, get page from it; otherwise use currentPage for default comment
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

        context.coordinator.setPDFView(pdfView)

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

        // Setup scroll event monitor for Ctrl+Scroll zoom
        context.coordinator.setupScrollMonitor(for: pdfView)

        return pdfView
    }

    func updateNSView(_ pdfView: StablePDFView, context: Context) {
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
                // Scroll to top after scale is set
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.centerContent(in: pdfView, scrollToTop: true)
                }
            }
        } else if let currentPage = pdfManager.currentPage,
                  pdfView.currentPage !== currentPage {
            // Only update page if it actually changed in the manager
            pdfView.go(to: currentPage)
        }

        // Sync displayMode BEFORE autoScales to prevent PDFKit side effects
        if pdfView.displayMode != pdfManager.displayMode {
            pdfView.displayMode = pdfManager.displayMode
        }

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

        updateSearchHighlights(pdfView)
    }

    private func updateSearchHighlights(_ pdfView: StablePDFView) {
        if searchManager.hasResults {
            pdfView.highlightedSelections = searchManager.highlightedSelections(
                currentColor: DesignTokens.searchCurrentResult,
                othersColor: DesignTokens.searchOtherResults
            )

            if let currentSelection = searchManager.currentSelection() {
                pdfView.go(to: currentSelection)
                pdfView.setCurrentSelection(currentSelection, animate: true)
            }
        } else {
            pdfView.highlightedSelections = nil
            pdfView.setCurrentSelection(nil, animate: false)
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

    static func dismantleNSView(_ pdfView: StablePDFView, coordinator: Coordinator) {
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

        // Clear the activePDFView reference if it points to this view
        if coordinator.pdfManager.activePDFView === pdfView {
            coordinator.pdfManager.activePDFView = nil
        }
    }

    // MARK: - Private

    private func performOneTimeFit(on pdfView: StablePDFView, scrollToTop: Bool = false) {
        performFit(on: pdfView, retryCount: 0, scrollToTop: scrollToTop)
    }

    private func performFit(on pdfView: StablePDFView, retryCount: Int, scrollToTop: Bool = false) {
        DispatchQueue.main.async {
            guard self.pdfManager.fitOnceRequested else { return }

            // Check if view is ready
            if (pdfView.bounds.isEmpty || pdfView.document == nil) && retryCount < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.performFit(on: pdfView, retryCount: retryCount + 1, scrollToTop: scrollToTop)
                }
                return
            }

            guard let currentPage = pdfView.currentPage ?? self.pdfManager.currentPage else {
                self.pdfManager.fitOnceRequested = false
                return
            }

            // Calculate fit scale + zoom bump for comfortable reading
            let baseScale = self.calculateFitScale(for: pdfView, page: currentPage)
            let zoomBump: CGFloat = 0.05
            let fitScale = baseScale + zoomBump

            if fitScale > 0 {
                let clampedScale = min(max(fitScale, DesignTokens.pdfMinScale), DesignTokens.pdfMaxScale)
                pdfView.scaleFactor = clampedScale
                self.pdfManager.scaleFactor = clampedScale
            }

            self.pdfManager.fitOnceRequested = false
            self.pdfManager.scaleNeedsUpdate = false

            // Center content after layout updates (and scroll to top for new documents)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.centerContent(in: pdfView, scrollToTop: scrollToTop)
            }
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

    private func calculateFitScale(for pdfView: StablePDFView, page: PDFPage) -> CGFloat {
        let viewBounds = pdfView.bounds
        guard viewBounds.width > 0, viewBounds.height > 0 else { return 1.0 }

        let pageBounds = page.bounds(for: .mediaBox)
        let pageWidth = pageBounds.width
        let pageHeight = pageBounds.height
        guard pageWidth > 0, pageHeight > 0 else { return 1.0 }

        // Account for page margins/padding in PDFView
        let horizontalPadding: CGFloat = 20
        let verticalPadding: CGFloat = 20
        let availableWidth = viewBounds.width - horizontalPadding
        let availableHeight = viewBounds.height - verticalPadding

        switch pdfView.displayMode {
        case .singlePage:
            // Fit entire page in view
            let widthScale = availableWidth / pageWidth
            let heightScale = availableHeight / pageHeight
            return min(widthScale, heightScale)

        case .singlePageContinuous:
            // Fit page width, allow vertical scroll
            return availableWidth / pageWidth

        case .twoUp:
            // Fit two pages side by side
            let twoPageWidth = pageWidth * 2 + 10 // 10pt gap between pages
            let widthScale = availableWidth / twoPageWidth
            let heightScale = availableHeight / pageHeight
            return min(widthScale, heightScale)

        case .twoUpContinuous:
            // Fit two pages width, allow vertical scroll
            let twoPageWidth = pageWidth * 2 + 10
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
        private weak var pdfView: StablePDFView?
        private var lastKnownScale: CGFloat?
        private var wasActive: Bool = true

        init(pdfManager: PDFManager, annotationManager: AnnotationManager, commentManager: CommentManager, isActive: Bool) {
            self.pdfManager = pdfManager
            self.annotationManager = annotationManager
            self.commentManager = commentManager
            self.isActive = isActive
            super.init()
        }

        func setupScrollMonitor(for pdfView: StablePDFView) {
            self.pdfView = pdfView

            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak pdfView] event in
                guard let self = self,
                      let pdfView = pdfView else {
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
            if pdfView.displayMode != pdfManager.displayMode {
                pdfView.displayMode = pdfManager.displayMode
            }

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
            let zoomFactor: CGFloat = 1.1  // 10% per scroll
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

        func setPDFView(_ pdfView: StablePDFView) {
            self.pdfView = pdfView
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
            pdfManager.currentPageIndex = pageIndex
            pdfManager.currentPage = currentPage
            pdfManager.scaleFactor = pdfView.scaleFactor
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
            // Sync manager to match PDFView (user may have changed via context menu)
            if pdfManager.displayMode != pdfView.displayMode {
                pdfManager.displayMode = pdfView.displayMode

                // Auto zoom-fit when display mode changes
                performFitForDisplayModeChange(on: pdfView)
            }
        }

        private func performFitForDisplayModeChange(on pdfView: StablePDFView) {
            // Delay to allow PDFKit to update its layout for the new display mode
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak pdfView] in
                guard let self = self,
                      let pdfView = pdfView,
                      let currentPage = pdfView.currentPage ?? self.pdfManager.currentPage else {
                    return
                }

                // Calculate fit scale for the new display mode
                let baseScale = self.calculateFitScaleForMode(pdfView: pdfView, page: currentPage)
                let zoomBump: CGFloat = 0.05
                let fitScale = baseScale + zoomBump

                guard fitScale > 0 else { return }

                let clampedScale = min(max(fitScale, DesignTokens.pdfMinScale), DesignTokens.pdfMaxScale)
                pdfView.scaleFactor = clampedScale
                self.pdfManager.scaleFactor = clampedScale

                // Navigate to top of current page
                let pageBounds = currentPage.bounds(for: .mediaBox)
                let topLeft = CGPoint(x: pageBounds.minX, y: pageBounds.maxY)
                pdfView.go(to: PDFDestination(page: currentPage, at: topLeft))

                // Center content after layout updates
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak pdfView] in
                    guard let self = self, let pdfView = pdfView else { return }
                    self.centerContentAfterFit(in: pdfView)
                }
            }
        }

        private func calculateFitScaleForMode(pdfView: StablePDFView, page: PDFPage) -> CGFloat {
            let viewBounds = pdfView.bounds
            guard viewBounds.width > 0, viewBounds.height > 0 else { return 1.0 }

            let pageBounds = page.bounds(for: .mediaBox)
            let pageWidth = pageBounds.width
            let pageHeight = pageBounds.height
            guard pageWidth > 0, pageHeight > 0 else { return 1.0 }

            let horizontalPadding: CGFloat = 20
            let verticalPadding: CGFloat = 20
            let availableWidth = viewBounds.width - horizontalPadding
            let availableHeight = viewBounds.height - verticalPadding

            switch pdfView.displayMode {
            case .singlePage:
                let widthScale = availableWidth / pageWidth
                let heightScale = availableHeight / pageHeight
                return min(widthScale, heightScale)

            case .singlePageContinuous:
                return availableWidth / pageWidth

            case .twoUp:
                let twoPageWidth = pageWidth * 2 + 10
                let widthScale = availableWidth / twoPageWidth
                let heightScale = availableHeight / pageHeight
                return min(widthScale, heightScale)

            case .twoUpContinuous:
                let twoPageWidth = pageWidth * 2 + 10
                return availableWidth / twoPageWidth

            @unknown default:
                return availableWidth / pageWidth
            }
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
