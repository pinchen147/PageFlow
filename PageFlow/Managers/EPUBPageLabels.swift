//
//  EPUBPageLabels.swift
//  PageFlow
//
//  The print edition's page labels ("iv", "123") placed in the book's text,
//  kept apart from the layout pages, which change with the window and the
//  text settings.
//

import EPUBKit
import Foundation

nonisolated struct EPUBPageLabels: Equatable, Sendable {
    struct Mark: Equatable, Sendable {
        let chapter: Int
        let offset: Int
        let label: String
    }

    /// In reading order.
    let marks: [Mark]
    /// Where each contents entry with a fragment starts, by entry id.
    var entryOffsets: [String: Int] = [:]

    var isEmpty: Bool { marks.isEmpty }

    /// Places the book's page list in its text, rendering (without images)
    /// each chapter a label points into. A label whose id the chapter lacks
    /// is dropped. Safe off the main actor.
    static func resolve(_ book: EPUBBook) -> EPUBPageLabels {
        let excluded = book.excludedChapters
        let marks = book.pageList.compactMap { entry -> Mark? in
            // A supplement has no pages, so its labels can't name one.
            guard !excluded.contains(entry.chapterIndex) else { return nil }
            var offset = 0
            if let fragment = entry.fragment {
                guard let anchor = book.anchorOffset(chapter: entry.chapterIndex, fragment: fragment) else { return nil }
                offset = anchor
            }
            return Mark(chapter: entry.chapterIndex, offset: offset, label: entry.label)
        }
        var labels = EPUBPageLabels(marks: marks.sorted { ($0.chapter, $0.offset) < ($1.chapter, $1.offset) })
        guard !labels.isEmpty else { return labels }
        for entry in book.contents {
            guard let fragment = entry.fragment,
                  let offset = book.anchorOffset(chapter: entry.chapterIndex, fragment: fragment) else { continue }
            labels.entryOffsets[entry.id] = offset
        }
        return labels
    }

    /// The print page a place falls on: the last label at or before it.
    func label(atChapter chapter: Int, offset: Int) -> String? {
        lastMark(atOrBefore: chapter, offset)?.label
    }

    /// The print page a chapter opens on: its first label, since a new chapter
    /// usually starts a new print page, else the one running on from before.
    func label(openingChapter chapter: Int) -> String? {
        marks.first { $0.chapter == chapter }?.label ?? label(atChapter: chapter, offset: 0)
    }

    /// The labels of a row of pages as one: "iv", or "iv–v" over a spread.
    static func span(_ labels: [String]) -> String? {
        guard let first = labels.first?.components(separatedBy: "–").first,
              let last = labels.last?.components(separatedBy: "–").last else { return nil }
        return first == last ? first : "\(first)–\(last)"
    }

    /// The print pages a layout page shows: the one in effect where it
    /// starts through the last that starts on it ("iv–v"), or just one. A
    /// chapter's first page starts at its first label, since a new chapter
    /// usually starts a new print page.
    func label(forPageIn chapter: Int, range: NSRange) -> String? {
        let starting = marks.filter { $0.chapter == chapter && NSLocationInRange($0.offset, range) }
        let current = lastMark(atOrBefore: chapter, range.location)
        guard let first = range.location == 0 ? starting.first ?? current : current ?? starting.first else { return nil }
        let last = starting.last ?? first
        return last == first ? first.label : "\(first.label)–\(last.label)"
    }

    /// Where a typed print page starts: "iv", "IV", "p. 12" or "page 12".
    func location(of typed: String) -> EPUBLocation? {
        let wanted = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var candidates = [wanted]
        for prefix in ["page ", "p. ", "p.", "p "] where wanted.hasPrefix(prefix) {
            candidates.append(String(wanted.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
        }
        for candidate in candidates where !candidate.isEmpty {
            if let mark = marks.first(where: { $0.label.lowercased() == candidate }) {
                return EPUBLocation(chapterIndex: mark.chapter, characterOffset: mark.offset)
            }
        }
        return nil
    }

    private func lastMark(atOrBefore chapter: Int, _ offset: Int) -> Mark? {
        // Binary search: the marks are in reading order.
        var low = 0
        var high = marks.count
        while low < high {
            let mid = (low + high) / 2
            if (marks[mid].chapter, marks[mid].offset) <= (chapter, offset) { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? marks[low - 1] : nil
    }
}
