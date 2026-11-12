//
//  HeadingSlug.swift
//  PageFlow
//
//  How a link's `#heading` names a heading in any document: a note's, a PDF
//  outline entry, a book's contents entry.
//

import Foundation

nonisolated enum HeadingSlug {
    /// Lowercase words joined by hyphens, punctuation dropped (GitHub's anchors).
    static func of(_ title: String) -> String {
        title.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "_") }
            .joined(separator: "-")
    }

    /// The first of `titles` a link's fragment names. A fragment of only symbols
    /// names nothing, not the first title of only symbols.
    static func firstIndex(of fragment: String, in titles: [String]) -> Int? {
        let wanted = of(fragment.removingPercentEncoding ?? fragment)
        guard !wanted.isEmpty else { return nil }
        return titles.firstIndex { of($0) == wanted }
    }
}
