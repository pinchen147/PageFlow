//
//  PDFDocumentScroll.swift
//  PageFlow
//
//  Clip-view arithmetic for PDFKit's document view, written for either
//  orientation. PDFKit on macOS 26 lays the document out bottom-up (its
//  document view is unflipped, so the first page sits at the largest y); a
//  PDFKit that flips it must not turn "the top" into the last page, nor
//  invert a pan or a zoom anchor.
//

import AppKit

enum PDFDocumentScroll {
    /// The clip origin y that shows the top of the document.
    static func topOriginY(documentHeight: CGFloat, clipHeight: CGFloat, isFlipped: Bool) -> CGFloat {
        isFlipped ? 0 : max(0, documentHeight - clipHeight)
    }

    /// How far the clip origin moves so the page under the pointer follows a
    /// drag from `start` to `end` (both in `view`'s coordinates).
    static func panDelta(from start: NSPoint, to end: NSPoint, in view: NSView, documentView: NSView) -> NSPoint {
        let a = documentView.convert(start, from: view)
        let b = documentView.convert(end, from: view)
        return NSPoint(x: a.x - b.x, y: a.y - b.y)
    }

    /// How far the clip origin moves so a page point that a zoom carried to
    /// `pageAfterZoom` comes back under the pointer at `pointer` (both in
    /// `view`'s coordinates, read after the zoom).
    static func zoomAnchorDelta(pointer: NSPoint, pageAfterZoom: NSPoint, in view: NSView, documentView: NSView) -> NSPoint {
        let underPointer = documentView.convert(pointer, from: view)
        let page = documentView.convert(pageAfterZoom, from: view)
        return NSPoint(x: page.x - underPointer.x, y: page.y - underPointer.y)
    }
}
