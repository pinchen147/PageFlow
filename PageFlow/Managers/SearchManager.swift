//
//  SearchManager.swift
//  PageFlow
//
//  Manages PDF search with result navigation and highlighting
//

import Foundation
import PDFKit
import Observation
import AppKit

@Observable
@MainActor
final class SearchManager {
    var searchQuery: String = ""
    var searchResults: [PDFSelection] = []
    var currentResultIndex: Int = 0
    var isSearching: Bool = false

    var hasResults: Bool {
        !searchResults.isEmpty
    }

    var currentResultNumber: Int {
        hasResults ? currentResultIndex + 1 : 0
    }

    var totalResults: Int {
        searchResults.count
    }

    func search(_ query: String, in document: PDFDocument) {
        guard !query.isEmpty else {
            clearSearch()
            return
        }

        searchQuery = query
        isSearching = true

        searchResults = document.findString(
            query,
            withOptions: .caseInsensitive
        )

        currentResultIndex = 0
    }

    func nextResult() {
        guard hasResults else { return }
        currentResultIndex = (currentResultIndex + 1) % searchResults.count
    }

    func previousResult() {
        guard hasResults else { return }
        currentResultIndex = (currentResultIndex - 1 + searchResults.count) % searchResults.count
    }

    func clearSearch() {
        searchQuery = ""
        searchResults = []
        currentResultIndex = 0
        isSearching = false
    }

    func currentSelection() -> PDFSelection? {
        guard hasResults else { return nil }
        return searchResults[currentResultIndex]
    }

    func highlightedSelections(currentColor: NSColor, othersColor: NSColor) -> [PDFSelection] {
        guard hasResults else { return [] }

        for (index, selection) in searchResults.enumerated() {
            selection.color = index == currentResultIndex ? currentColor : othersColor
        }
        return searchResults
    }
}
