//
//  EPUBPagination.swift
//  PageFlow
//
//  Whole-book page numbers for EPUB: each chapter split into fixed-size
//  pages, filled in chapter by chapter, with a single global page index, and
//  the table of which pages share a spread.
//

import AppKit
import EPUBKit
import Foundation

/// The book page every EPUB layout draws, in points at 100% zoom: the
/// standard sheet, or the window's size after Reflow to Fit. Page breaks
/// depend on it, never on the zoom.
nonisolated struct EPUBPageGeometry: Equatable, Sendable {
    static let standard = EPUBPageGeometry(pageSize: CGSize(width: 600, height: 900))
    /// The smallest page a reflow makes, so text always has room to set.
    static let minimumPageSize = CGSize(width: 320, height: 420)
    /// The Normal margins.
    static let margins = EPUBPageMargins.normal.insets
    /// Gap between pages, matching PDF's page breaks.
    static let pageGap: CGFloat = 16
    /// Space around a single page or spread: half of PDF's fit padding.
    static let spreadMargin: CGFloat = 10
    /// The longest a line of text runs, in ems of the body text: about 70
    /// characters. The large pages Reflow to Fit makes in a wide window keep
    /// that measure, centred, rather than lines across the whole window.
    static let measureInEms: CGFloat = 40
    /// The measure at the default text size.
    static let maxTextWidth: CGFloat = 680
    /// PDF's zoom range, 10–400%.
    static let scaleRange: ClosedRange<CGFloat> = ZoomRange.pages.bounds

    let pageSize: CGSize
    /// The longest a line of text runs on this page.
    let measure: CGFloat
    /// The reader's margins around the text.
    let margins: EPUBPageMargins

    init(pageSize: CGSize, measure: CGFloat = maxTextWidth, margins: EPUBPageMargins = .normal) {
        self.pageSize = CGSize(width: max(Self.minimumPageSize.width, pageSize.width.rounded(.down)),
                               height: max(Self.minimumPageSize.height, pageSize.height.rounded(.down)))
        self.measure = measure.rounded(.down)
        self.margins = margins
    }

    /// The sheet a fixed-layout book's pages are drawn on: their proportions,
    /// at the size flowing pages have at 100%, so zoom means the same in
    /// every book. Fit and two pages follow from it.
    static func fixedSheet(for pageSize: CGSize) -> EPUBPageGeometry {
        let scale = max(standard.pageSize.width, standard.pageSize.height) / max(pageSize.width, pageSize.height, 1)
        return EPUBPageGeometry(pageSize: CGSize(width: pageSize.width * scale, height: pageSize.height * scale))
    }

    /// The same page with the reading measure for text set at `fontSize`
    /// inside `margins`.
    func measured(forFontSize fontSize: CGFloat, margins: EPUBPageMargins = .normal) -> EPUBPageGeometry {
        EPUBPageGeometry(pageSize: pageSize, measure: fontSize * margins.measureInEms, margins: margins)
    }

    /// The same page measured and margined for `typography`.
    func measured(for typography: EPUBTypography) -> EPUBPageGeometry {
        measured(forFontSize: typography.fontSize, margins: typography.margins)
    }

    /// The space around pages in `layout`: the continuous stack's gaps (and
    /// the top chrome its pages start below), or a spread's margin.
    private static func chrome(_ layout: EPUBPageLayout, topInset: CGFloat) -> (width: CGFloat, height: CGFloat) {
        let columns = CGFloat(layout.pagesPerRow)
        return layout.isContinuous
            ? (pageGap * (columns + 1), topInset + pageGap * 2)
            : (spreadMargin * 2, spreadMargin * 2)
    }

    /// The scale at which pages of `pageSize` fit `viewport` in `layout`, like
    /// PDF's Zoom to Fit: the page row's width in the continuous layouts, the
    /// whole page or spread otherwise.
    static func fitScale(pageSize: CGSize, viewport: CGSize, layout: EPUBPageLayout) -> CGFloat {
        let columns = CGFloat(layout.pagesPerRow)
        let space = chrome(layout, topInset: 0)
        // The stack's gaps are part of the page row and scale with it; a
        // spread's margin is window space.
        let scale = layout.isContinuous
            ? viewport.width / (pageSize.width * columns + space.width)
            : min((viewport.width - space.width) / (pageSize.width * columns),
                  (viewport.height - space.height) / pageSize.height)
        return min(max(scale, scaleRange.lowerBound), scaleRange.upperBound)
    }

    /// The page that fills a viewport at 100% in `layout` (Reflow to Fit): the
    /// whole window, or half for two pages, inside the space around pages.
    static func filling(_ viewport: CGSize, layout: EPUBPageLayout, topInset: CGFloat = 0) -> EPUBPageGeometry {
        let columns = CGFloat(layout.pagesPerRow)
        let space = chrome(layout, topInset: topInset)
        return EPUBPageGeometry(pageSize: CGSize(width: (viewport.width - space.width) / columns,
                                                 height: viewport.height - space.height))
    }

    /// The text area as its lines see it: on a vertical page they run down
    /// and stack across, so this is ``textSize`` turned.
    func lineSize(vertical: Bool) -> CGSize {
        vertical ? CGSize(width: textSize.height, height: textSize.width) : textSize
    }

    /// The page's margins, widened evenly on a page wider than the reading
    /// measure.
    var textInsets: NSEdgeInsets {
        let margins = margins.insets
        let side = max(margins.left, ((pageSize.width - measure) / 2).rounded(.down))
        return NSEdgeInsets(top: margins.top, left: side, bottom: margins.bottom, right: side)
    }

    var textSize: CGSize {
        let insets = textInsets
        return CGSize(
            width: pageSize.width - insets.left - insets.right,
            height: pageSize.height - insets.top - insets.bottom
        )
    }

    /// Images fit inside the text area, a line short of its height so an
    /// image always leaves its page room to lay out.
    var imageBounds: CGSize {
        CGSize(width: textSize.width, height: textSize.height - 32)
    }
}

