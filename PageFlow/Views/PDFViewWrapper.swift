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

        pdfView.onAnnotationRemove = { [weak pdfView, weak annotationManager, weak pdfManager] annotation in
            guard let page = annotation.page else { return }

            // Remove annotation from page - this is the core operation
            page.removeAnnotation(annotation)

            // Mark document as dirty
            pdfManager?.isDirty = true

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
            if let undoManager = NSApp.keyWindow?.undoManager {
                undoManager.registerUndo(withTarget: page) { [weak pdfView, weak pdfManager] targetPage in
                    targetPage.addAnnotation(annotation)
                    pdfManager?.isDirty = true
                    pdfView?.needsDisplay = true
                    pdfView?.layoutDocumentView()
                }
                undoManager.setActionName("Remove Annotation")
            }
        }

        annotationManager.configure(
            pdfManager: pdfManager,
            selectionProvider: { [weak pdfView] in
                guard let pdfView = pdfView,
                      let selection = pdfView.currentSelection else { return (nil, nil) }
                // Get page from selection itself, not currentPage (fixes two-page continuous mode)
                let page = selection.pages.first ?? pdfView.currentPage
                return (selection, page)
            }
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
            }
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
            annotationManager.selectedAnnotation = nil
            pdfView.document = pdfManager.document

            if let currentPage = pdfManager.currentPage {
                pdfView.go(to: currentPage)
            }

            if let document = pdfManager.document {
                commentManager.loadComments(from: document)
            } else {
                commentManager.clearComments()
            }

            pdfView.autoScales = false
            if pdfManager.fitOnceRequested {
                performOneTimeFit(on: pdfView)
            } else {
                pdfView.scaleFactor = pdfManager.scaleFactor
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
        pdfView.onControlScroll = nil

        // Clear the activePDFView reference if it points to this view
        if coordinator.pdfManager.activePDFView === pdfView {
            coordinator.pdfManager.activePDFView = nil
        }
    }

    // MARK: - Private

    private func performOneTimeFit(on pdfView: StablePDFView) {
        performFit(on: pdfView, retryCount: 0)
    }

    private func performFit(on pdfView: StablePDFView, retryCount: Int) {
        DispatchQueue.main.async {
            guard self.pdfManager.fitOnceRequested else { return }

            // Check if view is ready (has bounds and document)
            // If not, retry up to 10 times (1 second total)
            if (pdfView.bounds.isEmpty || pdfView.document == nil) && retryCount < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.performFit(on: pdfView, retryCount: retryCount + 1)
                }
                return
            }

            // Preserve current state before modifying
            let originalAutoScale = pdfView.autoScales
            let originalDisplayMode = pdfView.displayMode

            // Temporarily enable autoScales to get the correct fit scale
            pdfView.autoScales = true

            let fitScale = pdfView.scaleFactorForSizeToFit

            // If scale is invalid (0) and we haven't timed out, retry
            if fitScale <= 0 && retryCount < 10 {
                pdfView.autoScales = originalAutoScale
                pdfView.displayMode = originalDisplayMode
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.performFit(on: pdfView, retryCount: retryCount + 1)
                }
                return
            }

            // Apply valid scale with a fit-to-window scale + slight zoom bump
            if fitScale > 0 {
                let zoomBump: CGFloat = 0.1
                let adjustedScale = min(fitScale + zoomBump, DesignTokens.pdfMaxScale)
                
                if adjustedScale != pdfView.scaleFactor {
                    pdfView.scaleFactor = adjustedScale
                    self.pdfManager.scaleFactor = adjustedScale
                }

                // Set destination to top-left initially to set vertical position
                if let currentPage = pdfView.currentPage ?? self.pdfManager.currentPage {
                    let pageBounds = currentPage.bounds(for: .mediaBox)
                    let topLeft = CGPoint(x: pageBounds.minX, y: pageBounds.maxY)
                    let destination = PDFDestination(page: currentPage, at: topLeft)
                    pdfView.go(to: destination)
                    
                    if let scrollView = pdfView.documentScrollView {
                        // Center horizontally
                        let docViewWidth = scrollView.documentView?.bounds.width ?? 0
                        let clipViewWidth = scrollView.contentView.bounds.width
                        let centeredX = max(0, (docViewWidth - clipViewWidth) / 2.0)
                        
                        // Keep current Y (set by go(to:))
                        let origin = NSPoint(x: centeredX, y: scrollView.documentVisibleRect.origin.y)
                        scrollView.contentView.scroll(to: origin)
                        scrollView.reflectScrolledClipView(scrollView.contentView)
                    }
                }
            }

            self.pdfManager.fitOnceRequested = false
            self.pdfManager.scaleNeedsUpdate = false

            // Restore original state
            pdfView.autoScales = originalAutoScale
            pdfView.displayMode = originalDisplayMode
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

            if let scrollView = pdfView.documentScrollView {
                let visibleRect = scrollView.documentVisibleRect

                var newOrigin = NSPoint(
                    x: visibleRect.origin.x + offsetX,
                    y: visibleRect.origin.y + offsetY
                )

                if let documentView = scrollView.documentView {
                    let maxX = max(0, documentView.bounds.width - visibleRect.width)
                    let maxY = max(0, documentView.bounds.height - visibleRect.height)
                    newOrigin.x = max(0, min(newOrigin.x, maxX))
                    newOrigin.y = max(0, min(newOrigin.y, maxY))
                }

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
            guard let pdfView = notification.object as? PDFView else { return }
            // Sync manager to match PDFView (user may have changed via context menu)
            if pdfManager.displayMode != pdfView.displayMode {
                pdfManager.displayMode = pdfView.displayMode
            }
        }
    }
}
