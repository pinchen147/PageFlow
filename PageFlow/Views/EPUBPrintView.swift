//
//  EPUBPrintView.swift
//  PageFlow
//
//  A book as paper: the whole reading flow laid out for the sheet the print panel
//  has, by the same styling, paginator and page view the reader uses, in black on
//  white whatever the reader's theme. Printing asks it for one page at a time, so
//  only the chapter being printed is held. Marks print as PDF's do: highlights and
//  underlines, but not the note dots (a PDF comment prints only its highlight).
//  Footnotes the reader shows as pop-ups follow their chapter.
//

import AppKit
import EPUBKit

/// A sheet of paper as the print settings have it, in points.
nonisolated struct EPUBPrintSheet: Equatable, Sendable {
    let size: CGSize
    /// What a printer can mark, from the sheet's top left. A placed page fits
    /// inside it; a flowing page's margins are already wider.
    let printable: CGRect

    @MainActor
    init(_ info: NSPrintInfo) {
        size = info.paperSize
        let marked = info.imageablePageBounds
        // The print settings' bounds run up from the sheet's bottom edge.
        printable = marked.isEmpty ? CGRect(origin: .zero, size: size)
            : CGRect(x: marked.minX, y: size.height - marked.maxY, width: marked.width, height: marked.height)
    }
}

/// Every printed page in reading order, for one sheet. Chapters outside the flow
/// (linear="no") have none, and neither does an empty chapter: no blank sheets.
nonisolated struct EPUBPrintLayout: Sendable {
    let sheet: EPUBPrintSheet
    let pages: [(chapter: Int, range: NSRange)]
    /// A flowing page fills the sheet.
    let flowGeometry: EPUBPageGeometry

    /// A placed page turns when its long side would otherwise lie across the
    /// paper's short one, as PDF's auto-rotate does.
    func turns(_ page: EPUBFixedPage) -> Bool {
        let printable = sheet.printable.size
        return page.size.width != page.size.height
            && (page.size.width > page.size.height) != (printable.width > printable.height)
    }

    /// A placed page fits what the printer can mark.
    func geometry(for page: EPUBFixedPage) -> EPUBPageGeometry {
        let printable = sheet.printable.size
        return EPUBPageGeometry(pageSize: turns(page) ? CGSize(width: printable.height, height: printable.width) : printable)
    }

    /// A chapter as paper has it. Paper has no pop-ups, so the chapter's notes
    /// follow its text, each whole note once; its own offsets don't move, so
    /// highlights stay on their words.
    static func styled(book: EPUBBook, chapter: Int, typography: EPUBTypography, geometry: EPUBPageGeometry) -> EPUBStyledChapter {
        let styled = EPUBStyledChapter.make(book: book, chapter: chapter, typography: typography, palette: .light,
                                            geometry: geometry, smallestTables: .paper)
        let notes = styled.detachedNoteIDs.compactMap { styled.detachedNotes[$0] }.map(EPUBFootnote.trimmed).filter { $0.length > 0 }
        guard !notes.isEmpty else { return styled }
        let text = NSMutableAttributedString(attributedString: styled.text)
        for note in notes {
            let attributes = note.attributes(at: 0, effectiveRange: nil)
            let start = text.length
            // A blank line sets the first note apart from the chapter.
            text.append(NSAttributedString(string: note === notes.first ? "\n\n" : "\n", attributes: attributes))
            text.append(note)
            if EPUBWriting.isVertical(styled.text) {
                text.addAttribute(EPUBWriting.verticalAttribute, value: true,
                                  range: NSRange(location: start, length: text.length - start))
            }
        }
        return EPUBStyledChapter(text: text, anchors: styled.anchors, notices: styled.notices, fixedPage: styled.fixedPage)
    }

    /// Where printed breaks are saved: with their notes and table sizes they
    /// aren't the reader's, whose page size may well be the paper's.
    private static let breaksDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("EPUBPrintPagination", isDirectory: true)

    /// Blocks while it works, spread over the cores, and reuses page breaks
    /// already saved for this page size. The panel needs a page count back at
    /// once, so a new paper blocks the main thread: cells and formulas need it, so it
    /// waits through ``EPUBMainThreadRelay`` for the workers that need it.
    static func make(book: EPUBBook, url: URL, typography: EPUBTypography, sheet: EPUBPrintSheet) -> EPUBPrintLayout {
        let geometry = EPUBPageGeometry(pageSize: sheet.size).measured(for: typography)
        let flow = book.chapters.indices.filter { book.chapters[$0].isLinear }
        var breaks = EPUBPaginationCache.load(for: url, typography: typography, geometry: geometry,
                                              chapterCount: book.chapters.count, in: breaksDirectory)
        if breaks == nil {
            let found = ChapterBreaks(count: book.chapters.count)
            let findBreaks: @Sendable (Int) -> Void = { chapter in
                let text = styled(book: book, chapter: chapter, typography: typography, geometry: geometry)
                found.set(text.pages(fitting: geometry.textSize), forChapter: chapter)
            }
            let findAll: @Sendable () -> Void = {
                DispatchQueue.concurrentPerform(iterations: flow.count) { findBreaks(flow[$0]) }
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated { EPUBMainThreadRelay.wait(for: findAll) }
            } else { findAll() }
            breaks = found.all
            EPUBPaginationCache.save(found.all, for: url, typography: typography, geometry: geometry, in: breaksDirectory)
        }
        return EPUBPrintLayout(sheet: sheet, pages: flow.flatMap { chapter in
            (breaks?[chapter] ?? []).map { (chapter: chapter, range: $0) }
        }, flowGeometry: geometry)
    }

    /// Each chapter's breaks, filled in from whichever thread found them.
    private final class ChapterBreaks: @unchecked Sendable {
        private let lock = NSLock()
        private var breaks: [[NSRange]]

        init(count: Int) { breaks = Array(repeating: [], count: count) }

        var all: [[NSRange]] { lock.withLock { breaks } }

        func set(_ pages: [NSRange], forChapter chapter: Int) {
            lock.withLock { breaks[chapter] = pages }
        }
    }
}

