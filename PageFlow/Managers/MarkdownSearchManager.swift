//
//  MarkdownSearchManager.swift
//  PageFlow
//
//  The Markdown half of the shared Find surface (S7a) — the `FindDriving` peer of
//  `SearchManager`. Finds query occurrences in the live markdown text and drives
//  the engine's find highlight/reveal through the tab's scoped bus (fork P2/P3):
//  each step posts `bus.findScrollToRange` (object = documentId) so the mounted
//  editor highlights all matches, reveals the focused match's collapsed source,
//  and scrolls it into view; `clear()` posts `bus.findClearHighlights`.
//
//  The range-finding itself is a pure, static function (`matchRanges(of:in:)`),
//  so result computation + next/prev wraparound are unit-testable headlessly with
//  no mounted editor and no NotificationCenter delivery.
//
//  Speaks the `FindDriving` vocabulary directly (`resultCount`/`currentMatch`/
//  `next`/`previous`/`runSearch`/`clear`) — no parallel native names to alias.
//

import Foundation
import MarkdownEngine

@Observable
@MainActor
final class MarkdownSearchManager: FindReplacing {
    /// The current query text (bound by the shared Find bar).
    var searchQuery: String = ""
    var replacementText: String = ""
    var showsReplacement = false
    @ObservationIgnored private let editorController: MarkdownEditorController?

    /// Character ranges of every match for the current query, in document order.
    /// Computed over the live editor's exact source (`textProvider`).
    private(set) var searchResults: [NSRange] = []

    /// Index of the focused match within `searchResults`; 0 when there are none.
    private(set) var currentResultIndex: Int = 0

    /// Supplies the text a search reads. A closure (not a `MarkdownContent`
    /// reference) so the manager owns no retain cycle with its owner and so a test
    /// can drive find headlessly over a plain `String`.
    private let textProvider: () -> String

    /// The tab's scoped bus (fork P2) and stable documentId (= tab id). Posts are
    /// stamped with `documentId` as `object` so only this tab's mounted editor
    /// reacts.
    private let bus: MarkdownEditorBus
    private let documentId: String

    @ObservationIgnored private var searchedSource: [UInt16]?
    @ObservationIgnored private var searchedQuery: [UInt16]?

    init(
        bus: MarkdownEditorBus,
        documentId: String,
        textProvider: @escaping () -> String,
        editorController: MarkdownEditorController? = nil
    ) {
        self.bus = bus
        self.documentId = documentId
        self.textProvider = textProvider
        self.editorController = editorController
    }

    // MARK: - Pure range finding (headless-testable)

    /// All ranges of `query` in `text`, case-insensitive, non-overlapping, in
    /// document order. Empty for an empty query or no match. Pure: no editor, no
    /// notifications — the unit-test seam for result count + ordering.
    static func matchRanges(of query: String, in text: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let haystack = text as NSString
        var ranges: [NSRange] = []
        var searchStart = 0
        let total = haystack.length
        while searchStart < total {
            let scope = NSRange(location: searchStart, length: total - searchStart)
            let found = haystack.range(of: query, options: .caseInsensitive, range: scope)
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            // Advance past this match; guard against a zero-length match (defensive).
            searchStart = found.location + max(found.length, 1)
        }
        return ranges
    }

    // MARK: - FindDriving surface

    var query: String { searchQuery }

    func setQuery(_ query: String) { searchQuery = query }

    var resultCount: Int { searchResults.count }

    /// 1-based focused match number; 0 when there are no results. (`hasResults`
    /// comes from the `FindDriving` default.)
    var currentMatch: Int { hasResults ? currentResultIndex + 1 : 0 }

    func setReplacement(_ replacement: String) { replacementText = replacement }
    func setShowingReplacement(_ showing: Bool) { showsReplacement = showing }

    /// Replace the current live match and continue past the inserted text.
    @discardableResult
    func replaceCurrent() -> Bool {
        guard !searchQuery.isEmpty, let editorController else { return false }
        let source = textProvider()
        refreshResultsIfNeeded(force: false, source: source)
        guard hasResults else { postCurrentMatch(); return false }
        let range = searchResults[currentResultIndex]
        guard editorController.replaceCharacters(
            in: [range], with: replacementText, expectedSource: source
        ) else { return false }
        let nextLocation = range.location + replacementText.utf16.count
        refreshResultsIfNeeded(force: true)
        currentResultIndex = searchResults.firstIndex { $0.location >= nextLocation } ?? 0
        postCurrentMatch()
        return true
    }

    /// Apply the initial match snapshot once as one native Undo operation.
    @discardableResult
    func replaceAll() -> Int {
        guard !searchQuery.isEmpty, let editorController else { return 0 }
        let source = textProvider()
        refreshResultsIfNeeded(force: false, source: source)
        guard hasResults else { postCurrentMatch(); return 0 }
        let count = searchResults.count
        guard editorController.replaceCharacters(
            in: searchResults, with: replacementText, expectedSource: source, actionName: "Replace All"
        ) else { return 0 }
        refreshResultsIfNeeded(force: true)
        postCurrentMatch()
        return count
    }

    // MARK: - Search

    /// Recompute matches for `searchQuery` over the live text and focus the first.
    /// An empty query routes to `clear()`.
    func runSearch() {
        guard !searchQuery.isEmpty else {
            clear()
            return
        }
        refreshResultsIfNeeded(force: true)
        postCurrentMatch()
    }

    func next() { move(by: 1) }

    func previous() { move(by: -1) }

    private func move(by step: Int) {
        guard !searchQuery.isEmpty else { return }
        if !refreshResultsIfNeeded(force: false), hasResults {
            let count = searchResults.count
            currentResultIndex = (currentResultIndex + step + count) % count
        }
        postCurrentMatch()
    }

    /// Changed source starts a fresh search; unchanged source retains navigation.
    /// Literal UTF16 snapshots keep ranges valid across canonical-equivalent edits.
    @discardableResult
    private func refreshResultsIfNeeded(force: Bool, source: String? = nil) -> Bool {
        let source = source ?? textProvider()
        let sourceUnits = Array(source.utf16)
        let queryUnits = Array(searchQuery.utf16)
        guard force || searchedSource != sourceUnits || searchedQuery != queryUnits else { return false }
        searchResults = Self.matchRanges(of: searchQuery, in: source)
        currentResultIndex = 0
        searchedSource = sourceUnits
        searchedQuery = queryUnits
        return true
    }

    /// Clear the query, results, and the editor's highlights.
    func clear() {
        searchQuery = ""
        searchResults = []
        currentResultIndex = 0
        searchedSource = nil
        searchedQuery = nil
        clearHighlights()
    }

    private func clearHighlights() {
        if let name = bus.findClearHighlights {
            NotificationCenter.default.post(name: name, object: documentId)
        }
    }

    // MARK: - Bus

    /// Post the focused match to the engine so it highlights every match, reveals
    /// the focused one's collapsed source (P3), and scrolls it into view. Stamped
    /// with `documentId` (P2) so only this tab's editor reacts. No matches clear
    /// the previous highlights while retaining the query.
    private func postCurrentMatch() {
        guard hasResults else {
            clearHighlights()
            return
        }
        bus.postFindScroll(
            documentId: documentId,
            range: searchResults[currentResultIndex],
            currentIndex: currentResultIndex,
            allRanges: searchResults
        )
    }
}
