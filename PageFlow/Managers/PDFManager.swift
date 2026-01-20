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
import os.log

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
@MainActor
final class PDFManager {
    // MARK: - Properties

    private let logger = Logger(subsystem: "com.pageflow", category: "PDFManager")

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

    /// Increments whenever pages are added/removed/reordered - triggers UI refresh
    var pageVersion: Int = 0

    /// Copied page for paste operation (same-document only)
    private(set) var copiedPage: PDFPage?
    
    // Weak reference to the active PDFView to support PDFThumbnailView linking
    weak var activePDFView: PDFView?

    // Password-protected PDF state
    var pendingLockedDocument: PDFDocument?
    var pendingLockedURL: URL?
    var pendingIsSecurityScoped: Bool = false

    // Navigation history for back/forward
    private var backStack: [NavigationEntry] = []
    private var forwardStack: [NavigationEntry] = []
    private let maxHistoryDepth = 50

    private var isAccessingSecurityScopedResource = false
    @ObservationIgnored private var securityScopedURL: URL?

    var undoManagerProvider: (() -> UndoManager?)?

    deinit {
        if let url = securityScopedURL {
            url.stopAccessingSecurityScopedResource()
        }
        #if DEBUG
        Swift.print("[deinit] PDFManager")
        #endif
    }

    private func getUndoManager(for action: String) -> UndoManager? {
        guard let undoManager = undoManagerProvider?() else {
            assertionFailure("UndoManager unavailable for: \(action)")
            return nil
        }
        return undoManager
    }

    var pageCount: Int {
        document?.pageCount ?? 0
    }

    var hasDocument: Bool {
        document != nil
    }

    /// Safe page accessor with bounds validation
    func page(at index: Int) -> PDFPage? {
        guard let document = document,
              index >= 0,
              index < document.pageCount else {
            return nil
        }
        return document.page(at: index)
    }

