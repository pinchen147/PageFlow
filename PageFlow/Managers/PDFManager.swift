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
    var documentURL: URL?
    private var isAccessingSecurityScopedResource = false

    var pageCount: Int {
        document?.pageCount ?? 0
    }

    var hasDocument: Bool {
        document != nil
    }

    // MARK: - Document Loading

    func loadDocument(from url: URL, isSecurityScoped: Bool = false) -> Bool {
        // Stop accessing previous security-scoped resource if any
        if isAccessingSecurityScopedResource, let oldURL = documentURL {
            oldURL.stopAccessingSecurityScopedResource()
            isAccessingSecurityScopedResource = false
        }

        // Start accessing security-scoped resource if needed
        if isSecurityScoped {
            guard url.startAccessingSecurityScopedResource() else {
                return false
            }
            isAccessingSecurityScopedResource = true
        }

        // Load the PDF document
        guard let pdfDocument = PDFDocument(url: url) else {
            // Failed to load - stop accessing if we started
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
                isAccessingSecurityScopedResource = false
            }
            return false
        }

        document = pdfDocument
        documentURL = url
        currentPageIndex = 0
        currentPage = pdfDocument.page(at: 0)

        return true
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

    func zoomIn() {
        scaleFactor = min(scaleFactor + 0.25, 4.0)
    }

    func zoomOut() {
        scaleFactor = max(scaleFactor - 0.25, 0.25)
    }

    func resetZoom() {
        scaleFactor = 1.0
    }

    func setZoom(_ scale: CGFloat) {
        scaleFactor = max(0.25, min(scale, 4.0))
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

    // MARK: - Export

    func exportWithoutAnnotations(to url: URL) -> Bool {
        guard let document = document else {
            return false
        }

        // Create a copy of the document
        let newDocument = PDFDocument()

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }

            // Create a copy of the page without annotations
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
