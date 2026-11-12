//
//  EPUBContent+Navigation.swift
//  PageFlow
//
//  Labels for places in the book as the chrome and sidebar show them: Find's
//  matches by page, and the print edition's page labels beside the layout
//  pages, which Go to Page also accepts.
//

import EPUBKit
import Foundation

extension EPUBContent {
    /// The page a Find match is on, "~" while its chapter is still being
    /// paginated (its pages may yet shift).
    /// A match in a supplement, outside the pages, reads "Extra".
    func searchResultPageLabel(_ result: EPUBSearchResult) -> String {
        if pagination.isExcluded(result.chapterIndex) { return "Extra" }
        let page = pagination.globalPage(chapter: result.chapterIndex, offset: result.range.location) + 1
        return pagination.isPaginated(result.chapterIndex) ? "\(page)" : "~\(page)"
    }

    /// A highlight's or bookmark's page for a list: "Extra" in a supplement,
    /// which has no page.
    func pageListLabel(of highlight: EPUBHighlight) -> String {
        pagination.isExcluded(highlight.chapterIndex) ? "Extra" : "\(page(of: highlight) + 1)"
    }

    func pageListLabel(of bookmark: EPUBBookmark) -> String {
        pagination.isExcluded(bookmark.chapterIndex) ? "Extra" : "\(page(of: bookmark) + 1)"
    }

    // MARK: - Contents

    /// The page a contents entry opens on, as PDF's outline shows it: the print
    /// page when the book has labels, "~" while its chapter is still being
    /// paginated, "Extra" in a supplement, which has no page.
    func contentsPageLabel(of entry: EPUBContentsEntry) -> String {
        if pagination.isExcluded(entry.chapterIndex) { return "Extra" }
        if let printed = printedLabel(of: entry) { return printed }
        let page = pagination.globalPage(chapter: entry.chapterIndex, offset: offset(of: entry)) + 1
        return pagination.isPaginated(entry.chapterIndex) ? "\(page)" : "~\(page)"
    }

    // MARK: - Print page labels

    /// Places the book's page list in its text in the background; the chip
    /// and the sidebar show labels once it lands.
    func resolvePageLabels(of book: EPUBBook) {
        guard !book.pageList.isEmpty else { return }
        Task { [weak self] in
            let labels = await Task.detached(priority: .utility) { EPUBPageLabels.resolve(book) }.value
            self?.pageLabels = labels
        }
    }

    /// The print page a layout page shows ("iv"), when the book has labels.
    func printedPageLabel(forPage page: Int) -> String? {
        guard !pageLabels.isEmpty, let shown = pagination.page(at: page) else { return nil }
        let range = shown.range ?? NSRange(location: 0, length: 0)
        return pageLabels.label(forPageIn: shown.chapter, range: range)
    }

    /// The print page a contents entry starts on, when the book has labels.
    func printedLabel(of entry: EPUBContentsEntry) -> String? {
        guard !pageLabels.isEmpty else { return nil }
        guard entry.fragment != nil else { return pageLabels.label(openingChapter: entry.chapterIndex) }
        let start = pageLabels.entryOffsets[entry.id] ?? offset(of: entry)
        return pageLabels.label(atChapter: entry.chapterIndex, offset: start)
    }

    var goToPagePrompt: String { pageLabels.isEmpty ? "Page number" : "Page number or print page (iv, 123)" }

    /// Go to Page with what the reader typed: a print page label when the
    /// book has one by that name ("iv", "123", "p. 12"), else a layout page
    /// number. Returns the error to show, or nil once it jumps.
    func goToPage(typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if let target = pageLabels.location(of: trimmed) {
            jump(to: target)
            return nil
        }
        guard let page = Int(trimmed) else {
            return pageLabels.isEmpty ? "Please enter a valid number." : "No page “\(trimmed)” in this book."
        }
        let count = pagination.pageCount
        guard page > 0 else { return "Page must be 1 or more." }
        // While the book is still being paginated the count is an estimate:
        // a page past it is taken as the last known page.
        guard page <= count || !pagination.isComplete else {
            return "Page must be between 1 and \(count)."
        }
        jump(toPage: min(page, count) - 1)
        return nil
    }
}
