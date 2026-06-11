//
//  PDFTestFixtures.swift
//  PageFlowTests
//
//  Shared document fixture for suites that need a real multi-page PDF.
//

import AppKit
import PDFKit

/// An N-page document with image-backed pages, so `page.copy()` (used by
/// paste/duplicate) succeeds and the pages carry real media boxes.
@MainActor
func makeTestDocument(pageCount: Int) -> PDFDocument {
    let document = PDFDocument()
    for index in 0..<pageCount {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 32, height: 32)).fill()
        image.unlockFocus()
        guard let page = PDFPage(image: image) else {
            fatalError("Failed to create test PDF page.")
        }
        document.insert(page, at: index)
    }
    return document
}
