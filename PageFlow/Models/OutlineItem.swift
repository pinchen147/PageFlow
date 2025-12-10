//
//  OutlineItem.swift
//  PageFlow
//
//  Represents a PDF outline entry for the sidebar.
//

import Foundation
import PDFKit

struct OutlineItem: Identifiable {
    let id = UUID()
    let title: String
    let pageIndex: Int?
    let children: [OutlineItem]?

    init?(outline: PDFOutline) {
        let label = outline.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        title = label?.isEmpty == false ? label! : "Untitled"
        if let page = outline.destination?.page, let document = page.document {
            pageIndex = document.index(for: page)
        } else {
            pageIndex = nil
        }

        var items: [OutlineItem] = []
        let childCount = outline.numberOfChildren
        if childCount > 0 {
            for index in 0..<childCount {
                guard let child = outline.child(at: index),
                      let item = OutlineItem(outline: child) else { continue }
                items.append(item)
            }
        }
        children = items.isEmpty ? nil : items
    }
}
