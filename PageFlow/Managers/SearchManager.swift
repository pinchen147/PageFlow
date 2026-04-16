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
    deinit {
        #if DEBUG
        Swift.print("[deinit] SearchManager")
        #endif
    }

    var searchQuery: String = ""
    var searchResults: [PDFSelection] = []
    var currentResultIndex: Int = 0
    var isSearching: Bool = false

    private var searchTask: Task<Void, Never>?

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
        performSearch(query, in: document, initialResultIndex: 0)
    }

    func restoreSearch(_ query: String, resultIndex: Int, in document: PDFDocument) {
        performSearch(query, in: document, initialResultIndex: resultIndex)
    }

    private func performSearch(_ query: String, in document: PDFDocument, initialResultIndex: Int) {
        guard !query.isEmpty else {
            clearSearch()
            return
        }

        searchTask?.cancel()
        searchQuery = query
        isSearching = true

        let doc = document
        let q = query
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let results = doc.findString(q, withOptions: .caseInsensitive)
            guard let self else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                guard self.searchQuery == q else { return }
                self.searchResults = results
                self.currentResultIndex = min(max(0, initialResultIndex), max(0, results.count - 1))
                self.isSearching = false
            }
        }
    }

    func nextResult() {
        let count = searchResults.count
        guard count > 0 else { return }
        currentResultIndex = (currentResultIndex + 1) % count
    }

    func previousResult() {
        let count = searchResults.count
        guard count > 0 else { return }
        currentResultIndex = (currentResultIndex - 1 + count) % count
    }

    func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchQuery = ""
        searchResults = []
        currentResultIndex = 0
        isSearching = false
    }

    func currentSelection() -> PDFSelection? {
        let results = searchResults
        let index = currentResultIndex
        guard index < results.count else { return nil }
        return results[index]
    }

    func highlightedSelections(currentColor: NSColor, othersColor: NSColor) -> [PDFSelection] {
        guard hasResults else { return [] }

        for (index, selection) in searchResults.enumerated() {
            selection.color = index == currentResultIndex ? currentColor : othersColor
        }
        return searchResults
    }
}
