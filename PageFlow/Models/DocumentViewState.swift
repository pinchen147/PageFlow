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
    /// The PDF display mode (`PDFDisplayMode.rawValue`: single or two pages,
    /// paged or continuous). `nil` for non-PDF entries and older records.
    var pdfDisplayMode: Int? = nil
    /// Markdown reading position (D7): the UTF-16 offset of the paragraph at
    /// the top of the viewport and how far below the viewport's top edge that
    /// paragraph starts — a location, so it survives a reflow (font, width,
    /// zoom, an edit above). `nil` for PDF entries and for records written
    /// before the fields existed.
    var markdownAnchorOffset: Int? = nil
    var markdownOffsetInViewport: CGFloat? = nil
    /// Markdown visual zoom (NSScrollView magnification; 1.0 = 100%). `nil` for
    /// PDF entries and older records.
    var markdownScaleFactor: CGFloat? = nil
    /// Width Fit is recomputed for the destination viewport; nil records remain manual.
    var markdownIsWidthFitted: Bool? = nil
    /// View-only Markdown table column widths (the reference editor's Set column width
    /// and column resize; the file has no place for them): per table key, one
    /// width per column, nil for Auto.
    var markdownTableColumnWidths: [String: [Double?]]? = nil
    /// EPUB reading position in the book's joined UTF-16 text. Kept so records
    /// written before the full reader state existed still restore.
    var epubCharacterOffset: Int? = nil
    /// Full EPUB reader state: location, reading mode, typography, bookmarks.
    /// `nil` for non-EPUB entries and for records written before it existed.
    var epubReaderState: EPUBPersistedReaderState? = nil

    /// The keys this build writes. `DocumentStateStore` replaces exactly these
    /// on a save and keeps every other key of a stored record verbatim, so a
    /// field a newer build added survives a round trip through this one.
    static let knownKeys: Set<String> = [
        "pageIndex", "scaleFactor", "isAutoScaling", "scrollPoint", "pdfDisplayMode",
        "markdownAnchorOffset", "markdownOffsetInViewport", "markdownScaleFactor", "markdownIsWidthFitted", "markdownTableColumnWidths",
        "epubCharacterOffset", "epubReaderState"
    ]

    /// A Markdown document's state: reading position + visual zoom are
    /// meaningful; the PDF fields hold neutral values.
    static func markdown(anchorOffset: Int?, offsetInViewport: CGFloat?, scaleFactor: CGFloat = 1, isWidthFitted: Bool? = nil,
                         tableColumnWidths: [String: [Double?]]? = nil) -> DocumentViewState {
        DocumentViewState(
            pageIndex: 0,
            scaleFactor: 1,
            isAutoScaling: false,
            scrollPoint: nil,
            markdownAnchorOffset: anchorOffset,
            markdownOffsetInViewport: offsetInViewport,
            markdownScaleFactor: scaleFactor,
            markdownIsWidthFitted: isWidthFitted,
            markdownTableColumnWidths: tableColumnWidths?.isEmpty == true ? nil : tableColumnWidths
        )
    }

    /// An EPUB document's state: the full reader state is meaningful; the PDF
    /// and Markdown fields hold neutral values.
    static func epub(_ readerState: EPUBPersistedReaderState) -> DocumentViewState {
        DocumentViewState(
            pageIndex: 0,
            scaleFactor: 1,
            isAutoScaling: false,
            scrollPoint: nil,
            epubReaderState: readerState
        )
    }

}
