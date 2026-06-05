//
//  ExportScope.swift
//  PageFlow
//
//  Defines export targets for PDF to Markdown conversion.
//

import PDFKit

enum ExportScope {
    case currentPage(Int)
    case outlineSection(OutlineItem, [OutlineItem])
    case entireDocument

    func pageIndices(in document: PDFDocument) -> Range<Int> {
        let pageCount = document.pageCount
        guard pageCount > 0 else { return 0..<0 }

        switch self {
        case .currentPage(let index):
            let clamped = index.clamped(to: 0..<pageCount)
            return clamped..<(clamped + 1)

        case .outlineSection(let item, let siblings):
            return item.pageRange(in: document, siblings: siblings)

        case .entireDocument:
            return 0..<pageCount
        }
    }
}

// MARK: - Int Clamping

private extension Int {
    func clamped(to range: Range<Int>) -> Int {
        Swift.max(range.lowerBound, Swift.min(self, range.upperBound - 1))
    }

    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.max(range.lowerBound, Swift.min(self, range.upperBound))
    }
}
