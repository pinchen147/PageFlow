//
//  PDFViewWrapper.swift
//  PageFlow
//
//  SwiftUI wrapper for PDFKit's PDFView using StablePDFView for resize stability.
//

import SwiftUI
import PDFKit

struct PDFViewWrapper: NSViewRepresentable {
    @Bindable var pdfManager: PDFManager
    var searchManager: SearchManager

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
        pdfView.enableDataDetectors = true
        pdfView.delegate = context.coordinator

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )

        // Setup scroll event monitor for Ctrl+Scroll zoom
        context.coordinator.setupScrollMonitor(for: pdfView)

        return pdfView
    }

    func updateNSView(_ pdfView: StablePDFView, context: Context) {
        if pdfView.document !== pdfManager.document {
            pdfView.document = pdfManager.document

            if let currentPage = pdfManager.currentPage {
                pdfView.go(to: currentPage)
            }

            pdfView.autoScales = pdfManager.isAutoScaling
            applyInitialScale(to: pdfView)
        } else if let currentPage = pdfManager.currentPage,
                  pdfView.currentPage !== currentPage {
            pdfView.go(to: currentPage)
        }

        if pdfView.autoScales != pdfManager.isAutoScaling {
            pdfView.autoScales = pdfManager.isAutoScaling
        }

        if pdfManager.fitOnceRequested {
            let fitScale = pdfView.scaleFactorForSizeToFit
            pdfView.scaleFactor = fitScale
            pdfManager.scaleFactor = fitScale
            pdfManager.fitOnceRequested = false
        } else if pdfManager.scaleNeedsUpdate {
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
        Coordinator(pdfManager: pdfManager)
    }

    static func dismantleNSView(_ pdfView: StablePDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(
            coordinator,
            name: .PDFViewPageChanged,
            object: pdfView
        )
        coordinator.removeScrollMonitor()
    }

    // MARK: - Private

    private func applyInitialScale(to pdfView: StablePDFView) {
        let fitScale = pdfView.scaleFactorForSizeToFit
        pdfView.scaleFactor = fitScale
        pdfManager.scaleFactor = fitScale
        pdfManager.fitOnceRequested = false
        pdfManager.scaleNeedsUpdate = false
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, PDFViewDelegate {
        let pdfManager: PDFManager
        private var scrollMonitor: Any?
        private weak var pdfView: StablePDFView?

        init(pdfManager: PDFManager) {
            self.pdfManager = pdfManager
        }

        func setupScrollMonitor(for pdfView: StablePDFView) {
            self.pdfView = pdfView

            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak pdfView] event in
                guard let self = self,
                      let pdfView = pdfView,
                      event.modifierFlags.contains(.control) else {
                    return event
                }

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
    }
}
