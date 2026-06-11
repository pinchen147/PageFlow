//
//  OutlineItemTests.swift
//  PageFlowTests
//
//  Section-boundary rules for outline items: next-sibling linking at
//  construction (`buildRoot`) and the page range it produces.
//

import AppKit
import PDFKit
import Testing
@testable import PageFlow

@MainActor
struct OutlineItemTests {

    // MARK: - Fixtures

    /// An outline root whose children point at the given page indices
    /// (nil = an entry without a destination).
    private func makeOutlineRoot(in document: PDFDocument, pages: [Int?]) -> PDFOutline {
        let root = PDFOutline()
        for (index, pageIndex) in pages.enumerated() {
            let child = PDFOutline()
            child.label = "Section \(index)"
            if let pageIndex, let page = document.page(at: pageIndex) {
                child.destination = PDFDestination(page: page, at: NSPoint(x: 0, y: 0))
            }
            root.insertChild(child, at: index)
        }
        return root
    }

    // MARK: - Sibling linking

    @Test
    func buildRootLinksEachItemToNextSiblingPage() {
        let document = makeTestDocument(pageCount: 10)
        let root = makeOutlineRoot(in: document, pages: [0, 4, 7])

        let items = OutlineItem.buildRoot(from: root)

        #expect(items.map(\.pageIndex) == [0, 4, 7])
        #expect(items.map(\.nextSiblingPageIndex) == [4, 7, nil])
    }

    @Test
    func nestedChildrenLinkWithinTheirOwnSiblingArray() {
        let document = makeTestDocument(pageCount: 10)
        let root = PDFOutline()
        let parent = PDFOutline()
        parent.label = "Chapter"
        if let page = document.page(at: 0) {
            parent.destination = PDFDestination(page: page, at: NSPoint(x: 0, y: 0))
        }
        for (index, pageIndex) in [1, 3, 6].enumerated() {
            let child = PDFOutline()
            child.label = "Sub \(index)"
            if let page = document.page(at: pageIndex) {
                child.destination = PDFDestination(page: page, at: NSPoint(x: 0, y: 0))
            }
            parent.insertChild(child, at: index)
        }
        root.insertChild(parent, at: 0)

        let items = OutlineItem.buildRoot(from: root)

        #expect(items[0].children?.map(\.nextSiblingPageIndex) == [3, 6, nil])
    }

    // MARK: - Page range

    @Test
    func sectionRangeEndsAtNextSibling() {
        let document = makeTestDocument(pageCount: 10)
        let items = OutlineItem.buildRoot(from: makeOutlineRoot(in: document, pages: [0, 4, 7]))

        #expect(items[0].pageRange(in: document) == 0..<4)
        #expect(items[1].pageRange(in: document) == 4..<7)
    }

    @Test
    func lastSectionRunsToEndOfDocument() {
        let document = makeTestDocument(pageCount: 10)
        let items = OutlineItem.buildRoot(from: makeOutlineRoot(in: document, pages: [0, 4, 7]))

        #expect(items[2].pageRange(in: document) == 7..<10)
    }

    @Test
    func nextSiblingWithoutDestinationFallsBackToDocumentEnd() {
        let document = makeTestDocument(pageCount: 10)
        let items = OutlineItem.buildRoot(from: makeOutlineRoot(in: document, pages: [2, nil, 8]))

        // A sibling without a page can't bound the section — the rule looks
        // only at the immediate next sibling, never further ahead.
        #expect(items[0].nextSiblingPageIndex == nil)
        #expect(items[0].pageRange(in: document) == 2..<10)
    }

    @Test
    func outOfOrderNextSiblingFallsBackToDocumentEnd() {
        let document = makeTestDocument(pageCount: 10)
        let items = OutlineItem.buildRoot(from: makeOutlineRoot(in: document, pages: [5, 2]))

        // The `nextPage > start` guard: a sibling pointing backwards can't
        // produce an inverted range.
        #expect(items[0].pageRange(in: document) == 5..<10)
    }

    @Test
    func itemWithoutPageYieldsEmptyRange() {
        let document = makeTestDocument(pageCount: 10)
        let items = OutlineItem.buildRoot(from: makeOutlineRoot(in: document, pages: [nil, 3]))

        #expect(items[0].pageRange(in: document) == 0..<0)
    }
}
