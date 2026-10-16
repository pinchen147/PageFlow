//
//  MarkdownSearchManagerTests.swift
//  PageFlowTests
//
//  S7a Find: pure range finding, navigation, and scoped delivery after the live
//  source changes. Tests inject current text and observe the actual editor bus;
//  no native window is needed to verify its source ranges.
//

import Foundation
import Testing
import MarkdownEngine
@testable import PageFlow

@MainActor
struct MarkdownSearchManagerTests {

    enum SourceChange: String, CaseIterable {
        case insertionBeforeHits
        case sameLengthReplacement
        case externalReplacement
        case replacementWithoutMatches
        case literalUnicodePrefix

        var initial: String {
            let body = "needle 😀 needle tail needle"
            return self == .literalUnicodePrefix ? "é " + body : body
        }

        var replacement: String {
            switch self {
            case .insertionBeforeHits: return "😀\r\n" + initial
            case .sameLengthReplacement: return "xxxxxx 😀 needle tail xxxxxx"
            case .externalReplacement: return "replacement\r\nneedle 🧭 needle"
            case .replacementWithoutMatches: return "replacement with no matching word\r\n😀"
            case .literalUnicodePrefix: return "e\u{301} needle 😀 needle tail needle"
            }
        }

        var matchCount: Int {
            switch self {
            case .insertionBeforeHits, .literalUnicodePrefix: return 3
            case .sameLengthReplacement: return 1
            case .externalReplacement: return 2
            case .replacementWithoutMatches: return 0
            }
        }
    }

    enum Navigation: String, CaseIterable { case next, previous }

    @MainActor private final class LiveSource {
        var text: String
        var scrollReceipts: [Notification] = []
        var clearReceipts: [Notification] = []

        init(_ text: String) { self.text = text }
    }

    /// A manager over a fixed text. The bus has nil find names, so `postCurrentMatch`
    /// / `clear` post nothing — the test never depends on NotificationCenter.
    private func makeManager(text: String) -> MarkdownSearchManager {
        MarkdownSearchManager(
            bus: MarkdownEditorBus(),       // nil find names ⇒ posts are no-ops
            documentId: "test-doc",
            textProvider: { text }
        )
    }

    // MARK: - Pure range finding

    @Test
    func matchRangesFindsAllOccurrencesInOrder() {
        let text = "alpha beta alpha gamma alpha"
        let ranges = MarkdownSearchManager.matchRanges(of: "alpha", in: text)
        #expect(ranges.count == 3)
        #expect(ranges[0] == NSRange(location: 0, length: 5))
        #expect(ranges[1] == NSRange(location: 11, length: 5))
        #expect(ranges[2] == NSRange(location: 23, length: 5))
    }

    @Test
    func matchRangesIsCaseInsensitive() {
        let text = "Title TITLE title TiTlE"
        let ranges = MarkdownSearchManager.matchRanges(of: "title", in: text)
        #expect(ranges.count == 4)
        // The found ranges carry the ORIGINAL (mixed-case) text's substrings.
        #expect((text as NSString).substring(with: ranges[0]) == "Title")
        #expect((text as NSString).substring(with: ranges[1]) == "TITLE")
    }

    @Test
    func matchRangesEmptyQueryReturnsNothing() {
        #expect(MarkdownSearchManager.matchRanges(of: "", in: "anything").isEmpty)
    }

    @Test
    func matchRangesNoMatchReturnsNothing() {
        #expect(MarkdownSearchManager.matchRanges(of: "zzz", in: "alpha beta").isEmpty)
    }

    @Test
    func matchRangesHandlesOverlappingCandidatesNonOverlapping() {
        // "aa" in "aaaa" → matches at 0 and 2 (non-overlapping advance).
        let ranges = MarkdownSearchManager.matchRanges(of: "aa", in: "aaaa")
        #expect(ranges.count == 2)
        #expect(ranges[0] == NSRange(location: 0, length: 2))
        #expect(ranges[1] == NSRange(location: 2, length: 2))
    }

    // MARK: - runSearch / result surface

    @Test
    func runSearchPopulatesResultsAndFocusesFirst() {
        let manager = makeManager(text: "one two one two one")
        manager.searchQuery = "one"
        manager.runSearch()

        #expect(manager.resultCount == 3)
        #expect(manager.currentResultIndex == 0)
        #expect(manager.currentMatch == 1)   // 1-based
        #expect(manager.hasResults)
    }

    @Test
    func runSearchEmptyQueryClearsResults() {
        let manager = makeManager(text: "one two")
        manager.searchQuery = "one"
        manager.runSearch()
        #expect(manager.hasResults)

        manager.searchQuery = ""
        manager.runSearch()
        #expect(!manager.hasResults)
        #expect(manager.resultCount == 0)
        #expect(manager.currentMatch == 0)
    }

    @Test
    func runSearchCaseInsensitive() {
        let manager = makeManager(text: "Swift swift SWIFT")
        manager.searchQuery = "swift"
        manager.runSearch()
        #expect(manager.resultCount == 3)
    }

    /// The provider owns the source snapshot; range finding must use that
    /// snapshot rather than reach into a separate durable model.
    @Test
    func runSearchComputesRangesOverProviderSnapshot() {
        let storage = "See [[Name|0xABCDEF]] and [[Name|0x123456]]."
        let display = "See [[Name]] and [[Name]]."
        let manager = MarkdownSearchManager(
            bus: MarkdownEditorBus(),
            documentId: "wiki",
            textProvider: { display }     // the DISPLAY string the engine highlights
        )
        manager.searchQuery = "Name"
        manager.runSearch()

        // Ranges are exactly those over the DISPLAY text the provider returned.
        #expect(manager.searchResults == MarkdownSearchManager.matchRanges(of: "Name", in: display))
        #expect(manager.resultCount == 2)
        // ...and NOT the storage-form ranges (the second match's location differs
        // because the piped ids lengthen the storage string).
        #expect(manager.searchResults != MarkdownSearchManager.matchRanges(of: "Name", in: storage))
    }

