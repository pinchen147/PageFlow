//
//  OutlineItem.swift
//  PageFlow
//
//  Represents a PDF outline entry for the sidebar.
//

import Foundation
import PDFKit

struct OutlineItem: Identifiable {
    let id: String
    let title: String
    let pageIndex: Int?
    let children: [OutlineItem]?

    init?(outline: PDFOutline, path: String = "root") {
        let trimmedLabel = outline.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = trimmedLabel.isEmpty ? "Untitled" : trimmedLabel
        if let page = outline.destination?.page, let document = page.document {
            pageIndex = document.index(for: page)
        } else {
            pageIndex = nil
        }

        let baseID = "\(path)|\(title)|\(pageIndex ?? -1)"
        id = baseID

        var items: [OutlineItem] = []
        let childCount = outline.numberOfChildren
        if childCount > 0 {
            for index in 0..<childCount {
                guard let child = outline.child(at: index),
                      let item = OutlineItem(outline: child, path: "\(baseID)-\(index)") else { continue }
                items.append(item)
            }
        }
        children = items.isEmpty ? nil : items
    }

    /// Calculates the page range for this outline section
    func pageRange(in document: PDFDocument, siblings: [OutlineItem]) -> Range<Int> {
        guard let start = pageIndex, start < document.pageCount else {
            return 0..<0
        }

        // Find next sibling's page to determine end boundary
        if let selfIndex = siblings.firstIndex(where: { $0.id == id }),
           selfIndex + 1 < siblings.count,
           let nextPage = siblings[selfIndex + 1].pageIndex,
           nextPage > start {
            return start..<nextPage
        }

        return start..<document.pageCount
    }
}
