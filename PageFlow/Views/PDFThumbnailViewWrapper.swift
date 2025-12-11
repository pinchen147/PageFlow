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
    }
}
