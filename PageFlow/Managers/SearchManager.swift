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
    @ObservationIgnored private var fullyColored = false
    @ObservationIgnored private var lastColoredIndex = 0

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
        performSearch(query, in: document, initialResultIndex: 0, debounce: true)
    }

    func restoreSearch(_ query: String, resultIndex: Int, in document: PDFDocument) {
        performSearch(query, in: document, initialResultIndex: resultIndex, debounce: false)
    }

    private func performSearch(_ query: String, in document: PDFDocument, initialResultIndex: Int, debounce: Bool) {
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
            // Collapse a burst of keystrokes into one trailing search: each new
            // keystroke cancels the prior task before its debounce elapses, so the
            // expensive full-document findString runs once the user pauses typing,
            // not once per character.
            if debounce {
                try? await Task.sleep(nanoseconds: 220_000_000)
                guard !Task.isCancelled else { return }
            }
            let results = doc.findString(q, withOptions: .caseInsensitive)
            guard let self else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                guard self.searchQuery == q else { return }
                self.searchResults = results
                self.fullyColored = false
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
        fullyColored = false
        lastColoredIndex = 0
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

        if fullyColored, lastColoredIndex < searchResults.count {
            // Navigation only (result set unchanged): recolor just the two
            // affected selections rather than walking the whole set.
            searchResults[lastColoredIndex].color = othersColor
            searchResults[currentResultIndex].color = currentColor
        } else {
            for (index, selection) in searchResults.enumerated() {
                selection.color = index == currentResultIndex ? currentColor : othersColor
            }
            fullyColored = true
        }
        lastColoredIndex = currentResultIndex
        return searchResults
    }
}
