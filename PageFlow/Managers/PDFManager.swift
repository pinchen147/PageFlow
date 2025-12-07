//
//  PDFManager.swift
//  PageFlow
//
//  Manages PDF document state, navigation, and operations
//

import Foundation
import PDFKit
import Observation

@Observable
class PDFManager {
    // MARK: - Properties

    var document: PDFDocument?
    var currentPage: PDFPage?
    var currentPageIndex: Int = 0
    var scaleFactor: CGFloat = 1.0
    var isAutoScaling: Bool = false
    var scaleNeedsUpdate: Bool = false
    var documentURL: URL?
    private var isAccessingSecurityScopedResource = false

    var pageCount: Int {
        document?.pageCount ?? 0
    }

    var hasDocument: Bool {
        document != nil
    }

    var documentTitle: String {
        guard let document = document else {
            return "PageFlow"
        }

        if let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
           !title.isEmpty {
            return title
        }

        return documentURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    // MARK: - Document Loading

    func loadDocument(from url: URL, isSecurityScoped: Bool = false) -> Bool {
        guard url.pathExtension.lowercased() == "pdf" else {
            return false
        }

        stopAccessingCurrentResource()

        guard startAccessingResourceIfNeeded(url, isSecurityScoped: isSecurityScoped) else {
            return false
        }

        guard let pdfDocument = PDFDocument(url: url) else {
            stopAccessingResourceOnFailure(url, wasSecurityScoped: isSecurityScoped)
            return false
        }

        document = pdfDocument
        documentURL = url
        currentPageIndex = 0
        currentPage = pdfDocument.page(at: 0)

        return true
    }

    private func stopAccessingCurrentResource() {
        if isAccessingSecurityScopedResource, let oldURL = documentURL {
            oldURL.stopAccessingSecurityScopedResource()
            isAccessingSecurityScopedResource = false
        }
    }

    private func startAccessingResourceIfNeeded(_ url: URL, isSecurityScoped: Bool) -> Bool {
        guard isSecurityScoped else { return true }

        guard url.startAccessingSecurityScopedResource() else {
            return false
        }

        isAccessingSecurityScopedResource = true
        return true
    }

    private func stopAccessingResourceOnFailure(_ url: URL, wasSecurityScoped: Bool) {
        if wasSecurityScoped {
            url.stopAccessingSecurityScopedResource()
            isAccessingSecurityScopedResource = false
        }
    }

    func closeDocument() {
        // Stop accessing security-scoped resource if we were
        if isAccessingSecurityScopedResource, let url = documentURL {
            url.stopAccessingSecurityScopedResource()
            isAccessingSecurityScopedResource = false
        }

        document = nil
        documentURL = nil
        currentPage = nil
        currentPageIndex = 0
        scaleFactor = 1.0
    }

    // MARK: - Navigation

    func goToPage(_ index: Int) {
        guard let document = document,
              index >= 0,
              index < document.pageCount else {
            return
        }

        currentPageIndex = index
        currentPage = document.page(at: index)
    }

    func nextPage() {
        let nextIndex = currentPageIndex + 1
        guard nextIndex < pageCount else { return }
        goToPage(nextIndex)
    }

    func previousPage() {
        let previousIndex = currentPageIndex - 1
        guard previousIndex >= 0 else { return }
        goToPage(previousIndex)
    }

    func goToFirstPage() {
        goToPage(0)
    }

    func goToLastPage() {
        goToPage(pageCount - 1)
    }

    // MARK: - Zoom

    private let zoomStep: CGFloat = 0.25

    func zoomIn() {
        isAutoScaling = false
        scaleFactor = min(scaleFactor + zoomStep, DesignTokens.pdfMaxScale)
        scaleNeedsUpdate = true
    }

    func zoomOut() {
        isAutoScaling = false
        scaleFactor = max(scaleFactor - zoomStep, DesignTokens.pdfMinScale)
        scaleNeedsUpdate = true
    }

    func resetZoom() {
        isAutoScaling = false
        scaleFactor = DesignTokens.pdfDefaultScale
        scaleNeedsUpdate = true
    }

    func setZoom(_ scale: CGFloat) {
        isAutoScaling = false
        scaleFactor = max(DesignTokens.pdfMinScale, min(scale, DesignTokens.pdfMaxScale))
        scaleNeedsUpdate = true
    }

    func toggleAutoScale() {
        isAutoScaling.toggle()
    }

    // MARK: - Save

    func save() -> Bool {
        guard let document = document,
              let url = documentURL else {
            return false
        }

        return document.write(to: url)
    }

    func saveAs(to url: URL) -> Bool {
        guard let document = document else {
            return false
        }

        if document.write(to: url) {
            documentURL = url
            return true
        }

        return false
    }

    // MARK: - Print

    func print() {
        guard let document = document else { return }

        let printInfo = NSPrintInfo.shared
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = false

        guard let printOperation = document.printOperation(
            for: printInfo,
            scalingMode: .pageScaleToFit,
            autoRotate: true
        ) else {
            return
        }

        printOperation.showsPrintPanel = true
        printOperation.showsProgressPanel = true
        printOperation.runModal(for: NSApp.keyWindow ?? NSWindow(),
                               delegate: nil,
                               didRun: nil,
                               contextInfo: nil)
    }

    // MARK: - Export

    func exportWithoutAnnotations(to url: URL) -> Bool {
        guard let document = document else {
            return false
        }

        // Create a copy of the document
        let newDocument = PDFDocument()

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }

            // PDFPage.copy() always returns PDFPage, force unwrap is safe
            let pageCopy = page.copy() as! PDFPage

            // Remove all annotations
            let annotations = pageCopy.annotations
            for annotation in annotations {
                pageCopy.removeAnnotation(annotation)
            }

            newDocument.insert(pageCopy, at: pageIndex)
        }

        return newDocument.write(to: url)
    }
}