/// A chapter styled for display: the text pages slice, plus what navigation
/// needs from its render.
nonisolated struct EPUBStyledChapter: @unchecked Sendable {
    let text: NSAttributedString
    let anchors: [String: Int]
    /// The elements note references can point to, for footnote pop-ups.
    var noteTargets: [String: EPUBNoteTarget] = [:]
    /// Footnotes shown only as pop-ups, styled like the text, by id.
    var detachedNotes: [String: NSAttributedString] = [:]
    /// One id for each whole note in `detachedNotes`, in the book's order.
    var detachedNoteIDs: [String] = []
    let notices: [EPUBContentNotice]
    /// How a fixed-layout chapter sits on its one page; nil for flowing text.
    var fixedPage: EPUBFixedPage?

    /// The chapter's pages: a fixed page is one page holding all its text;
    /// flowing text splits to fit `pageSize`.
    func pages(fitting pageSize: CGSize) -> [NSRange] {
        guard fixedPage != nil else { return EPUBPaginator.pages(in: text, pageSize: pageSize) }
        return [NSRange(location: 0, length: text.length)]
    }

    /// Renders and styles a chapter. Safe off the main actor.
    static func make(book: EPUBBook, chapter: Int, typography: EPUBTypography, palette: EPUBPagePalette,
                     geometry: EPUBPageGeometry, smallestTables: EPUBTextStyling.TableFloor = .screen) -> EPUBStyledChapter {
        _ = EPUBSwiftMathTypesetter.installed
        guard let rendered = try? book.renderChapter(at: chapter, imageBounds: geometry.imageBounds) else {
            return EPUBStyledChapter(
                text: NSAttributedString(string: "This chapter could not be displayed."),
                anchors: [:],
                notices: []
            )
        }
        return EPUBStyledChapter(
            text: EPUBTextStyling.applying(typography, palette: palette, to: rendered.attributedText,
                                           textWidth: rendered.isVertical ? geometry.textSize.height : geometry.textSize.width,
                                           smallestTables: smallestTables),
            anchors: rendered.anchors,
            noteTargets: rendered.noteTargets,
            detachedNotes: rendered.detachedNotes.mapValues {
                // A table sized for the page would clip in the pop-up.
                EPUBTextStyling.applying(typography, palette: palette, to: $0,
                                         textWidth: EPUBFootnoteViewController.textWidth)
            },
            detachedNoteIDs: rendered.detachedNoteIDs,
            notices: rendered.notices,
            fixedPage: rendered.fixedPage
        )
    }

    /// Decodes the images these pages draw, so they never decode in draw. Safe
    /// off the main actor, where it belongs.
    func decodeImages(in ranges: [NSRange], pixels: CGFloat, pageSize: CGSize) {
        guard !ranges.isEmpty else { return }
        if let fixedPage {
            fixedPage.decodeImages(pixelsPerPoint: pixels * fixedPage.frame(in: pageSize).width / fixedPage.size.width)
        } else {
            for range in ranges { text.decodeEPUBImages(in: range) }
        }
    }

    /// The same chapter in another theme: only text and table border colours change.
    func recolored(from old: EPUBPagePalette, to new: EPUBPagePalette) -> EPUBStyledChapter {
        EPUBStyledChapter(text: EPUBTextStyling.recoloring(text, from: old, to: new), anchors: anchors,
                          noteTargets: noteTargets,
                          detachedNotes: detachedNotes.mapValues { EPUBTextStyling.recoloring($0, from: old, to: new) },
                          detachedNoteIDs: detachedNoteIDs, notices: notices, fixedPage: fixedPage)
    }
}

