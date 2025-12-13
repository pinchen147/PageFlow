//
//  PDFThumbnailViewWrapper.swift
//  PageFlow
//
//  SwiftUI wrapper for PDFKit's PDFThumbnailView.
//

import SwiftUI
import PDFKit

struct PDFThumbnailViewWrapper: NSViewRepresentable {
    @Bindable var pdfManager: PDFManager

    func makeNSView(context: Context) -> PDFThumbnailView {
        let thumbnailView = PDFThumbnailView()
        thumbnailView.backgroundColor = DesignTokens.viewerBackground

        let width = DesignTokens.sidebarWidth - (DesignTokens.spacingMD * 2)
        // Approx A4 ratio (1:1.414)
        thumbnailView.thumbnailSize = CGSize(width: width, height: width * 1.414)

        configureScrollView(in: thumbnailView)

        return thumbnailView
    }

    func updateNSView(_ thumbnailView: PDFThumbnailView, context: Context) {
        // Link to the active main PDFView to enable bi-directional sync
        if thumbnailView.pdfView == nil, let mainPDFView = pdfManager.activePDFView {
            thumbnailView.pdfView = mainPDFView
        }

        if thumbnailView.backgroundColor != DesignTokens.viewerBackground {
            thumbnailView.backgroundColor = DesignTokens.viewerBackground
        }

        configureScrollView(in: thumbnailView)
    }

    private func configureScrollView(in thumbnailView: PDFThumbnailView) {
        guard let scrollView = findScrollView(in: thumbnailView) else { return }

        // Auto-hide scrollers when content fits
        scrollView.autohidesScrollers = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        // Center content horizontally
        scrollView.contentView.postsBoundsChangedNotifications = true
        if let documentView = scrollView.documentView {
            documentView.frame.origin.x = max(0, (scrollView.bounds.width - documentView.bounds.width) / 2)
        }
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? NSScrollView {
                return scrollView
            }
            if let found = findScrollView(in: subview) {
                return found
            }
        }
        return nil
    }
}