    // MARK: - Navigation wraparound (1-based currentMatch)

    @Test
    func nextWrapsAroundToFirst() {
        let manager = makeManager(text: "x x x")   // three "x"
        manager.searchQuery = "x"
        manager.runSearch()
        #expect(manager.currentMatch == 1)

        manager.next()
        #expect(manager.currentMatch == 2)
        manager.next()
        #expect(manager.currentMatch == 3)
        manager.next()                              // wrap 3 → 1
        #expect(manager.currentMatch == 1)
    }

    @Test
    func previousWrapsAroundToLast() {
        let manager = makeManager(text: "x x x")
        manager.searchQuery = "x"
        manager.runSearch()
        #expect(manager.currentMatch == 1)

        manager.previous()                          // wrap 1 → 3
        #expect(manager.currentMatch == 3)
        manager.previous()
        #expect(manager.currentMatch == 2)
    }

    @Test
    func navigationNoOpsWithoutResults() {
        let manager = makeManager(text: "nothing here")
        manager.searchQuery = "zzz"
        manager.runSearch()
        #expect(!manager.hasResults)

        manager.next()      // must not crash / move
        manager.previous()
        #expect(manager.currentResultIndex == 0)
        #expect(manager.currentMatch == 0)
    }

    @Test("navigation refreshes source ranges without changing the query",
          arguments: SourceChange.allCases, Navigation.allCases)
    func navigationAfterSourceChange(change: SourceChange, navigation: Navigation) throws {
        let source = LiveSource(change.initial)
        let documentID = UUID().uuidString
        let scrollName = Notification.Name("FindBoundary.scroll." + documentID)
        let clearName = Notification.Name("FindBoundary.clear." + documentID)
        let bus = MarkdownEditorBus(
            findScrollToRange: scrollName, findClearHighlights: clearName, scopeByObject: true
        )
        let center = NotificationCenter.default
        let scrollObserver = center.addObserver(forName: scrollName, object: nil, queue: nil) { notification in
            MainActor.assumeIsolated { source.scrollReceipts.append(notification) }
        }
        let clearObserver = center.addObserver(forName: clearName, object: nil, queue: nil) { notification in
            MainActor.assumeIsolated { source.clearReceipts.append(notification) }
        }
        defer {
            center.removeObserver(scrollObserver)
            center.removeObserver(clearObserver)
        }
        let manager = MarkdownSearchManager(bus: bus, documentId: documentID, textProvider: { source.text })
        manager.setQuery("needle")
        manager.runSearch()
        try #require(manager.resultCount == 3)
        try #require(source.scrollReceipts.count == 1)
        source.scrollReceipts.removeAll()
        source.clearReceipts.removeAll()
        if change == .sameLengthReplacement {
            try #require(change.initial.utf16.count == change.replacement.utf16.count)
        } else if change == .literalUnicodePrefix {
            try #require(change.initial == change.replacement)
            try #require(Array(change.initial.utf16) != Array(change.replacement.utf16))
        }

        source.text = change.replacement
        switch navigation {
        case .next: manager.next()
        case .previous: manager.previous()
        }

        #expect(manager.query == "needle")
        #expect(manager.resultCount == change.matchCount)
        #expect(Array(source.text.utf16) == Array(change.replacement.utf16))
        if change.matchCount == 0 {
            #expect(manager.currentMatch == 0)
            #expect(source.scrollReceipts.isEmpty)
            try #require(source.clearReceipts.count == 1)
            #expect(source.clearReceipts[0].object as? String == documentID)
            return
        }
        try #require(source.scrollReceipts.count == 1)
        let receipt = source.scrollReceipts[0]
        #expect(receipt.object as? String == documentID)
        let info = try #require(receipt.userInfo)
        let focused = try #require(info["range"] as? NSRange)
        let ranges = try #require(info["allRanges"] as? [NSRange])
        let currentIndex = try #require(info["currentIndex"] as? Int)
        #expect(ranges.count == change.matchCount)
        try #require(ranges.indices.contains(currentIndex))
        #expect(focused == ranges[currentIndex])
        #expect(manager.currentMatch == currentIndex + 1)
        let currentText = source.text as NSString
        for range in ranges {
            try #require(range.location != NSNotFound && range.location >= 0 && range.length > 0
                         && NSMaxRange(range) <= currentText.length)
            #expect(currentText.substring(with: range) == "needle")
        }
    }

    // MARK: - clear

    @Test
    func clearResetsEverything() {
        let manager = makeManager(text: "alpha alpha")
        manager.searchQuery = "alpha"
        manager.runSearch()
        #expect(manager.hasResults)

        manager.clear()
        #expect(manager.searchQuery.isEmpty)
        #expect(manager.resultCount == 0)
        #expect(manager.currentResultIndex == 0)
        #expect(manager.currentMatch == 0)
        #expect(!manager.hasResults)
    }

    // MARK: - FindDriving conformance surface

    @Test
    func findDrivingSurfaceReflectsState() {
        let manager = makeManager(text: "match match match")
        let driver: any FindDriving = manager

        driver.setQuery("match")
        driver.runSearch()
        #expect(driver.resultCount == 3)
        #expect(driver.currentMatch == 1)
        #expect(driver.hasResults)

        driver.next()
        #expect(driver.currentMatch == 2)

        driver.clear()
        #expect(driver.resultCount == 0)
        #expect(!driver.hasResults)
        #expect(driver.query.isEmpty)
    }
}
