//
//  PDFManager.swift
//  PageFlow
//
//  Manages PDF document state, navigation, and operations
//

import Foundation
import AppKit
import PDFKit
import Observation

enum InteractionMode {
    case select
    case pan
}

enum DocumentLoadResult {
    case success
    case failed
    case needsPassword
}

@Observable
class PDFManager {
    // MARK: - Properties

    var document: PDFDocument?
    var currentPage: PDFPage?
    var currentPageIndex: Int = 0
    var scaleFactor: CGFloat = 1.0
    var isAutoScaling: Bool = false
    var scaleNeedsUpdate: Bool = false
    var fitOnceRequested: Bool = false
    var documentURL: URL?
    var isDirty: Bool = false
    var interactionMode: InteractionMode = .select
    var displayMode: PDFDisplayMode = .singlePageContinuous
    
    // Weak reference to the active PDFView to support PDFThumbnailView linking
    weak var activePDFView: PDFView?

    // Password-protected PDF state
    var pendingLockedDocument: PDFDocument?
    var pendingLockedURL: URL?
    var pendingIsSecurityScoped: Bool = false

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

    func loadDocument(from url: URL, isSecurityScoped: Bool = false) -> DocumentLoadResult {
        guard url.pathExtension.lowercased() == "pdf" else {
            return .failed
        }

        stopAccessingCurrentResource()
        clearPendingLockedDocument()

        guard startAccessingResourceIfNeeded(url, isSecurityScoped: isSecurityScoped) else {
            return .failed
        }

        guard let pdfDocument = PDFDocument(url: url) else {
            stopAccessingResourceOnFailure(url, wasSecurityScoped: isSecurityScoped)
            return .failed
        }

        // Check if document is locked (password-protected)
        if pdfDocument.isLocked {
            pendingLockedDocument = pdfDocument
            pendingLockedURL = url
            pendingIsSecurityScoped = isSecurityScoped
            return .needsPassword
        }

        finalizeDocumentLoad(pdfDocument, url: url)
        return .success
    }

    func unlockDocument(password: String) -> Bool {
        guard let pdfDocument = pendingLockedDocument,
              let url = pendingLockedURL else {
            return false
        }

        guard pdfDocument.unlock(withPassword: password) else {
            return false
        }

        finalizeDocumentLoad(pdfDocument, url: url)
        clearPendingLockedDocument()
        return true
    }

    func cancelPendingUnlock() {
        if pendingIsSecurityScoped, let url = pendingLockedURL {
            url.stopAccessingSecurityScopedResource()
        }
        clearPendingLockedDocument()
    }

    private func clearPendingLockedDocument() {
        pendingLockedDocument = nil
        pendingLockedURL = nil
        pendingIsSecurityScoped = false
    }

    private func finalizeDocumentLoad(_ pdfDocument: PDFDocument, url: URL) {
        document = pdfDocument
        documentURL = url
        currentPageIndex = 0
        currentPage = pdfDocument.page(at: 0)
        isAutoScaling = false
        fitOnceRequested = true
        scaleNeedsUpdate = false
        scaleFactor = DesignTokens.pdfDefaultScale
        isDirty = false
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
        isDirty = false
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
        isAutoScaling = false
        scaleFactor = min(scaleFactor + DesignTokens.pdfZoomStep, DesignTokens.pdfMaxScale)
        scaleNeedsUpdate = true
    }

    func zoomOut() {
        isAutoScaling = false
        scaleFactor = max(scaleFactor - DesignTokens.pdfZoomStep, DesignTokens.pdfMinScale)
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
        scaleNeedsUpdate = true
    }

    func requestFitOnce() {
        isAutoScaling = false
        fitOnceRequested = true
    }

    func rotateClockwise() {
        applyRotation(delta: 90, actionName: "Rotate Page")
    }

    func rotateCounterClockwise() {
        applyRotation(delta: -90, actionName: "Rotate Page")
    }

    private func applyRotation(delta: Int, actionName: String) {
        guard let page = currentPage else { return }

        let oldRotation = page.rotation
        let newRotation = (oldRotation + delta + 360) % 360
        page.rotation = newRotation
        isDirty = true

        if let undoManager = NSApp.keyWindow?.undoManager {
            undoManager.registerUndo(withTarget: self) { target in
                target.applyRotation(delta: oldRotation - newRotation, actionName: actionName)
            }
            undoManager.setActionName(actionName)
        }
    }

    // MARK: - Outline

    func outlineItems() -> [OutlineItem] {
        guard let root = document?.outlineRoot else { return [] }

        var items: [OutlineItem] = []
        let childCount = root.numberOfChildren
        if childCount > 0 {
            for index in 0..<childCount {
                guard let child = root.child(at: index),
                      let item = OutlineItem(outline: child, path: "root-\(index)") else { continue }
                items.append(item)
            }
        }
        return items
    }

    // MARK: - Save

    func save() -> Bool {
        guard let document = document,
              let url = documentURL else {
            return false
        }

        guard let data = document.dataRepresentation() else {
            return false
        }

        do {
            try data.write(to: url)
            isDirty = false
            return true
        } catch {
            return false
        }
    }

    func saveAs(to url: URL) -> Bool {
        guard let document = document else {
            return false
        }

        guard let data = document.dataRepresentation() else {
            return false
        }

        do {
            try data.write(to: url)
            stopAccessingCurrentResource()
            documentURL = url
            isDirty = false
            return true
        } catch {
            return false
        }
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