final class EPUBPrintView: NSView {
    private let book: EPUBBook
    private let url: URL
    private let typography: EPUBTypography
    private let highlights: [EPUBHighlight]
    /// Keeps the book's file readable for as long as the print job runs,
    /// whatever becomes of the tab.
    let fileAccess: PDFFileAccess
    private var layout: EPUBPrintLayout
    /// The chapter being printed.
    private var styled: (chapter: Int, text: EPUBStyledChapter)?
    /// The last page drawn: a preview asks for the same page again and again.
    private var shown: (index: Int, page: EPUBPageView)?

    init(book: EPUBBook, url: URL, typography: EPUBTypography, highlights: [EPUBHighlight], fileAccess: PDFFileAccess,
         layout: EPUBPrintLayout) {
        self.book = book
        self.fileAccess = fileAccess
        self.url = url
        self.typography = typography
        self.highlights = highlights
        self.layout = layout
        super.init(frame: .zero)
        // Paper is light, whatever the Mac's appearance.
        appearance = NSAppearance(named: .aqua)
        adoptLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func adoptLayout() {
        styled = nil
        shown = nil
        setFrameSize(NSSize(width: layout.sheet.size.width,
                            height: layout.sheet.size.height * CGFloat(max(1, layout.pages.count))))
    }

    // MARK: - Pages

    /// The panel asks again when its paper or orientation changes.
    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        if let info = NSPrintOperation.current?.printInfo {
            let sheet = EPUBPrintSheet(info)
            if sheet != layout.sheet {
                layout = .make(book: book, url: url, typography: typography, sheet: sheet)
                adoptLayout()
            }
        }
        range.pointee = NSRange(location: 1, length: max(1, layout.pages.count))
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect { rect(ofPage: page - 1) }

    /// A page is a whole sheet, its edge on the paper's. The system's choice
    /// would start it inside what the printer can mark.
    override func locationOfPrintRect(_ rect: NSRect) -> NSPoint { .zero }

    /// A page's sheet in this unflipped view: the first page on top.
    private func rect(ofPage index: Int) -> NSRect {
        let size = layout.sheet.size
        return NSRect(x: 0, y: size.height * CGFloat(max(1, layout.pages.count) - 1 - index),
                      width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let height = layout.sheet.size.height
        guard !layout.pages.isEmpty, height > 0, let context = NSGraphicsContext.current else { return }
        let last = layout.pages.count - 1
        // Just inside the rect: a page rect's edges touch its neighbours.
        let dirty = dirtyRect.insetBy(dx: 0, dy: 0.5)
        let first = max(0, last - Int(dirty.maxY / height))
        let final = min(last, last - Int(dirty.minY / height))
        guard first <= final else { return }
        for index in first...final { draw(pageAt: index, in: context) }
    }

    /// In its own pool: a print run never returns to the run loop between
    /// pages, so what a page leaves autoreleased would pile up for the whole book.
    private func draw(pageAt index: Int, in context: NSGraphicsContext) {
        autoreleasepool {
            let page = pageView(at: index)
            NSGraphicsContext.saveGraphicsState()
            placementTransform(of: page, at: index).concat()
            page.displayIgnoringOpacity(page.bounds, in: context)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Where a page sits on its sheet. A flowing page has a smallest size; on
    /// smaller paper, all of it still shows. A placed page keeps to what the
    /// printer can mark, turned with its top to the left when it turns.
    private func placementTransform(of page: EPUBPageView, at index: Int) -> NSAffineTransform {
        let sheet = rect(ofPage: index)
        let transform = NSAffineTransform()
        guard let fixed = page.textView.fixedLayer?.page else {
            let scale = min(1, sheet.width / page.bounds.width, sheet.height / page.bounds.height)
            transform.translateX(by: sheet.minX, yBy: sheet.maxY - page.bounds.height * scale)
            transform.scale(by: scale)
            return transform
        }
        let printable = layout.sheet.printable
        let frame = NSRect(x: sheet.minX + printable.minX, y: sheet.maxY - printable.maxY,
                           width: printable.width, height: printable.height)
        if layout.turns(fixed) {
            transform.translateX(by: frame.maxX, yBy: frame.minY)
            transform.rotate(byDegrees: 90)
            transform.scale(by: min(1, frame.height / page.bounds.width, frame.width / page.bounds.height))
        } else {
            let scale = min(1, frame.width / page.bounds.width, frame.height / page.bounds.height)
            transform.translateX(by: frame.minX, yBy: frame.maxY - page.bounds.height * scale)
            transform.scale(by: scale)
        }
        return transform
    }

    private func styledChapter(_ chapter: Int) -> EPUBStyledChapter {
        if let styled, styled.chapter == chapter { return styled.text }
        let text = EPUBPrintLayout.styled(book: book, chapter: chapter, typography: typography, geometry: layout.flowGeometry)
        styled = (chapter, text)
        return text
    }

    private func pageView(at index: Int) -> EPUBPageView {
        if let shown, shown.index == index { return shown.page }
        let (chapter, range) = layout.pages[index]
        let styled = styledChapter(chapter)
        let page = EPUBPageView.forPrinting(showing: EPUBPageContent(
            text: styled.text,
            range: range,
            header: book.chapters[chapter].title,
            footer: "\(index + 1)",
            palette: .light,
            geometry: styled.fixedPage.map(layout.geometry(for:)) ?? layout.flowGeometry,
            family: typography.family,
            page: index,
            chapter: chapter,
            highlights: EPUBPageHighlight.onPage(highlights, chapter: chapter, pageRange: range).map(\.withoutNoteMarker),
            fixedPage: styled.fixedPage
        ))
        page.appearance = appearance
        shown = (index, page)
        return page
    }
}

private extension EPUBPageHighlight {
    var withoutNoteMarker: EPUBPageHighlight {
        EPUBPageHighlight(id: id, range: range, color: color, style: style, hasNote: false, startsHere: startsHere)
    }
}

extension EPUBContent {
    /// The book laid out off the main thread for the sheet in `info`, in the
    /// reader's text settings on white paper; nil unless it is ready.
    func makePrintView(for info: NSPrintInfo) async -> EPUBPrintView? {
        guard isReady, let book else { return nil }
        let (url, typography, sheet) = (documentURL, typography, EPUBPrintSheet(info))
        let layout = await Task.detached(priority: .userInitiated) {
            EPUBPrintLayout.make(book: book, url: url, typography: typography, sheet: sheet)
        }.value
        return EPUBPrintView(book: book, url: url, typography: typography, highlights: highlights.items,
                             fileAccess: PDFFileAccess(url: url, requestSecurityScope: usesSecurityScopedAccess), layout: layout)
    }
}
