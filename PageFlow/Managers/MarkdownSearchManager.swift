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

    /// Canonical UTF-16 navigation envelopes for visible matches, in document order.
    /// Highlight segments exclude recognized emphasis delimiters within each envelope.
    private(set) var searchResults: [NSRange] = []

    /// Index of the focused match within `searchResults`; 0 when there are none.
    private(set) var currentResultIndex: Int = 0

    /// Supplies the text a search reads. A closure (not a `MarkdownContent`
    /// reference) so the manager owns no retain cycle with its owner and so a test
    /// can drive find headlessly over a plain `String`.
    private let textProvider: () -> String
    private let navigationContext: (() -> MarkdownFindNavigation?)?

    /// The tab's scoped bus (fork P2) and stable documentId (= tab id). Posts are
    /// stamped with `documentId` as `object` so only this tab's mounted editor
    /// reacts.
    private let bus: MarkdownEditorBus
    private let documentId: String

    nonisolated private struct Match: Sendable {
        let visibleRange: NSRange
        let sourceRange: NSRange
        let sourceSegments: [NSRange]
    }

    @ObservationIgnored private var matches: [Match] = []
    @ObservationIgnored private var projectionSource: String?
    @ObservationIgnored private var cachedProjection: MarkdownEmphasisProjection?
    @ObservationIgnored private var searchedSource: String?
    private var searchedQuery: String?
    @ObservationIgnored private var pendingSearch: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration: UInt64 = 0

    init(
        bus: MarkdownEditorBus,
        documentId: String,
        textProvider: @escaping () -> String,
        editorController: MarkdownEditorController? = nil,
        navigationContext: (() -> MarkdownFindNavigation?)? = nil
    ) {
        self.bus = bus
        self.documentId = documentId
        self.textProvider = textProvider
        self.editorController = editorController
        self.navigationContext = navigationContext
    }

    // MARK: - Pure range finding (headless-testable)

    nonisolated private static func matches(of query: String, projection: MarkdownEmphasisProjection) -> [Match] {
        matchRanges(of: query, in: projection.visibleText).compactMap { visibleRange in
            let segments = projection.sourceSegments(forVisibleRange: visibleRange)
            guard let first = segments.first, let last = segments.last else { return nil }
            return Match(visibleRange: visibleRange,
                         sourceRange: NSRange(location: first.location, length: NSMaxRange(last) - first.location),
                         sourceSegments: segments)
        }
    }

    /// Case-insensitive, nonoverlapping UTF-16 occurrences in the supplied text.
    /// Production passes the cached emphasis projection's visible text here.
    nonisolated static func matchRanges(of query: String, in text: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let haystack = text as NSString
        var ranges: [NSRange] = []
        var searchStart = 0
        let total = haystack.length
        while searchStart < total {
            guard !Task.isCancelled else { return [] }
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

    var isSearching: Bool { !searchQuery.isEmpty && searchedQuery?.hasSameSource(as: searchQuery) != true }
    var resultCount: Int { isSearching || searchQuery.isEmpty ? 0 : searchResults.count }

    /// 1-based focused match number; 0 when there are no results. (`hasResults`
    /// comes from the `FindDriving` default.)
    var currentMatch: Int { hasResults ? currentResultIndex + 1 : 0 }

    func setReplacement(_ replacement: String) { replacementText = replacement }
    func setShowingReplacement(_ showing: Bool) { showsReplacement = showing }

    /// Replace the current live match and continue past the inserted text.
    @discardableResult
    func replaceCurrent() -> Bool {
        cancelPendingSearch()
        guard !searchQuery.isEmpty, let editorController else { return false }
        let source = textProvider()
        refreshResultsIfNeeded(force: false, source: source)
        guard hasResults else { postCurrentMatch(); return false }
        guard let selection = editorController.replaceEmphasisMatches(
            in: [matches[currentResultIndex].visibleRange], with: replacementText, expectedSource: source
        ) else { return false }
        let nextLocation = NSMaxRange(selection)
        refreshResultsIfNeeded(force: true)
        currentResultIndex = searchResults.firstIndex { $0.location >= nextLocation } ?? 0
        postCurrentMatch()
        return true
    }

    /// Apply the initial match snapshot once as one native Undo operation.
    @discardableResult
    func replaceAll() -> Int {
        cancelPendingSearch()
        guard !searchQuery.isEmpty, let editorController else { return 0 }
        let source = textProvider()
        refreshResultsIfNeeded(force: false, source: source)
        guard hasResults else { postCurrentMatch(); return 0 }
        let count = searchResults.count
        guard editorController.replaceEmphasisMatches(
            in: matches.map(\.visibleRange), with: replacementText, expectedSource: source, actionName: "Replace All"
        ) != nil else { return 0 }
        refreshResultsIfNeeded(force: true)
        postCurrentMatch()
        return count
    }

    // MARK: - Search

    /// Recompute matches for `searchQuery` over the live text and focus the first.
    /// An empty query routes to `clear()`.
    func runSearch() {
        cancelPendingSearch()
        guard !searchQuery.isEmpty else {
            clear()
            return
        }
        refreshResultsIfNeeded(force: true)
        postCurrentMatch()
    }

    /// Query typing never scans on the main actor. Coalesce bursts, cancel
    /// obsolete scans and accept only ranges for the current exact source.
    func scheduleSearch() {
        // The bar reports every change of the query, its own included: a query already
        // answered over this text keeps its matches and the reader's place in them.
        if pendingSearch == nil, !searchQuery.isEmpty, searchedQuery?.hasSameSource(as: searchQuery) == true,
           searchedSource?.hasSameSource(as: textProvider()) == true { return }
        cancelPendingSearch()
        searchedQuery = nil
        let hadResults = !searchResults.isEmpty
        searchResults = []
        matches = []
        currentResultIndex = 0
        if hadResults { clearHighlights() }
        guard !searchQuery.isEmpty else {
            searchedSource = nil
            return
        }
        let generation = searchGeneration
        let query = searchQuery
        pendingSearch = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) }
            catch { return }
            guard !Task.isCancelled, self?.searchGeneration == generation,
                  let source = self?.textProvider() else { return }
            let cached = self?.projectionSource?.hasSameSource(as: source) == true ? self?.cachedProjection : nil
            let semantic = self?.editorController?.usesSemanticStorage == true
            let worker = Task.detached(priority: .userInitiated) {
                if semantic {
                    return (nil as MarkdownEmphasisProjection?, Self.matchRanges(of: query, in: source).map {
                        Match(visibleRange: $0, sourceRange: $0, sourceSegments: [$0])
                    })
                }
                let projection = cached ?? MarkdownEmphasisProjection(source: source)
                return (Optional(projection), Self.matches(of: query, projection: projection))
            }
            let (projection, matches) = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self,
                  self.searchGeneration == generation,
                  self.searchQuery.hasSameSource(as: query) else { return }
            self.pendingSearch = nil
            guard source.hasSameSource(as: self.textProvider()) else {
                self.scheduleSearch()
                return
            }
            self.cachedProjection = projection
            self.projectionSource = source
            self.matches = matches
            self.searchResults = matches.map(\.sourceRange)
            self.currentResultIndex = 0
            self.searchedSource = source
            self.searchedQuery = query
            self.postCurrentMatch()
        }
    }

    private func cancelPendingSearch() {
        searchGeneration &+= 1
        pendingSearch?.cancel()
        pendingSearch = nil
    }

    var currentMatchText: String? {
        guard hasResults, let source = searchedSource as NSString?, searchResults.indices.contains(currentResultIndex),
              NSMaxRange(searchResults[currentResultIndex]) <= source.length else { return nil }
        return source.substring(with: searchResults[currentResultIndex])
    }

    func next() { move(by: 1) }

    func previous() { move(by: -1) }

    private func move(by step: Int) {
        cancelPendingSearch()
        guard !searchQuery.isEmpty else { return }
        if !refreshResultsIfNeeded(force: false), hasResults {
            let count = searchResults.count
            currentResultIndex = (currentResultIndex + step + count) % count
        }
        postCurrentMatch(explicitNavigation: true)
    }

    /// Changed source starts a fresh search; unchanged source retains navigation.
    /// Literal source equality keeps ranges valid across canonical-equivalent edits.
    @discardableResult
    private func refreshResultsIfNeeded(force: Bool, source: String? = nil) -> Bool {
        let source = source ?? textProvider()
        guard force || searchedSource?.hasSameSource(as: source) != true
                || searchedQuery?.hasSameSource(as: searchQuery) != true else { return false }
        if editorController?.usesSemanticStorage == true {
            matches = Self.matchRanges(of: searchQuery, in: source).map {
                Match(visibleRange: $0, sourceRange: $0, sourceSegments: [$0])
            }
            searchResults = matches.map(\.sourceRange)
            currentResultIndex = 0
            searchedSource = source
            searchedQuery = searchQuery
            return true
        }
        let projection: MarkdownEmphasisProjection
        if projectionSource?.hasSameSource(as: source) == true, let cachedProjection {
            projection = cachedProjection
        } else {
            projection = MarkdownEmphasisProjection(source: source)
            cachedProjection = projection
            projectionSource = source
        }
        matches = Self.matches(of: searchQuery, projection: projection)
        searchResults = matches.map(\.sourceRange)
        currentResultIndex = 0
        searchedSource = source
        searchedQuery = searchQuery
        return true
    }

    /// Clear the query, results, and the editor's highlights.
    func clear() {
        cancelPendingSearch()
        searchQuery = ""
        searchResults = []
        matches = []
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

    /// A note's editor built anew (it left the warm set with nothing to undo) has
    /// no paint of the search the bar still shows. Colors the matches again without
    /// moving the reader. A note changed meanwhile waits for its next search.
    func repaintHighlights() {
        guard hasResults, searchedSource?.hasSameSource(as: textProvider()) == true else { return }
        bus.postFindScroll(
            documentId: documentId,
            range: searchResults[currentResultIndex],
            currentIndex: currentResultIndex,
            allRanges: searchResults,
            allSourceSegments: matches.map(\.sourceSegments),
            paintsOnly: true,
            expectedSource: searchedSource
        )
    }

    /// Post the focused match to the engine so it highlights every match, reveals
    /// the focused one's collapsed source (P3), and scrolls it into view. Stamped
    /// with `documentId` (P2) so only this tab's editor reacts. No matches clear
    /// the previous highlights while retaining the query.
    private func postCurrentMatch(explicitNavigation: Bool = false) {
        guard hasResults else {
            clearHighlights()
            return
        }
        var navigation: MarkdownFindNavigation?
        if explicitNavigation, let navigationContext {
            guard let context = navigationContext() else { return }
            let generation = searchGeneration
            navigation = MarkdownFindNavigation(whileValid: { [weak self] in
                self?.searchGeneration == generation && context.whileValid()
            }, didNavigate: context.didNavigate)
        }
        bus.postFindScroll(
            documentId: documentId,
            range: searchResults[currentResultIndex],
            currentIndex: currentResultIndex,
            allRanges: searchResults,
            allSourceSegments: matches.map(\.sourceSegments),
            navigation: navigation,
            expectedSource: searchedSource
        )
    }
}