    /// Checks if page index is valid for current document
    func isValidPageIndex(_ index: Int) -> Bool {
        guard document != nil else { return false }
        return index >= 0 && index < pageCount
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

    var canGoBack: Bool {
        !backStack.isEmpty
    }

    var canGoForward: Bool {
        !forwardStack.isEmpty
    }

    // MARK: - Navigation History

    /// Push current position to history before navigating (call before goToPage for link/outline navigation)
    func pushNavigationState() {
        let entry = NavigationEntry(pageIndex: currentPageIndex)
        backStack.append(entry)
        if backStack.count > maxHistoryDepth {
            backStack.removeFirst()
        }
        forwardStack.removeAll()
    }

    func goBack() {
        guard let entry = backStack.popLast() else { return }
        let currentEntry = NavigationEntry(pageIndex: currentPageIndex)
        forwardStack.append(currentEntry)
        goToPageWithoutHistory(entry.pageIndex)
    }

    func goForward() {
        guard let entry = forwardStack.popLast() else { return }
        let currentEntry = NavigationEntry(pageIndex: currentPageIndex)
        backStack.append(currentEntry)
        goToPageWithoutHistory(entry.pageIndex)
    }

    /// Navigate to page without affecting history (used by goBack/goForward)
    private func goToPageWithoutHistory(_ index: Int) {
        guard let document = document,
              index >= 0,
              index < document.pageCount else {
            return
        }

        currentPageIndex = index
        currentPage = document.page(at: index)
    }

    func clearNavigationHistory() {
        backStack.removeAll()
        forwardStack.removeAll()
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
        // Clear previous document's undo actions to prevent stale references
        undoManagerProvider?()?.removeAllActions()

        document = pdfDocument
        documentURL = url
        currentPageIndex = 0
        currentPage = pdfDocument.page(at: 0)
        isAutoScaling = false
        fitOnceRequested = true
        scaleNeedsUpdate = false
        scaleFactor = DesignTokens.pdfDefaultScale
        isDirty = false
        copiedPage = nil  // Clear to prevent cross-document paste corruption
    }

    private func stopAccessingCurrentResource() {
        if isAccessingSecurityScopedResource, let oldURL = documentURL {
            oldURL.stopAccessingSecurityScopedResource()
            isAccessingSecurityScopedResource = false
            securityScopedURL = nil
        }
    }

    private func startAccessingResourceIfNeeded(_ url: URL, isSecurityScoped: Bool) -> Bool {
        guard isSecurityScoped else { return true }

        guard url.startAccessingSecurityScopedResource() else {
            return false
        }

        isAccessingSecurityScopedResource = true
        securityScopedURL = url
        return true
    }

    private func stopAccessingResourceOnFailure(_ url: URL, wasSecurityScoped: Bool) {
        if wasSecurityScoped {
            url.stopAccessingSecurityScopedResource()
            isAccessingSecurityScopedResource = false
            securityScopedURL = nil
        }
    }

    func closeDocument() {
        undoManagerProvider?()?.removeAllActions()

        if isAccessingSecurityScopedResource, let url = documentURL {
            url.stopAccessingSecurityScopedResource()
            isAccessingSecurityScopedResource = false
            securityScopedURL = nil
        }

        document = nil
        documentURL = nil
        currentPage = nil
        currentPageIndex = 0
        scaleFactor = 1.0
        isDirty = false
        copiedPage = nil
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
        guard pageCount > 0 else { return }
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
        rotatePage(at: currentPageIndex, clockwise: true)
    }

    func rotateCounterClockwise() {
        rotatePage(at: currentPageIndex, clockwise: false)
    }

    /// Rotates page at specified index - used by both toolbar and thumbnail context menu
    func rotatePage(at index: Int, clockwise: Bool) {
        guard let document = document,
              index >= 0, index < document.pageCount,
              let page = document.page(at: index) else { return }

        let delta = clockwise ? 90 : -90
        let oldRotation = page.rotation
        let newRotation = (oldRotation + delta + 360) % 360
        page.rotation = newRotation
        isDirty = true
        pageVersion += 1

        if let undoManager = getUndoManager(for: "Rotate Page") {
            undoManager.registerUndo(withTarget: self) { target in
                target.rotatePage(at: index, clockwise: !clockwise)
            }
            undoManager.setActionName("Rotate Page")
        }
    }

    // MARK: - Page Operations

    /// Whether a page is available to paste
    var canPaste: Bool { copiedPage != nil }

    /// Copies the page at the given index for later paste
    func copyPage(at index: Int) {
        guard let page = document?.page(at: index),
              let pageCopy = page.copy() as? PDFPage else { return }
        copiedPage = pageCopy
    }

    /// Cuts the page at the given index (copy + delete)
    func cutPage(at index: Int) {
        guard let document = document, document.pageCount > 1 else { return }
        copyPage(at: index)
        deletePage(at: index)
    }

    /// Pastes the copied page after the given index
    /// Returns true if paste succeeded
    func pastePage(after index: Int) -> Bool {
        guard let page = copiedPage,
              let document = document,
              index >= 0, index < document.pageCount else { return false }

        let insertIndex = index + 1
        let pageCountBefore = document.pageCount

        document.insert(page, at: insertIndex)

        // Validate insert succeeded (PDFKit doesn't report failures)
        guard document.pageCount == pageCountBefore + 1 else { return false }

        // Create new copy for future pastes (page can only be in doc once)
        guard let newCopy = page.copy() as? PDFPage else {
            // Rollback: remove the inserted page if copy fails
            document.removePage(at: insertIndex)
            return false
        }
        copiedPage = newCopy

        isDirty = true
        pageVersion += 1
        currentPageIndex = insertIndex
        currentPage = document.page(at: insertIndex)

        if let undoManager = getUndoManager(for: "Paste Page") {
            undoManager.registerUndo(withTarget: self) { target in
                target.deletePage(at: insertIndex)
            }
            undoManager.setActionName("Paste Page")
        }

        return true
    }

    func deletePage(at index: Int) {
        guard let document = document,
              document.pageCount > 1,
              index >= 0, index < document.pageCount,
              let page = document.page(at: index),
              let pageCopy = page.copy() as? PDFPage else { return }

        document.removePage(at: index)
        isDirty = true
        pageVersion += 1

        // Adjust current page if needed
        if currentPageIndex >= document.pageCount {
            currentPageIndex = document.pageCount - 1
        }
        currentPage = document.page(at: currentPageIndex)

        if let undoManager = getUndoManager(for: "Delete Page") {
            undoManager.registerUndo(withTarget: self) { target in
                target.insertPageForUndo(pageCopy, at: index)
            }
            undoManager.setActionName("Delete Page")
        }
    }

    func duplicatePage(at index: Int) {
        guard let document = document,
              let page = document.page(at: index),
              let pageCopy = page.copy() as? PDFPage else { return }

        let insertIndex = index + 1
        document.insert(pageCopy, at: insertIndex)
        isDirty = true
        pageVersion += 1

        if let undoManager = getUndoManager(for: "Duplicate Page") {
            undoManager.registerUndo(withTarget: self) { target in
                target.removePageForUndo(at: insertIndex)
            }
            undoManager.setActionName("Duplicate Page")
        }
    }

    func movePage(from sourceIndex: Int, to destinationIndex: Int) {
        guard let document = document,
              sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < document.pageCount,
              destinationIndex >= 0, destinationIndex < document.pageCount,
              let page = document.page(at: sourceIndex) else { return }

        document.removePage(at: sourceIndex)
        document.insert(page, at: destinationIndex)
        isDirty = true
        pageVersion += 1

        // Update current page index if affected
        if currentPageIndex == sourceIndex {
            currentPageIndex = destinationIndex
        } else if sourceIndex < currentPageIndex && destinationIndex >= currentPageIndex {
            currentPageIndex -= 1
        } else if sourceIndex > currentPageIndex && destinationIndex <= currentPageIndex {
            currentPageIndex += 1
        }
        currentPage = document.page(at: currentPageIndex)

        if let undoManager = getUndoManager(for: "Reorder Page") {
            undoManager.registerUndo(withTarget: self) { target in
                target.movePage(from: destinationIndex, to: sourceIndex)
            }
            undoManager.setActionName("Reorder Page")
        }
    }

    // MARK: - Page Operation Helpers (for undo/redo)

    private func insertPageForUndo(_ page: PDFPage, at index: Int) {
        guard let document = document,
              index >= 0, index <= document.pageCount else { return }

        document.insert(page, at: index)
        isDirty = true
        pageVersion += 1
        currentPageIndex = index
        currentPage = document.page(at: index)

        if let undoManager = getUndoManager(for: "Delete Page") {
            undoManager.registerUndo(withTarget: self) { target in
                target.deletePage(at: index)
            }
            undoManager.setActionName("Delete Page")
        }
    }

    private func removePageForUndo(at index: Int) {
        guard let document = document,
              document.pageCount > 1,
              let page = document.page(at: index),
              let pageCopy = page.copy() as? PDFPage else { return }

        document.removePage(at: index)
        isDirty = true
        pageVersion += 1
        if currentPageIndex >= document.pageCount {
            currentPageIndex = document.pageCount - 1
        }
        currentPage = document.page(at: currentPageIndex)

        if let undoManager = getUndoManager(for: "Duplicate Page") {
            undoManager.registerUndo(withTarget: self) { target in
                target.insertPageForUndo(pageCopy, at: index)
            }
            undoManager.setActionName("Duplicate Page")
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

    /// Async save - use for normal save operations to prevent UI freeze
    func save() async -> Bool {
        guard let document = document,
              let url = documentURL else {
            return false
        }

        // Capture references for background work
        let docRef = document
        let targetURL = url
        let log = logger

        // Perform heavy work on background thread
        let result = await Task.detached(priority: .userInitiated) {
            guard let data = docRef.dataRepresentation() else {
                return false
            }

            do {
                try data.write(to: targetURL, options: .atomic)
                return true
            } catch {
                log.error("Save failed: \(error.localizedDescription)")
                return false
            }
        }.value

        // Update state on main thread
        if result {
            isDirty = false
        }

        return result
    }

    /// Synchronous save - use only for quit-time saves where we can't await
    func saveSync() -> Bool {
        guard let document = document,
              let url = documentURL else {
            return false
        }

        guard let data = document.dataRepresentation() else {
            return false
        }

        do {
            try data.write(to: url, options: .atomic)
            isDirty = false
            return true
        } catch {
            logger.error("Sync save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Async save as - use for Save As operations
    func saveAs(to url: URL) async -> Bool {
        guard let document = document else {
            return false
        }

        // Capture references for background work
        let docRef = document
        let targetURL = url
        let log = logger

        // Perform heavy work on background thread
        let result = await Task.detached(priority: .userInitiated) {
            guard let data = docRef.dataRepresentation() else {
                return false
            }

            do {
                try data.write(to: targetURL, options: .atomic)
                return true
            } catch {
                log.error("Save As failed: \(error.localizedDescription)")
                return false
            }
        }.value

        // Update state on main thread
        if result {
            stopAccessingCurrentResource()
            documentURL = url
            isDirty = false
        }

        return result
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
