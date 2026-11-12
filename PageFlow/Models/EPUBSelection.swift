//
//  EPUBSelection.swift
//  PageFlow
//
//  The reader's text selection in a book: from where a drag began to where
//  it is now, each end a chapter and a UTF-16 offset in its styled text. It
//  can run over every page on screen and across a chapter break; each page
//  paints its own part, and Copy and Highlight take all of it.
//

import EPUBKit
import AppKit

/// A place in the book's text.
nonisolated struct EPUBTextPosition: Comparable, Hashable, Sendable {
    var chapter: Int
    var offset: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.chapter, lhs.offset) < (rhs.chapter, rhs.offset)
    }
}

/// Selected text, possibly over several pages and chapters.
nonisolated struct EPUBTextSelection: Equatable, Sendable {
    /// Where the selection began; Shift-click and dragging move only `focus`.
    var anchor: EPUBTextPosition
    var focus: EPUBTextPosition

    init(anchor: EPUBTextPosition, focus: EPUBTextPosition) {
        self.anchor = anchor
        self.focus = focus
    }

    /// A selection inside one chapter.
    init(chapter: Int, range: NSRange) {
        anchor = EPUBTextPosition(chapter: chapter, offset: range.location)
        focus = EPUBTextPosition(chapter: chapter, offset: NSMaxRange(range))
    }

    /// Select All: the reading flow from its first chapter to its last, whose
    /// length isn't needed (and would take styling it) until something reads it.
    static func wholeBook(first: Int, last: Int) -> EPUBTextSelection {
        EPUBTextSelection(anchor: EPUBTextPosition(chapter: first, offset: 0),
                          focus: EPUBTextPosition(chapter: last, offset: .max))
    }

    var isWholeBook: Bool { focus.offset == .max }

    var start: EPUBTextPosition { min(anchor, focus) }
    var end: EPUBTextPosition { max(anchor, focus) }
    var isEmpty: Bool { anchor == focus }

    /// The chapter, when the selection lies in one.
    var chapter: Int? { start.chapter == end.chapter ? start.chapter : nil }

    /// The chapter range, when the selection lies in one chapter.
    var range: NSRange? {
        guard chapter != nil else { return nil }
        return NSRange(location: start.offset, length: end.offset - start.offset)
    }

    /// The part in `chapter` that a page showing `pageRange` of it shows, in
    /// the page's own offsets. A chapter the selection runs through whole
    /// needs no length: the page range bounds it.
    func localRange(inChapter chapter: Int, pageRange: NSRange) -> NSRange? {
        guard chapter >= start.chapter, chapter <= end.chapter else { return nil }
        let lower = max(chapter == start.chapter ? start.offset : 0, pageRange.location)
        let upper = min(chapter == end.chapter ? end.offset : Int.max, NSMaxRange(pageRange))
        guard upper > lower else { return nil }
        return NSRange(location: lower - pageRange.location, length: upper - lower)
    }

    /// Each chapter's part, in reading order. `length` gives a chapter's text
    /// length; a chapter whose text isn't at hand is left out.
    func chapterRanges(length: (Int) -> Int?) -> [(chapter: Int, range: NSRange)] {
        (start.chapter...end.chapter).compactMap { chapter in
            let lower = chapter == start.chapter ? start.offset : 0
            guard let total = length(chapter) else { return nil }
            let upper = min(chapter == end.chapter ? end.offset : total, total)
            guard upper > lower else { return nil }
            return (chapter, NSRange(location: lower, length: upper - lower))
        }
    }

    /// The selected text in reading order, whichever way it was dragged:
    /// chapters joined by a line break, images (attachment characters) left out.
    func text(chapterText: (Int) -> NSAttributedString?) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var texts: [Int: NSAttributedString] = [:]
        let parts = chapterRanges { chapter in
            texts[chapter] = chapterText(chapter)
            return texts[chapter]?.length
        }
        for part in parts {
            guard let text = texts[part.chapter] else { continue }
            if result.length > 0, !result.string.hasSuffix("\n") {
                result.append(NSAttributedString(string: "\n"))
            }
            result.append(text.attributedSubstring(from: part.range))
        }
        EPUBMath.wordsForCopying(in: result)
        return result
    }

    /// A drag by words or paragraphs: the unit first clicked (`anchorUnit`)
    /// stays selected, and the selection reaches the far side of the unit
    /// under the pointer (`focusUnit`), backwards or forwards.
    static func extending(_ anchorUnit: (start: EPUBTextPosition, end: EPUBTextPosition),
                          to focusUnit: (start: EPUBTextPosition, end: EPUBTextPosition)) -> EPUBTextSelection {
        if focusUnit.start < anchorUnit.start {
            return EPUBTextSelection(anchor: anchorUnit.end, focus: focusUnit.start)
        }
        return EPUBTextSelection(anchor: anchorUnit.start, focus: max(focusUnit.end, anchorUnit.end))
    }
}

extension EPUBPageContent {
    /// A place on this page (in its own offsets) as a place in the book.
    func position(atLocal offset: Int) -> EPUBTextPosition? {
        guard let chapter, let range else { return nil }
        return EPUBTextPosition(chapter: chapter, offset: range.location + min(max(0, offset), range.length))
    }

    /// Whether a place in the book is on this page, at either of its ends.
    func shows(_ position: EPUBTextPosition) -> Bool {
        guard let range, chapter == position.chapter else { return false }
        return position.offset >= range.location && position.offset <= NSMaxRange(range)
    }

    /// The part of `selection` this page shows, in its own offsets.
    func localRange(of selection: EPUBTextSelection?) -> NSRange? {
        guard let selection, let chapter, let range else { return nil }
        return selection.localRange(inChapter: chapter, pageRange: range)
    }
}

extension Notification.Name {
    /// What pages paint over their text changed without a new page: the
    /// selection (object: the book's `EPUBHighlights`) or the spoken words
    /// (object: its `EPUBReadAloud`). Pages showing that book repaint.
    static let epubPageMarksDidChange = Notification.Name("EPUBPageMarksDidChange")
}
