//
//  EPUBChapterCache.swift
//  PageFlow
//
//  The styled chapters an EPUB tab draws from: styled off the main thread
//  (a far page's short chapter on it, when that takes moments), kept within a
//  text-length budget, least recently used evicted first, never the reader's
//  own chapters.
//

import EPUBKit
import Foundation

/// A page about to draw: its slice of the chapter, and the device pixels each
/// of its points fills.
struct EPUBWantedPage: Sendable {
    let range: NSRange
    let pixels: CGFloat
}

@MainActor
final class EPUBChapterCache {
    /// UTF-16 units of styled text kept: a typical book fits whole once the
    /// background pass has styled it, so pages and thumbnails never wait.
    static let defaultBudget = 4_000_000

    /// Called with each chapter that lands.
    var onInsert: ((Int) -> Void)?
    /// The reader's chapter and its neighbours, never evicted.
    var protected: ClosedRange<Int> = 0...0

    private let budget: Int
    private var book: EPUBBook?
    private var typography = EPUBTypography()
    private var palette = EPUBPagePalette.light
    private var geometry = EPUBPageGeometry.standard
    private var chapters: [Int: EPUBStyledChapter] = [:]
    /// Least recently used first.
    private var order: [Int] = []
    private var length = 0
    private var styling: [Int: (task: Task<EPUBStyledChapter, Never>, pages: WantedPages)] = [:]
    private var queued: [Int] = []
    private var queueTask: Task<Void, Never>?
    private var generation = 0

    init(budget: Int = defaultBudget) {
        self.budget = budget
    }

    /// Whether more text fits without evicting anything.
    var hasRoom: Bool { length < budget }

    /// Whether a chapter's styling is under way.
    func isStyling(_ index: Int) -> Bool { styling[index] != nil }

    /// Every cached chapter, for restyling them all at once (a theme change).
    var all: [Int: EPUBStyledChapter] { chapters }

    /// Drops everything and styles with `typography` for pages of `geometry`
    /// from now on. `seed` holds chapters already styled for them.
    func reset(book: EPUBBook?, typography: EPUBTypography, palette: EPUBPagePalette, geometry: EPUBPageGeometry,
               seed: [Int: EPUBStyledChapter] = [:]) {
        generation &+= 1
        styling.removeAll()
        queued.removeAll()
        queueTask = nil
        chapters.removeAll()
        order.removeAll()
        length = 0
        self.book = book
        self.typography = typography
        self.palette = palette
        self.geometry = geometry
        for (index, chapter) in seed.sorted(by: { $0.key < $1.key }) { insert(chapter, for: index) }
    }

    /// Keeps only the reader's chapter and its neighbours (a hidden tab).
    func releaseUnprotected() {
        for index in order where !protected.contains(index) {
            length -= chapters.removeValue(forKey: index)?.text.length ?? 0
        }
        order.removeAll { !protected.contains($0) }
    }

    /// The chapter without marking it used.
    func peek(_ index: Int) -> EPUBStyledChapter? { chapters[index] }

    /// The chapter, marked as recently used.
    func chapter(_ index: Int) -> EPUBStyledChapter? {
        guard let chapter = chapters[index] else { return nil }
        if order.last != index {
            order.removeAll { $0 == index }
            order.append(index)
        }
        return chapter
    }

    /// The chapter at once, on this thread: for a command over chapters away
    /// from the reader that can't wait, or a far page whose chapter takes moments.
    /// First to leave the cache.
    func styledNow(_ index: Int) -> EPUBStyledChapter? {
        if let cached = peek(index) { return cached }
        guard let book else { return nil }
        let chapter = EPUBStyledChapter.make(book: book, chapter: index, typography: typography, palette: palette,
                                             geometry: geometry)
        insert(chapter, for: index, asLeastRecent: true)
        return chapter
    }

    /// The pages a chapter under way lands on: their images decode before it
    /// does. Pages asked for meanwhile join in, from whichever path started it.
    private final class WantedPages: @unchecked Sendable {
        private let lock = NSLock()
        private var ranges: [NSRange] = []
        private var pixels: CGFloat = 0

        func add(_ page: EPUBWantedPage) {
            lock.withLock {
                ranges.append(page.range)
                pixels = page.pixels
            }
        }

        var wanted: (ranges: [NSRange], pixels: CGFloat) { lock.withLock { (ranges, pixels) } }
    }

    /// The chapter, styling it now if it isn't cached or already under way;
    /// nil once the cache is reset with no book (a closed tab). A page in
    /// `decoding` is one about to draw: it draws from what is decoded here,
    /// off the main thread, rather than decoding as it draws.
    func styled(_ index: Int, priority: TaskPriority = .userInitiated, asLeastRecent: Bool = false,
                decoding page: EPUBWantedPage? = nil) async -> EPUBStyledChapter? {
        if let cached = chapter(index) { return cached }
        if let pending = styling[index] {
            if let page { pending.pages.add(page) }
            return await pending.task.value
        }
        guard let book else { return nil }
        let (typography, palette, geometry, generation) = (typography, palette, geometry, generation)
        let pages = WantedPages()
        if let page { pages.add(page) }
        let task = Task.detached(priority: priority) {
            let chapter = EPUBStyledChapter.make(book: book, chapter: index, typography: typography, palette: palette,
                                                 geometry: geometry)
            let wanted = pages.wanted
            chapter.decodeImages(in: wanted.ranges, pixels: wanted.pixels, pageSize: geometry.pageSize)
            return chapter
        }
        styling[index] = (task, pages)
        let result = await task.value
        guard generation == self.generation else { return result }
        styling[index] = nil
        insert(result, for: index, asLeastRecent: asLeastRecent)
        return result
    }

    /// Styles a chapter at low priority, one at a time, without pushing the
    /// reader's chapters out of the recently used end (rail thumbnails).
    func request(_ index: Int) {
        guard chapters[index] == nil, styling[index] == nil, !queued.contains(index) else { return }
        queued.append(index)
        guard queueTask == nil else { return }
        let generation = generation
        queueTask = Task { [weak self] in
            while let next = self?.queued.first, self?.generation == generation {
                _ = await self?.styled(next, priority: .utility, asLeastRecent: true)
                self?.queued.removeAll { $0 == next }
            }
            if self?.generation == generation { self?.queueTask = nil }
        }
    }

    /// Whether a chapter fits without evicting anything.
    func fits(_ chapter: EPUBStyledChapter) -> Bool { length + chapter.text.length <= budget }

    /// Keeps a chapter the background pass styled, only while it fits: the
    /// background never evicts. One being styled for a page waits for that,
    /// which lands with the page's images decoded.
    func admitIfRoom(_ chapter: EPUBStyledChapter, for index: Int) {
        guard chapters[index] == nil, styling[index] == nil, fits(chapter) else { return }
        insert(chapter, for: index, asLeastRecent: true)
    }

    private func insert(_ chapter: EPUBStyledChapter, for index: Int, asLeastRecent: Bool = false) {
        if let old = chapters.updateValue(chapter, forKey: index) {
            length -= old.text.length
            order.removeAll { $0 == index }
        }
        length += chapter.text.length
        if asLeastRecent { order.insert(index, at: 0) } else { order.append(index) }
        while length > budget,
              let victim = order.firstIndex(where: { $0 != index && !protected.contains($0) }) {
            length -= chapters.removeValue(forKey: order.remove(at: victim))?.text.length ?? 0
        }
        onInsert?(index)
    }
}
