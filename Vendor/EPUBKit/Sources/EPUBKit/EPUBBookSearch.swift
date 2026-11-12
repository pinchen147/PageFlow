import Foundation

/// A whole-book Find: every match, and the chapters it could not read.
public struct EPUBSearchOutcome: Equatable, Sendable {
    public let results: [EPUBSearchResult]
    /// Chapters that failed to read or render, so their text was not searched.
    public let unsearchedChapters: [Int]

    public init(results: [EPUBSearchResult], unsearchedChapters: [Int] = []) {
        self.results = results
        self.unsearchedChapters = unsearchedChapters
    }
}

/// A match with the words around it, on one line, for a results list.
public struct EPUBSearchExcerpt: Equatable, Sendable {
    public let before: String
    public let match: String
    public let after: String

    public init(before: String, match: String, after: String) {
        self.before = before
        self.match = match
        self.after = after
    }
}

public extension EPUBBook {
    /// Searches every chapter's text, ignoring case but not accents, as Find
    /// does in a PDF and in Markdown. A chapter that can't be read or rendered
    /// has nothing to find; the rest of the book still searches, and the
    /// outcome names it.
    func searchBook(_ query: String) throws -> EPUBSearchOutcome {
        guard !query.isEmpty else { return EPUBSearchOutcome(results: []) }
        var reader: ArchiveReader?
        var matches: [EPUBSearchResult] = []
        var unsearched: [Int] = []
        for chapterIndex in chapters.indices {
            try Task.checkCancellation()
            guard let source = indexedText(of: chapterIndex, reader: &reader)?.text else {
                unsearched.append(chapterIndex)
                continue
            }
            var cursor = 0
            while cursor < source.length {
                let range = source.range(
                    of: query,
                    options: .caseInsensitive,
                    range: NSRange(location: cursor, length: source.length - cursor)
                )
                guard range.location != NSNotFound else { break }
                matches.append(EPUBSearchResult(chapterIndex: chapterIndex, range: range))
                cursor = NSMaxRange(range)
            }
        }
        return EPUBSearchOutcome(results: matches, unsearchedChapters: unsearched)
    }

    /// The match with up to `before` characters ahead of it and `after`
    /// behind, whitespace collapsed and images dropped; nil until its
    /// chapter has been searched.
    func searchExcerpt(for result: EPUBSearchResult, before: Int = 40, after: Int = 40) -> EPUBSearchExcerpt? {
        guard let text = searchText[result.chapterIndex]?.text,
              NSMaxRange(result.range) <= text.length else { return nil }
        let start = max(0, result.range.location - before)
        let end = min(text.length, NSMaxRange(result.range) + after)
        func clean(_ range: NSRange) -> String {
            text.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }
        var lead = clean(NSRange(location: start, length: result.range.location - start))
        var tail = clean(NSRange(location: NSMaxRange(result.range), length: end - NSMaxRange(result.range)))
        // Cut back to whole words where the excerpt was cut mid-text.
        if start > 0, let space = lead.firstIndex(of: " ") { lead = "…" + String(lead[space...]) }
        if end < text.length, let space = tail.lastIndex(of: " ") { tail = String(tail[..<space]) + "…" }
        if start == 0 { lead = String(lead.drop { $0 == " " }) }
        if end == text.length { tail = String(tail.reversed().drop { $0 == " " }.reversed()) }
        return EPUBSearchExcerpt(before: lead, match: clean(result.range), after: tail)
    }

    /// Plain text of parts of chapters, in order, as Copy gives it, for a
    /// selection too large to style: each chapter rendered once without images
    /// and not kept. `upper` past a chapter's end means to its end. A chapter
    /// that can't be read is left out. Call it off the main thread; a cancelled
    /// task stops it.
    func plainText(of parts: [(chapter: Int, lower: Int, upper: Int)]) throws -> String {
        var reader: ArchiveReader?
        var result = ""
        for part in parts {
            try Task.checkCancellation()
            guard chapters.indices.contains(part.chapter) else { continue }
            let chapter = chapters[part.chapter]
            guard let archive = reader ?? (try? ArchiveReader(url: sourceURL, expandedLimit: .max)) else { continue }
            reader = archive
            let renderer = XHTMLRenderer(archive: archive, resourcePath: chapter.path, images: nil,
                                         keepsNotesInline: chapter.layout == .fixed)
            autoreleasepool {
                guard let bytes = try? source(of: chapter, in: archive), let text = try? renderer.render(bytes),
                      part.lower < text.length else { return }
                let range = NSRange(location: part.lower, length: min(part.upper, text.length) - part.lower)
                let piece = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
                EPUBMath.wordsForCopying(in: piece)
                if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
                result += piece.string
            }
        }
        return result
    }

    /// Where an id sits in a chapter's text (the same offsets the display
    /// render uses); nil when the chapter can't be read or has no such id.
    func anchorOffset(chapter: Int, fragment: String) -> Int? {
        var reader: ArchiveReader?
        return indexedText(of: chapter, reader: &reader)?.anchors[fragment]
    }

    /// A chapter's plain text and anchors, rendered once without images
    /// (one slot per image, like the display render) and kept for Find.
    internal func indexedText(of chapterIndex: Int, reader: inout ArchiveReader?) -> EPUBSearchText.Entry? {
        if let cached = searchText[chapterIndex] { return cached.isFailed ? nil : cached }
        guard chapters.indices.contains(chapterIndex) else { return nil }
        let chapter = chapters[chapterIndex]
        guard let archive = reader ?? (try? ArchiveReader(url: sourceURL)) else { return nil }
        reader = archive
        let renderer = XHTMLRenderer(archive: archive, resourcePath: chapter.path, images: nil,
                                     keepsNotesInline: chapter.layout == .fixed)
        guard let bytes = try? source(of: chapter, in: archive), let text = try? renderer.render(bytes) else {
            searchText[chapterIndex] = .failed
            return nil
        }
        let entry = EPUBSearchText.Entry(text: text.string as NSString, anchors: renderer.anchors)
        searchText[chapterIndex] = entry
        return entry
    }
}

/// A thread-safe per-book cache of chapter plain text for Find.
final class EPUBSearchText: @unchecked Sendable {
    struct Entry: @unchecked Sendable {
        let text: NSString
        let anchors: [String: Int]
        var isFailed = false

        static let failed = Entry(text: "", anchors: [:], isFailed: true)
    }

    private let lock = NSLock()
    private var texts: [Int: Entry] = [:]

    subscript(chapter: Int) -> Entry? {
        get { lock.withLock { texts[chapter] } }
        set { lock.withLock { texts[chapter] = newValue } }
    }
}
