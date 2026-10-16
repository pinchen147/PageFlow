//
//  PDFTestFixtures.swift
//  PageFlowTests
//
//  Shared document fixtures for suites that need real PDFs.
//

import AppKit
import CoreText
import PDFKit

/// A one-page document with real selectable text — Core Text drawn into a
/// CGPDFContext, so PDFKit's text engine sees true glyphs and `findString` /
/// `selection(for:)` return live `PDFSelection`s. Fully headless: no view,
/// no display server.
@MainActor
func makeTextDocument(text: String) -> PDFDocument? {
    makeTextDocument(pages: [text])
}

/// Real selectable text on each page, in document order.
@MainActor
func makeTextDocument(pages: [String]) -> PDFDocument? {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data) else { return nil }
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

    for text in pages {
        context.beginPDFPage(nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 24)]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: mediaBox.insetBy(dx: 36, dy: 36), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        context.endPDFPage()
    }
    context.closePDF()

    return PDFDocument(data: data as Data)
}

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
