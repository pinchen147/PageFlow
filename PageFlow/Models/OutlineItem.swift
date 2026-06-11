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
    /// The next sibling's page index — this section's end boundary, linked once
    /// at construction so callers get a page range from the item alone.
    private(set) var nextSiblingPageIndex: Int?

    // Private: `buildRoot` is the single construction path (it owns the
    // sibling-boundary linking); direct construction would silently skip it.
    private init?(outline: PDFOutline, path: String) {
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
        children = items.isEmpty ? nil : Self.linked(items)
    }

    /// Builds the root-level outline items for a document's outline root,
    /// linking sibling boundaries. The single construction path for a tree.
    static func buildRoot(from root: PDFOutline) -> [OutlineItem] {
        var items: [OutlineItem] = []
        let childCount = root.numberOfChildren
        if childCount > 0 {
            for index in 0..<childCount {
                guard let child = root.child(at: index),
                      let item = OutlineItem(outline: child, path: "root-\(index)") else { continue }
                items.append(item)
            }
        }
        return linked(items)
    }

    /// Stamps each item with its immediate next sibling's page index.
    private static func linked(_ items: [OutlineItem]) -> [OutlineItem] {
        var linked = items
        for index in linked.indices.dropLast() {
            linked[index].nextSiblingPageIndex = linked[index + 1].pageIndex
        }
        return linked
    }

    /// Calculates the page range for this outline section: from this item's
    /// page up to the next sibling's page, falling back to the end of the
    /// document when there is no next sibling, it has no page, or it points
    /// backwards.
    func pageRange(in document: PDFDocument) -> Range<Int> {
        guard let start = pageIndex, start < document.pageCount else {
            return 0..<0
        }

        if let nextPage = nextSiblingPageIndex, nextPage > start {
            return start..<nextPage
        }

        return start..<document.pageCount
    }
}