/// Which pages share a row in a layout: the arithmetic of `pagesPerRow`, or,
/// in two pages when a fixed-layout book says which side its pages are for,
/// the pairs those sides make, a page without a partner alone on its side.
nonisolated struct EPUBSpreadTable: Equatable, Sendable {
    /// Where a lone page sits in its row. Leading is the side a row fills first.
    enum LoneSlot: Equatable, Sendable {
        case leading
        case trailing
        case center

        /// In slots from the row's start.
        var position: CGFloat {
            switch self {
            case .leading: 0
            case .trailing: 1
            case .center: 0.5
            }
        }
    }

    struct Row: Equatable, Sendable {
        let first: Int
        let count: Int
        var loneSlot = LoneSlot.leading

        var pages: Range<Int> { first..<(first + count) }
    }

    let pagesPerRow: Int
    let pageCount: Int
    /// Nil while the arithmetic holds.
    private let rows: [Row]?
    private let rowOfPage: [Int]

    init(pagesPerRow: Int, pageCount: Int, rows: [Row]? = nil) {
        self.pagesPerRow = max(1, pagesPerRow)
        self.pageCount = pageCount
        self.rows = rows
        rowOfPage = rows.map { rows in rows.indices.flatMap { index in rows[index].pages.map { _ in index } } } ?? []
    }

    var rowCount: Int { rows?.count ?? (pageCount + pagesPerRow - 1) / pagesPerRow }

    func row(ofPage page: Int) -> Int {
        guard rows != nil else { return page / pagesPerRow }
        return rowOfPage.indices.contains(page) ? rowOfPage[page] : max(0, rowOfPage.count - 1)
    }

    func row(at index: Int) -> Row {
        if let rows { return rows.indices.contains(index) ? rows[index] : Row(first: 0, count: 0) }
        let first = index * pagesPerRow
        return Row(first: first, count: max(0, min(pagesPerRow, pageCount - first)))
    }

    /// The row a page is on.
    func row(holding page: Int) -> Row { row(at: row(ofPage: page)) }
}

/// Where each chapter's pages fall in the book. A chapter not yet paginated
/// counts as one placeholder page, so the total grows as pagination finishes.
/// A chapter outside the reading flow (linear="no") has no pages at all.
struct EPUBPagination: Equatable, Sendable {
    private(set) var chapterPages: [[NSRange]?]
    private var firstPage: [Int]
    /// Chapters read outside the flow, in their own reader.
    private(set) var excluded: Set<Int> = []
    /// The spread side each fixed-layout chapter's first page is made for.
    private let sides: [Int: EPUBPageSide]
    private let rightToLeft: Bool
    /// Two-page rows, when ``sides`` shape them.
    private var pairedRows: EPUBSpreadTable?

    init(chapterCount: Int, excluded: Set<Int> = [], sides: [Int: EPUBPageSide] = [:], rightToLeft: Bool = false) {
        self.sides = sides
        self.rightToLeft = rightToLeft
        chapterPages = Array(repeating: nil, count: chapterCount)
        firstPage = Array(0..<chapterCount)
        self.excluded = excluded.filter { (0..<chapterCount).contains($0) }
        for chapter in self.excluded { chapterPages[chapter] = [] }
        reindex()
    }

    /// A whole book's pages at once (``EPUBPaginationCache``). A chapter in
    /// the flow saved without pages is paginated again.
    init(pages: [[NSRange]], excluded: Set<Int> = [], sides: [Int: EPUBPageSide] = [:], rightToLeft: Bool = false) {
        self.init(chapterCount: pages.count, excluded: excluded, sides: sides, rightToLeft: rightToLeft)
        for (chapter, ranges) in pages.enumerated() where !self.excluded.contains(chapter) {
            chapterPages[chapter] = ranges.isEmpty ? nil : ranges
        }
        reindex()
    }

    func isExcluded(_ chapter: Int) -> Bool { excluded.contains(chapter) }

    /// The nearest chapter in the reading flow before or after `chapter`.
    func flowChapter(from chapter: Int, forward: Bool) -> Int? {
        var next = chapter + (forward ? 1 : -1)
        while chapterPages.indices.contains(next) {
            if !excluded.contains(next) { return next }
            next += forward ? 1 : -1
        }
        return nil
    }

    func pages(ofChapter chapter: Int) -> [NSRange]? {
        chapterPages.indices.contains(chapter) ? chapterPages[chapter] : nil
    }

