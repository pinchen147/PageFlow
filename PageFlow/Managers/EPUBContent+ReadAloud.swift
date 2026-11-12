//
//  EPUBContent+ReadAloud.swift
//  PageFlow
//
//  Where Read Aloud starts in the book, and the pages following it: a page
//  at a time turns when the voice moves past the pages on screen; the
//  continuous layouts jump only when it is far away, and the stack scrolls
//  the spoken line into view itself. Also sets up the book's own narration
//  and keeps its speed.
//

import EPUBKit
import Foundation

extension EPUBContent {
    func setUpReadAloud() {
        readAloud.chapterCount = { [weak self] in self?.book?.chapters.count ?? 0 }
        readAloud.skipsChapter = { [weak self] in self?.pagination.isExcluded($0) ?? false }
        readAloud.startPosition = { [weak self] in self?.readAloudStart }
        readAloud.stopPosition = { [weak self] in self?.highlights.selection?.end }
        readAloud.onSpokenMove = { [weak self] in self?.followSpoken($0) }
    }

    /// The book is open: Read Aloud plays its own narration, if it has any.
    func setUpNarration(of book: EPUBBook) {
        readAloud.narratedChapters = Set(book.mediaOverlays.chapters.keys)
        readAloud.narrationDuration = book.mediaOverlays.duration
        readAloud.narrationRate = AppDefaults.store.object(forKey: Self.narrationRateKey) as? Float ?? 1
        readAloud.makeNarrator = {
            EPUBNarrationPlayer { path, file in
                try book.extractAudio(path, to: file, limit: EPUBExtractedAudio.sizeLimit)
            }
        }
    }

    private static let narrationRateKey = "epubNarrationRate"

    /// The reader's choice of speed, kept for every narrated book.
    func setNarrationRate(_ rate: Float) {
        readAloud.narrationRate = rate
        AppDefaults.store.set(rate, forKey: Self.narrationRateKey)
    }

    /// The selection's start, else the top of the page being read.
    var readAloudStart: EPUBTextPosition? {
        if let selection = highlights.selection { return selection.start }
        guard let shown = pagination.page(at: currentPage) else { return nil }
        return EPUBTextPosition(chapter: shown.chapter, offset: shown.range?.location ?? 0)
    }

    /// The page the voice is on.
    func page(of spoken: EPUBSpokenRange) -> Int {
        pagination.globalPage(chapter: spoken.chapter, offset: spoken.location)
    }

    private func followSpoken(_ spoken: EPUBSpokenRange) {
        let page = page(of: spoken)
        let inView = EPUBReadAloud.pagesInView(currentPage: currentPage, pagesPerRow: currentRow.count,
                                               isContinuous: layout.isContinuous)
        guard readAloud.pageFollow.shouldFollow(inView: inView.contains(page), at: currentPage) else { return }
        goToPage(page)
        readAloud.pageFollow.followed(to: currentPage)
    }
}
