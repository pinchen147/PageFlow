//
//  PDFPermissions.swift
//  PageFlow
//

import PDFKit

/// What the open PDF's security handler permits. PDFKit silently refuses page
/// and annotation edits the document forbids, and does not enforce copying or
/// printing at all, so commands check this before recording dirty state, Undo
/// or thumbnail changes, and the UI disables what it does not allow.
struct PDFPermissions: Equatable {
    /// Add, remove and restyle annotations and comments.
    var annotate = false
    /// Rotate, insert, delete and reorder pages.
    var editPages = false
    /// Extract text or pages (copy, Markdown export, page copy).
    var copy = false
    var print = false
}

extension PDFPermissions {
    /// The narrowest permission bit for each command; a locked or absent
    /// document permits nothing.
    init(_ document: PDFDocument?) {
        guard let document, !document.isLocked else { return }
        annotate = document.allowsCommenting
        editPages = document.allowsDocumentAssembly
        copy = document.allowsCopying
        print = document.allowsPrinting
    }
}
