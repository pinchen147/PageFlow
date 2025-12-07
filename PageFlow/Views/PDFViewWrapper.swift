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

        return pdfView
    }

    func updateNSView(_ pdfView: StablePDFView, context: Context) {
        if pdfView.document !== pdfManager.document {
            pdfView.document = pdfManager.document

            if let currentPage = pdfManager.currentPage {
                pdfView.go(to: currentPage)
            }

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
    }

    // MARK: - Private

    private func applyInitialScale(to pdfView: StablePDFView) {
        let fitScale = pdfView.scaleFactorForSizeToFit
        let isDefaultScale = pdfManager.scaleFactor == DesignTokens.pdfDefaultScale
        let targetScale = isDefaultScale ? fitScale : pdfManager.scaleFactor

        pdfView.scaleFactor = targetScale

        if pdfManager.scaleFactor != targetScale {
            pdfManager.scaleFactor = targetScale
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, PDFViewDelegate {
        let pdfManager: PDFManager

        init(pdfManager: PDFManager) {
            self.pdfManager = pdfManager
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
