import Foundation
import EPUBKit
import Observation

@Observable
@MainActor
final class EPUBSearchManager: FindResultsListing {
    private(set) var query = ""
    private(set) var results: [EPUBSearchResult] = [] {
        didSet {
            resultsByChapter = Dictionary(grouping: results, by: \.chapterIndex).mapValues { $0.map(\.range) }
            resultsRevision &+= 1
            if results.isEmpty { resultsWentAway() }
        }
    }
    /// The matches grouped by chapter, so a page looks up only its own.
    @ObservationIgnored private(set) var resultsByChapter: [Int: [NSRange]] = [:]
    /// Changes whenever the matches do, for redrawing pages.
    private(set) var resultsRevision = 0
    private(set) var currentIndex = 0
    /// Chapters the last search could not read, so its results may be partial.
    private(set) var unsearchedChapters: [Int] = []
    /// Whether a whole-book scan is under way.
    private(set) var isSearching = false
    /// Bumps when the reader asks for the results list (the Find bar's button).
    private(set) var resultsListRequest = 0

    @ObservationIgnored var searchProvider: (String) async throws -> EPUBSearchOutcome = { _ in EPUBSearchOutcome(results: []) }
    @ObservationIgnored var reveal: (EPUBSearchResult) -> Void = { _ in }
    /// Next or Previous is about to go to a match: a jump Back returns from.
    @ObservationIgnored var willStep: (EPUBSearchResult) -> Void = { _ in }
    /// A search found nothing, or Find cleared.
    @ObservationIgnored var resultsWentAway: () -> Void = {}
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var revealGeneration = 0

    /// A match's words, once its chapter has been searched.
    @ObservationIgnored var matchText: (EPUBSearchResult) -> String? = { _ in nil }
    var currentMatchText: String? { results.indices.contains(currentIndex) ? matchText(results[currentIndex]) : nil }

    var resultCount: Int { results.count }
    var currentMatch: Int { results.isEmpty ? 0 : currentIndex + 1 }

    func setQuery(_ query: String) {
        guard query != self.query else { return }
        guard !query.isEmpty else { return clear() }
        searchTask?.cancel()
        debounceTask?.cancel()
        self.query = query
        isSearching = true
        if !results.isEmpty { results = [] }
        currentIndex = 0
        unsearchedChapters = []
    }

    /// Pending results can still update after navigation, but must not move the reader back.
    func cancelPendingReveal() { revealGeneration &+= 1 }

    func runSearch() {
        runSearch(revealGeneration: revealGeneration)
    }

    private func runSearch(revealGeneration: Int) {
        debounceTask?.cancel()
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            await self?.performSearch(revealGeneration: revealGeneration)
        }
    }

    /// Query typing coalesces: a whole-book scan is expensive, so wait for a
    /// pause before launching one and let a new keystroke replace it.
    func scheduleSearch() {
        let generation = revealGeneration
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.runSearch(revealGeneration: generation)
        }
    }

    func performSearch() async {
        await performSearch(revealGeneration: revealGeneration)
    }

    private func performSearch(revealGeneration: Int) async {
        let requestedQuery = query
        guard !requestedQuery.isEmpty else { return clear() }
        isSearching = true
        // A scan replaced by a rerun of the same query leaves the new one searching.
        defer { if query == requestedQuery, !Task.isCancelled { isSearching = false } }
        do {
            let found = try await searchProvider(requestedQuery)
            guard !Task.isCancelled, query == requestedQuery else { return }
            let mayReveal = revealGeneration == self.revealGeneration
            let selected = results.indices.contains(currentIndex) ? results[currentIndex] : nil
            results = found.results
            unsearchedChapters = found.unsearchedChapters
            if !mayReveal, let selected, let index = results.firstIndex(of: selected) {
                currentIndex = index
            } else {
                currentIndex = found.results.firstIndex(where: canReveal) ?? 0
            }
            if mayReveal, results.indices.contains(currentIndex), canReveal(results[currentIndex]) { revealCurrent() }
        } catch is CancellationError {
            // A newer query's scan superseded this one; leave its results be.
        } catch {
            guard !Task.isCancelled, query == requestedQuery else { return }
            results = []
            unsearchedChapters = []
            currentIndex = 0
        }
    }

    /// Makes a match current without revealing it: the results list jumps
    /// there itself, so Back returns.
    func setCurrentIndex(_ index: Int) {
        guard results.indices.contains(index) else { return }
        cancelPendingReveal()
        currentIndex = index
    }

    func showResultsList() { resultsListRequest &+= 1 }

    /// Whether typing or stepping may show a match where it is. A supplement's
    /// opens a sheet over the book, so it waits for the results list.
    var canReveal: (EPUBSearchResult) -> Bool = { _ in true }

    func next() { move(by: 1) }
    func previous() { move(by: -1) }

    func clear() {
        query = ""
        debounceTask?.cancel()
        debounceTask = nil
        searchTask?.cancel()
        searchTask = nil
        results = []
        unsearchedChapters = []
        isSearching = false
        currentIndex = 0
    }

    private func move(by amount: Int) {
        guard !results.isEmpty else { return runSearch() }
        var index = currentIndex
        for _ in results.indices {
            index = (index + amount + results.count) % results.count
            if canReveal(results[index]) {
                currentIndex = index
                return stepToCurrent()
            }
        }
        // Only supplements hold matches: stepping is asking to see one.
        currentIndex = (currentIndex + amount + results.count) % results.count
        stepToCurrent()
    }

    private func stepToCurrent() {
        cancelPendingReveal()
        willStep(results[currentIndex])
        revealCurrent()
    }

    private func revealCurrent() {
        guard results.indices.contains(currentIndex) else { return }
        reveal(results[currentIndex])
    }
}
