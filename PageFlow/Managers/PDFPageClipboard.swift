//
//  PDFPageClipboard.swift
//  PageFlow
//
//  The app-wide page clipboard behind Copy, Cut and Paste Page, so a page
//  copied in one PDF can be pasted into another.
//

import Foundation
import Observation
import PDFKit

/// Holds the copied page as a one-page PDF. Each paste reads a fresh page
/// from that data, so no page object is ever shared between documents.
@Observable
@MainActor
final class PDFPageClipboard {
    static let shared = PDFPageClipboard()

    private var pageData: Data?

    var hasPage: Bool { pageData != nil }

    /// Copies `page`, annotations included. Returns false (keeping the
    /// previous page) when the page can't be written out.
    @discardableResult
    func copy(_ page: PDFPage) -> Bool {
        guard let copy = page.copy() as? PDFPage else { return false }
        let holder = PDFDocument()
        holder.insert(copy, at: 0)
        guard holder.pageCount == 1, let data = holder.dataRepresentation() else { return false }
        pageData = data
        return true
    }

    /// A new page made from the copied one, owned by no open document.
    func makePage() -> PDFPage? {
        guard let pageData, let document = PDFDocument(data: pageData) else { return nil }
        // PDFKit can inspect the pasted page after the temporary document is released.
        return document.page(at: 0)?.copy() as? PDFPage
    }

    func clear() {
        pageData = nil
    }
}
