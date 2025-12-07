//
//  PDFViewWrapper.swift
//  PageFlow
//
//  SwiftUI wrapper for PDFKit's PDFView
//

import SwiftUI
import PDFKit

struct PDFViewWrapper: NSViewRepresentable {
    @Bindable var pdfManager: PDFManager

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()

        // Configure PDFView
        pdfView.wantsLayer = true
        pdfView.layer?.isOpaque = true
        pdfView.layer?.backgroundColor = NSColor.black.cgColor
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = NSColor.black

        // Set delegate
        pdfView.delegate = context.coordinator

        // Observe page changes
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )

        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        // Update document if changed
        if pdfView.document !== pdfManager.document {
            pdfView.document = pdfManager.document

            // When document changes, explicitly go to the current page
            if let currentPage = pdfManager.currentPage {
                pdfView.go(to: currentPage)
            }
        } else {
            // Document hasn't changed, but page might have
            if let currentPage = pdfManager.currentPage,
               pdfView.currentPage != currentPage {
                pdfView.go(to: currentPage)
            }
        }

        // Update scale factor if changed
        if pdfView.scaleFactor != pdfManager.scaleFactor {
            pdfView.scaleFactor = pdfManager.scaleFactor
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(pdfManager: pdfManager)
    }

    static func dismantleNSView(_ pdfView: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(
            coordinator,
            name: .PDFViewPageChanged,
            object: pdfView
        )
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
        }

        // PDFViewDelegate methods can be added here for future features
        // e.g., func pdfViewWillClick(onLink sender: PDFView, with url: URL)
    }
}
