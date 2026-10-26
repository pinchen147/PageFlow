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
    /// Deliberately not observable: recolor bookkeeping must never invalidate
    /// views (the wrapper reads highlights inside updateNSView; ADR-0001).
    @ObservationIgnored private var recolorState = SearchRecolor.State()

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
                // New result set: force the next highlight pass to walk all
                // hits. lastColoredIndex deliberately survives (clearSearch is
                // the full reset) — SearchRecolor degrades a stale index to a
                // full walk anyway.
                self.recolorState.fullyColored = false
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
        recolorState = SearchRecolor.State()
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

        let (plan, next) = SearchRecolor.plan(
            state: recolorState,
            currentIndex: currentResultIndex,
            resultCount: searchResults.count
        )
        switch plan {
        case .pair(let previous, let current):
            // Navigation only (result set unchanged): recolor just the two
            // affected selections rather than walking the whole set.
            searchResults[previous].color = othersColor
            searchResults[current].color = currentColor
        case .all:
            for (index, selection) in searchResults.enumerated() {
                selection.color = index == currentResultIndex ? currentColor : othersColor
            }
        }
        recolorState = next

        // Always the SAME instances: the wrapper's highlight signature and
        // PDFView's shallow array copy both key on selection identity, and
        // re-assigning `highlightedSelections` is the redraw trigger.
        return searchResults
    }
}

// MARK: - PDFFindDriver (S7a)

/// The PDF half of the shared Find surface — a lightweight value adapter that lets
/// the shared `SearchBar` drive PDF find without `SearchManager` itself having to
/// know about the bar. It holds the tab's `SearchManager` and a weak `PDFManager`;
/// `runSearch()` resolves the live document and stepping pushes the PDF nav state,
/// so PDF find stays byte-identical to the old inline bar (which read
/// `pdfManager.document` and pushed nav state itself). A value type constructed
/// fresh where needed (`PDFTabView`'s `body`, `TabManager.activeFindDriver`) —
/// building it mutates no observable state.
@MainActor
struct PDFFindDriver: FindDriving {
    let searchManager: SearchManager
    weak var pdfManager: PDFManager?

    var query: String { searchManager.searchQuery }

    func setQuery(_ query: String) { searchManager.searchQuery = query }

    var resultCount: Int { searchManager.totalResults }

    /// 1-based focused match; `currentResultNumber` is already 0 when empty.
    var currentMatch: Int { searchManager.currentResultNumber }

    func runSearch() {
        guard let document = pdfManager?.document else { return }
        searchManager.search(searchManager.searchQuery, in: document)
    }

    func next() {
        guard hasResults else { return }
        pdfManager?.pushNavigationState()
        searchManager.nextResult()
    }

    func previous() {
        guard hasResults else { return }
        pdfManager?.pushNavigationState()
        searchManager.previousResult()
    }

    func clear() {
        searchManager.clearSearch()
    }
}