    /// Every chapter's pages, once all are paginated.
    var completePages: [[NSRange]]? {
        isComplete ? chapterPages.compactMap { $0 } : nil
    }

    var isComplete: Bool { !chapterPages.contains { $0 == nil } }
    var pageCount: Int {
        guard let last = firstPage.last else { return 0 }
        return last + pageCount(ofChapter: chapterPages.count - 1)
    }

    /// Pages before `global` as they will count once the book is paginated:
    /// a chapter still pending counts as the average chapter so far, not as
    /// its one placeholder page. Exact once the book is complete.
    func estimatedPages(before global: Int) -> Double {
        let done = chapterPages.indices.filter { !excluded.contains($0) }.compactMap { chapterPages[$0]?.count }
        let average = done.isEmpty ? 1 : Double(done.reduce(0, +)) / Double(done.count)
        let pending = chapterPages.indices.filter { chapterPages[$0] == nil && firstPage[$0] < global }.count
        return Double(global) + Double(pending) * (average - 1)
    }

    func isPaginated(_ chapter: Int) -> Bool {
        chapterPages.indices.contains(chapter) && chapterPages[chapter] != nil
    }

    mutating func set(_ pages: [NSRange], forChapter chapter: Int) {
        guard chapterPages.indices.contains(chapter), !excluded.contains(chapter) else { return }
        chapterPages[chapter] = pages.isEmpty ? [NSRange(location: 0, length: 0)] : pages
        reindex()
    }

    private mutating func reindex() {
        var next = 0
        for index in chapterPages.indices {
            firstPage[index] = next
            next += pageCount(ofChapter: index)
        }
        pairedRows = sides.isEmpty ? nil
            : EPUBSpreadTable(pagesPerRow: 2, pageCount: next, rows: pairRows(pageCount: next))
    }

    /// The rows the book's sides make: a page for the row's second side stands
    /// alone there, and a page pairs with the next unless that one must start
    /// a row or stand alone itself.
    private func pairRows(pageCount: Int) -> [EPUBSpreadTable.Row] {
        var sideOfPage: [Int: EPUBPageSide] = [:]
        for (chapter, side) in sides where self.pageCount(ofChapter: chapter) > 0 { sideOfPage[firstPage[chapter]] = side }
        let firstSide: EPUBPageSide = rightToLeft ? .right : .left
        let secondSide: EPUBPageSide = rightToLeft ? .left : .right
        var rows: [EPUBSpreadTable.Row] = []
        var page = 0
        while page < pageCount {
            let side = sideOfPage[page]
            if side == .center {
                rows.append(.init(first: page, count: 1, loneSlot: .center))
                page += 1
            } else if side == secondSide {
                rows.append(.init(first: page, count: 1, loneSlot: .trailing))
                page += 1
            } else if page + 1 < pageCount, sideOfPage[page + 1] != .center, sideOfPage[page + 1] != firstSide {
                rows.append(.init(first: page, count: 2))
                page += 2
            } else {
                rows.append(.init(first: page, count: 1))
                page += 1
            }
        }
        return rows
    }

    /// Which pages share a row with `pagesPerRow` to a row.
    func spreads(pagesPerRow: Int) -> EPUBSpreadTable {
        pagesPerRow == 2 ? pairedRows ?? EPUBSpreadTable(pagesPerRow: 2, pageCount: pageCount)
            : EPUBSpreadTable(pagesPerRow: pagesPerRow, pageCount: pageCount)
    }

    /// The chapter and its page range shown at a global page index; the
    /// range is nil while that chapter is still being paginated.
    func page(at global: Int) -> (chapter: Int, range: NSRange?)? {
        guard global >= 0, global < pageCount else { return nil }
        var low = 0
        var high = firstPage.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if firstPage[mid] <= global { low = mid } else { high = mid - 1 }
        }
        let local = global - firstPage[low]
        return (low, chapterPages[low]?[local])
    }

    /// The global page holding a chapter offset.
    func globalPage(chapter: Int, offset: Int) -> Int {
        guard firstPage.indices.contains(chapter) else { return 0 }
        guard let pages = chapterPages[chapter] else { return firstPage[chapter] }
        return firstPage[chapter] + EPUBPaginator.pageIndex(containing: offset, in: pages)
    }

    func firstPage(ofChapter chapter: Int) -> Int {
        firstPage.indices.contains(chapter) ? firstPage[chapter] : 0
    }

    private func pageCount(ofChapter chapter: Int) -> Int {
        guard chapterPages.indices.contains(chapter) else { return 0 }
        return chapterPages[chapter]?.count ?? 1
    }
}
