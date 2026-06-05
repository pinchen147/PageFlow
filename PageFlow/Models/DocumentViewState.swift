//
//  DocumentViewState.swift
//  PageFlow
//
//  Persisted per-document reading state: where the user left off (page + exact
//  scroll point) and their zoom. Restored when a document is reopened, so the
//  reader lands back exactly where they were across tab switches and relaunches.
//

import Foundation

struct DocumentViewState: Codable, Equatable {
    /// Index of the page the user was viewing.
    var pageIndex: Int
    /// Zoom factor in effect when the state was captured.
    var scaleFactor: CGFloat
    /// Whether PDFKit's Auto-Scale (fit-on-resize) mode was active.
    var isAutoScaling: Bool
    /// Exact scroll point within the page, in PDF page space. `nil` means
    /// page-level only (restore the page, but at its top).
    var scrollPoint: CGPoint?
}
