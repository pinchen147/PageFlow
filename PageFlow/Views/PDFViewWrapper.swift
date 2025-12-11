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

    func makeNSView(context: Context) -> StablePDFView {
        let pdfView = StablePDFView()

        pdfView.wantsLayer = true
        pdfView.layer?.isOpaque = true
        pdfView.layer?.backgroundColor = DesignTokens.viewerBackground.cgColor
        pdfView.backgroundColor = DesignTokens.viewerBackground
        pdfView.displayMode = .singlePageContinuous
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

        annotationManager.configure(
            pdfManager: pdfManager,
            selectionProvider: { [weak pdfView] in
                guard let pdfView = pdfView else { return (nil, nil) }
                return (pdfView.currentSelection, pdfView.currentPage)
            }
        )

        commentManager.configure(
            pdfManager: pdfManager,
            selectionProvider: { [weak pdfView] in
                guard let pdfView = pdfView else { return (nil, nil) }
                return (pdfView.currentSelection, pdfView.currentPage)
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

        // Setup scroll event monitor for Ctrl+Scroll zoom
        context.coordinator.setupScrollMonitor(for: pdfView)

        return pdfView
    }

    func updateNSView(_ pdfView: StablePDFView, context: Context) {
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

            pdfView.autoScales = pdfManager.isAutoScaling
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

        if pdfView.autoScales != pdfManager.isAutoScaling {
            pdfView.autoScales = pdfManager.isAutoScaling
        }

        if pdfView.interactionMode != pdfManager.interactionMode {
            pdfView.interactionMode = pdfManager.interactionMode
        }

        if pdfManager.fitOnceRequested {
            performOneTimeFit(on: pdfView)
        } else if pdfManager.scaleNeedsUpdate {
            // Only update scale if explicitly requested
            pdfView.scaleFactor = pdfManager.scaleFactor
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
            commentManager: commentManager
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
        coordinator.removeScrollMonitor()

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

            // Temporarily enable autoScales to get the correct fit scale
            let originalAutoScale = pdfView.autoScales
            pdfView.autoScales = true

            let fitScale = pdfView.scaleFactorForSizeToFit

            // If scale is invalid (0) and we haven't timed out, retry
            if fitScale <= 0 && retryCount < 10 {
                pdfView.autoScales = originalAutoScale
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

                if let currentPage = pdfView.currentPage ?? self.pdfManager.currentPage {
                    let pageBounds = currentPage.bounds(for: .mediaBox)
                    // Set destination to top-left initially to set vertical position
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

            pdfView.autoScales = originalAutoScale
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, PDFViewDelegate {
        let pdfManager: PDFManager
        let annotationManager: AnnotationManager
        let commentManager: CommentManager
        private var scrollMonitor: Any?
        private weak var pdfView: StablePDFView?
        private var lastKnownScale: CGFloat?

        init(pdfManager: PDFManager, annotationManager: AnnotationManager, commentManager: CommentManager) {
            self.pdfManager = pdfManager
            self.annotationManager = annotationManager
            self.commentManager = commentManager
            super.init()
        }

        func setupScrollMonitor(for pdfView: StablePDFView) {
            self.pdfView = pdfView

            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak pdfView] event in
                guard let self = self,
                      let pdfView = pdfView,
                      event.modifierFlags.contains(.control) else {
                    return event
                }

                return self.handleZoomScroll(event: event, pdfView: pdfView)
            }
        }

        private func handleZoomScroll(event: NSEvent, pdfView: StablePDFView) -> NSEvent? {
            // Check if mouse is over the PDF view
            let mouseLocation = NSEvent.mouseLocation
            guard let window = pdfView.window else { return event }

            let windowPoint = window.convertPoint(fromScreen: mouseLocation)
            let pointInView = pdfView.convert(windowPoint, from: nil)

            guard pdfView.bounds.contains(pointInView) else {
                return event
            }

            // Disable auto-scaling when manually zooming
            pdfView.autoScales = false
            self.pdfManager.isAutoScaling = false

            // Calculate new scale
            let delta = event.scrollingDeltaY
            guard delta != 0 else { return nil }

            let oldScale = pdfView.scaleFactor
            let zoomFactor: CGFloat = 1.1  // 10% per scroll
            var newScale: CGFloat

            if delta > 0 {
                // Zoom in
                newScale = oldScale * zoomFactor
            } else {
                // Zoom out
                newScale = oldScale / zoomFactor
            }

            // Clamp to min/max
            newScale = max(DesignTokens.pdfMinScale, min(newScale, DesignTokens.pdfMaxScale))

            guard newScale != oldScale else { return nil }

            // Find the page at cursor location
            guard let page = pdfView.page(for: pointInView, nearest: true) else {
                pdfView.scaleFactor = newScale
                self.pdfManager.scaleFactor = newScale
                return nil
            }

            // Convert view point to page coordinates
            let pointInPage = pdfView.convert(pointInView, to: page)

            // Apply the new scale
            pdfView.scaleFactor = newScale

            // Convert the page point back to view coordinates (now scaled)
            let pointInViewAfterZoom = pdfView.convert(pointInPage, from: page)

            // Calculate the offset
            let offsetX = pointInViewAfterZoom.x - pointInView.x
            let offsetY = pointInViewAfterZoom.y - pointInView.y

            // Get current scroll position
            guard let scrollView = pdfView.documentScrollView else {
                self.pdfManager.scaleFactor = newScale
                return nil
            }

            let visibleRect = scrollView.documentVisibleRect

            // Adjust scroll to keep point under cursor
            let newOrigin = NSPoint(
                x: visibleRect.origin.x + offsetX,
                y: visibleRect.origin.y + offsetY
            )

            scrollView.contentView.setBoundsOrigin(newOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)

            self.pdfManager.scaleFactor = newScale

            return nil
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
    }
}
