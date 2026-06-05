//
//  PDFViewStateTests.swift
//  PageFlowTests
//
//  Exercises the PDF View State seam through PDFManager's interface: the zoom/fit
//  commands that set desired state, the ingest reducers that fold view events back,
//  and the projector's relative-tolerance scale comparison. None of these needs a
//  live window or PDFView — the interface is the test surface.
//

import AppKit
import CoreGraphics
import PDFKit
import SwiftUI
import Testing
@testable import PageFlow

@MainActor
struct PDFViewStateTests {

    // MARK: - scalesDiffer (the projector's relative-tolerance comparison)

    @Test
    func scalesDifferIgnoresSubHalfPercentChange() {
        #expect(PDFViewWrapper.scalesDiffer(1.0, 1.0) == false)
        #expect(PDFViewWrapper.scalesDiffer(1.004, 1.0) == false)   // 0.4% — PDFKit re-rounding
    }

    @Test
    func scalesDifferDetectsMeaningfulChange() {
        #expect(PDFViewWrapper.scalesDiffer(1.10, 1.0))             // 10%
        #expect(PDFViewWrapper.scalesDiffer(2.02, 2.0))            // 1%
    }

    // MARK: - Zoom commands set desired state (source of truth)

    @Test
    func zoomInStepsClampsAndClearsAutoScaleAndFit() {
        let manager = PDFManager()
        manager.scaleFactor = 1.0
        manager.isAutoScaling = true
        manager.pendingFit = FitRequest(scrollToTop: true)

        manager.zoomIn()

        #expect(manager.scaleFactor == 1.0 + DesignTokens.pdfZoomStep)
        #expect(manager.isAutoScaling == false)
        #expect(manager.pendingFit == nil)
    }

    @Test
    func zoomInClampsToMaxAndZoomOutToMin() {
        let manager = PDFManager()
        manager.scaleFactor = DesignTokens.pdfMaxScale
        manager.zoomIn()
        #expect(manager.scaleFactor == DesignTokens.pdfMaxScale)

        manager.scaleFactor = DesignTokens.pdfMinScale
        manager.zoomOut()
        #expect(manager.scaleFactor == DesignTokens.pdfMinScale)
    }

    @Test
    func setZoomClampsBothEndsAndClearsAutoScaleAndFit() {
        let manager = PDFManager()
        manager.isAutoScaling = true
        manager.pendingFit = FitRequest(scrollToTop: false)

        manager.setZoom(99)
        #expect(manager.scaleFactor == DesignTokens.pdfMaxScale)
        #expect(manager.isAutoScaling == false)
        #expect(manager.pendingFit == nil)

        manager.setZoom(-5)
        #expect(manager.scaleFactor == DesignTokens.pdfMinScale)
    }

    @Test
    func resetZoomReturnsToDefaultAndClearsFit() {
        let manager = PDFManager()
        manager.scaleFactor = 2.5
        manager.pendingFit = FitRequest(scrollToTop: true)
        manager.resetZoom()
        #expect(manager.scaleFactor == DesignTokens.pdfDefaultScale)
        #expect(manager.pendingFit == nil)
    }

    // MARK: - Fit requests

    @Test
    func requestFitOnceArmsTransientFitWithoutScrollToTop() {
        let manager = PDFManager()
        manager.isAutoScaling = true
        manager.requestFitOnce()
        #expect(manager.pendingFit == FitRequest(scrollToTop: false))
        #expect(manager.isAutoScaling == false)
    }

    @Test
    func toggleAutoScaleFlipsModeAndClearsFit() {
        let manager = PDFManager()
        manager.pendingFit = FitRequest(scrollToTop: true)
        #expect(manager.isAutoScaling == false)

        manager.toggleAutoScale()
        #expect(manager.isAutoScaling == true)
        #expect(manager.pendingFit == nil)

        manager.toggleAutoScale()
        #expect(manager.isAutoScaling == false)
    }

    // MARK: - Ingest (view event -> manager); no-op when already matching

    @Test
    func ingestScaleChangeUpdatesOnlyWhenDifferent() {
        let manager = PDFManager()
        manager.scaleFactor = 1.0

        manager.ingestScaleChange(1.0)
        #expect(manager.scaleFactor == 1.0)

        manager.ingestScaleChange(2.0)
        #expect(manager.scaleFactor == 2.0)
    }

    @Test
    func ingestDisplayModeChangeAdoptsViewMode() {
        let manager = PDFManager()
        manager.displayMode = .singlePageContinuous
        manager.ingestDisplayModeChange(.twoUp)
        #expect(manager.displayMode == .twoUp)
    }

    @Test
    func ingestPageChangeUpdatesIndexAndPage() throws {
        let document = makeDocument(pageCount: 3)
        let manager = PDFManager()
        manager.document = document
        manager.currentPageIndex = 0
        manager.currentPage = document.page(at: 0)

        let target = try #require(document.page(at: 2))
        manager.ingestPageChange(index: 2, page: target)

        #expect(manager.currentPageIndex == 2)
        #expect(manager.currentPage === target)
    }

    // MARK: - Document load arms a scroll-to-top fit

    @Test
    func finalizeDocumentLoadArmsScrollToTopFit() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let url = tempDirectory.appendingPathComponent("doc.pdf")
        #expect(makeDocument(pageCount: 2).write(to: url))

        let manager = PDFManager()
        let result = manager.loadDocument(from: url)

        guard case .success = result else {
            Issue.record("Expected the document to load successfully.")
            return
        }
        #expect(manager.pendingFit == FitRequest(scrollToTop: true))
        #expect(manager.scaleFactor == DesignTokens.pdfDefaultScale)
        #expect(manager.isAutoScaling == false)
    }

    // MARK: - Helpers

    private func makeDocument(pageCount: Int) -> PDFDocument {
        let document = PDFDocument()
        for index in 0..<pageCount {
            let image = NSImage(size: NSSize(width: 32, height: 32))
            image.lockFocus()
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 32, height: 32)).fill()
            image.unlockFocus()
            guard let page = PDFPage(image: image) else {
                fatalError("Failed to create PDF page from test image.")
            }
            document.insert(page, at: index)
        }
        return document
    }
}
