//
//  PDFDocumentScrollTests.swift
//  PageFlowTests
//
//  A PDF opens at its top, pans with the hand and zooms around the pointer
//  whichever way PDFKit's document view runs (issue #7: on a macOS beta every
//  PDF opened on its last page).
//

import AppKit
import PDFKit
import Testing
@testable import PageFlow

@MainActor
struct PDFDocumentScrollTests {
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// A 1000 pt tall document in a 200 pt scroll view, inside a plain host view
    /// (the PDF view's place), scrolled to the middle.
    private func scroller(flipped: Bool) -> (host: NSView, scroll: NSScrollView, document: NSView) {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let scroll = NSScrollView(frame: host.bounds)
        let document: NSView = flipped ? FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
            : NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        scroll.documentView = document
        host.addSubview(scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
        scroll.reflectScrolledClipView(scroll.contentView)
        return (host, scroll, document)
    }

    @Test
    func theTopIsTheLargestOriginOnlyWhenTheDocumentRunsBottomUp() {
        #expect(PDFDocumentScroll.topOriginY(documentHeight: 4008, clipHeight: 465, isFlipped: false) == 3543)
        #expect(PDFDocumentScroll.topOriginY(documentHeight: 4008, clipHeight: 465, isFlipped: true) == 0,
                "a flipped document's top is y = 0, not its last page")
        #expect(PDFDocumentScroll.topOriginY(documentHeight: 300, clipHeight: 465, isFlipped: false) == 0)
    }

    @Test(arguments: [false, true])
    func aDragUpShowsWhatIsFurtherDownEitherWay(flipped: Bool) {
        let (host, _, document) = scroller(flipped: flipped)
        // The hand moves up 20 pt in the host's (unflipped) coordinates.
        let delta = PDFDocumentScroll.panDelta(from: NSPoint(x: 50, y: 100), to: NSPoint(x: 50, y: 120),
                                               in: host, documentView: document)
        // Further down the document is smaller y when it runs bottom-up, larger when flipped.
        #expect(delta.y == (flipped ? 20 : -20))
        #expect(delta.x == 0)
    }

    @Test(arguments: [false, true])
    func aZoomBringsThePagePointBackUnderThePointerEitherWay(flipped: Bool) {
        let (host, scroll, document) = scroller(flipped: flipped)
        // The zoom carried the page point 30 pt below the pointer (host coordinates).
        let pointer = NSPoint(x: 50, y: 100), carried = NSPoint(x: 50, y: 70)
        let pagePoint = document.convert(carried, from: host)
        let delta = PDFDocumentScroll.zoomAnchorDelta(pointer: pointer, pageAfterZoom: carried, in: host, documentView: document)
        var origin = scroll.contentView.bounds.origin
        origin.y += delta.y
        scroll.contentView.scroll(to: origin)
        // After the scroll that page point is under the pointer again.
        #expect(abs(document.convert(pagePoint, to: host).y - pointer.y) < 0.001)
        #expect(delta.y == (flipped ? 30 : -30))
    }

    @Test
    func aRealPDFOpenedAtTheTopShowsItsFirstPage() async throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for _ in 1...5 { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        let document = try #require(PDFDocument(data: data as Data))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = PDFView(frame: try #require(window.contentView).bounds)
        view.displayMode = .singlePageContinuous
        view.autoScales = true
        window.contentView = view
        view.document = document
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        let scroll = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let documentView = try #require(scroll.documentView)
        // Start from the bottom, as a stale position would leave it.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let top = PDFDocumentScroll.topOriginY(documentHeight: documentView.bounds.height,
                                               clipHeight: scroll.contentView.bounds.height,
                                               isFlipped: documentView.isFlipped)
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: top))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(nanoseconds: 200_000_000)
        let nearTop = NSPoint(x: view.bounds.midX, y: view.isFlipped ? 40 : view.bounds.maxY - 40)
        let page = try #require(view.page(for: nearTop, nearest: true))
        #expect(document.index(for: page) == 0, "PDFKit's document view here is \(documentView.isFlipped ? "flipped" : "unflipped")")
    }
}
