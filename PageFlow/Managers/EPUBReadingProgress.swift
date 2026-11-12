//
//  EPUBReadingProgress.swift
//  PageFlow
//
//  Progress through the book for the page chip.
//

import Foundation

/// Progress through a book at the reader's page.
struct EPUBReadingProgress: Equatable {
    /// Through the last page shown, 0–1.
    var fraction: Double
    /// The page count is still growing while the book is paginated.
    var isEstimate: Bool

    /// "12%", or "~12%" while paginating. Floored, so 100% is the last page.
    var percentLabel: String {
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded(.down))
        return (isEstimate ? "~" : "") + "\(percent)%"
    }

    /// Progress through the last page shown, estimating unpaginated chapters
    /// from the chapters whose page counts are ready.
    static func at(page: Int, pagesPerRow: Int, pagination: EPUBPagination) -> EPUBReadingProgress? {
        let count = pagination.pageCount
        guard count > 0 else { return nil }
        let lastShown = min(count, page + max(1, pagesPerRow))
        let total = pagination.estimatedPages(before: count)
        return EPUBReadingProgress(fraction: pagination.estimatedPages(before: lastShown) / total,
                                   isEstimate: !pagination.isComplete)
    }
}

extension EPUBContent {
    /// Progress at the reader's page; nil before the book has pages.
    var readingProgress: EPUBReadingProgress? {
        EPUBReadingProgress.at(page: currentPage, pagesPerRow: currentRow.count, pagination: pagination)
    }
}
