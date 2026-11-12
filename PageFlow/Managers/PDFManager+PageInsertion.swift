//
//  PDFManager+PageInsertion.swift
//  PageFlow
//
//  Insert Blank Page and Insert Pages from File. Every insertion is one
//  Undo step that removes exactly the pages it added.
//

import Foundation
import PDFKit

/// Why pages from another PDF were or weren't inserted.
enum PageInsertionResult: Equatable {
    case inserted(count: Int)
    /// Not a PDF, empty, or unreadable.
    case unreadable
    /// The source needs a password.
    case locked
    /// The source forbids copying its contents.
    case restricted
    /// This document can't take pages (no document, permission, bad index).
    case refused
}

extension PDFManager {

    /// Pages can be added to the open document.
    var canInsertPages: Bool { hasDocument && permissions.editPages }

    /// Inserts a blank page after `index`, with that page's size and rotation.
    @discardableResult
    func insertBlankPage(after index: Int) -> Bool {
        guard canInsertPages, let template = page(at: index) else { return false }
        let blank = PDFPage()
        blank.setBounds(template.bounds(for: .mediaBox), for: .mediaBox)
        blank.setBounds(template.bounds(for: .cropBox), for: .cropBox)
        blank.rotation = template.rotation
        return insertPages([blank], at: index + 1, actionName: "Insert Blank Page")
    }

    /// Inserts every page of the PDF at `url` after `index`. Reads the file
    /// inside its security scope, so a panel-granted URL stays usable.
    func insertPages(contentsOf url: URL, after index: Int) -> PageInsertionResult {
        guard canInsertPages, page(at: index) != nil else { return .refused }
        guard let source = Self.insertionSource(at: url) else { return .unreadable }
        return insertPages(from: source, after: index)
    }

    /// The PDF at `url`, read whole inside its security scope (a URL-backed
    /// PDFDocument reads lazily, after the scope ends). Nil when unreadable;
    /// a password-protected one comes back locked.
    static func insertionSource(at url: URL) -> PDFDocument? {
        let scoped = url.startAccessingSecurityScopedResource()
        let data = try? Data(contentsOf: url)
        if scoped { url.stopAccessingSecurityScopedResource() }
        return data.flatMap(PDFDocument.init(data:))
    }

    /// Inserts every page of `source` after `index`, keeping their sizes,
    /// rotation and annotations independently of the source document.
    func insertPages(from source: PDFDocument, after index: Int) -> PageInsertionResult {
        guard canInsertPages, page(at: index) != nil else { return .refused }
        guard !source.isLocked else { return .locked }
        guard source.allowsCopying else { return .restricted }
        let pages = (0..<source.pageCount).compactMap { source.page(at: $0)?.copy() as? PDFPage }
        guard !pages.isEmpty, pages.count == source.pageCount else { return .unreadable }
        let actionName = pages.count == 1 ? "Insert Page" : "Insert Pages"
        return insertPages(pages, at: index + 1, actionName: actionName)
            ? .inserted(count: pages.count) : .refused
    }

    // MARK: - Shared insertion (one Undo step)

    /// Inserts `pages` at `index` as one Undo step; the first becomes current.
    func insertPages(_ pages: [PDFPage], at index: Int, actionName: String) -> Bool {
        guard permissions.editPages, let document, !pages.isEmpty,
              index >= 0, index <= document.pageCount else { return false }

        let countBefore = document.pageCount
        for (offset, page) in pages.enumerated() {
            document.insert(page, at: index + offset)
        }
        // PDFKit doesn't report a refused insert; undo a partial one.
        guard document.pageCount == countBefore + pages.count else {
            for page in pages {
                let inserted = document.index(for: page)
                if inserted != NSNotFound { document.removePage(at: inserted) }
            }
            return false
        }

        isDirty = true
        currentPageIndex = index
        currentPage = document.page(at: index)
        pageVersion += 1
        markThumbnailStructureDirty()
        for offset in pages.indices {
            pageMutationHandler?(.inserted(at: index + offset))
        }

        if let undoManager = getUndoManager(for: actionName) {
            undoManager.registerUndo(withTarget: self) { target in
                target.removeInsertedPages(at: index, count: pages.count, actionName: actionName)
            }
            undoManager.setActionName(actionName)
        }
        return true
    }

    /// Undo of `insertPages`: removes them and lands on the page before.
    private func removeInsertedPages(at index: Int, count: Int, actionName: String) {
        guard permissions.editPages, let document, count > 0, index >= 0,
              index + count <= document.pageCount, document.pageCount > count else { return }

        let pages = (index..<index + count).compactMap { document.page(at: $0) }
        guard pages.count == count else { return }
        for offset in (0..<count).reversed() {
            document.removePage(at: index + offset)
        }

        isDirty = true
        currentPageIndex = min(max(index - 1, 0), document.pageCount - 1)
        currentPage = document.page(at: currentPageIndex)
        pageVersion += 1
        markThumbnailStructureDirty()
        for offset in (0..<count).reversed() {
            pageMutationHandler?(.deleted(at: index + offset))
        }

        if let undoManager = getUndoManager(for: actionName) {
            undoManager.registerUndo(withTarget: self) { target in
                _ = target.insertPages(pages, at: index, actionName: actionName)
            }
            undoManager.setActionName(actionName)
        }
    }
}
