//
//  SearchManagerTests.swift
//  PageFlowTests
//
//  SearchManager's highlight contract: recolor plans applied to the SAME
//  live PDFSelection instances on every call — the wrapper's highlight
//  signature and PDFView's shallow array copy both key on identity.
//

import AppKit
import PDFKit
import Testing
@testable import PageFlow

@MainActor
struct SearchManagerTests {
    private static let current = NSColor.systemYellow
    private static let others = NSColor.systemGray
    private static let sentinel = NSColor.systemPurple

    /// Three live selections from a real text page — no view required.
    private func makeSelections() throws -> [PDFSelection] {
        let document = try #require(makeTextDocument(text: "alpha beta alpha gamma alpha"))
        let hits = document.findString("alpha", withOptions: .caseInsensitive)
        try #require(hits.count == 3)
        return hits
    }

    @Test
    func firstHighlightWalksAllSelections() throws {
        let manager = SearchManager()
        manager.searchResults = try makeSelections()
        manager.currentResultIndex = 1

        let returned = manager.highlightedSelections(currentColor: Self.current, othersColor: Self.others)
        #expect(returned[0].color == Self.others)
        #expect(returned[1].color == Self.current)
        #expect(returned[2].color == Self.others)
    }

    /// Navigation within an unchanged result set must touch only the
    /// previously-current and newly-current selections (the fast path) —
    /// a sentinel painted on a bystander survives.
    @Test
    func navigationRecolorsOnlyThePair() throws {
        let manager = SearchManager()
        manager.searchResults = try makeSelections()
        manager.currentResultIndex = 0
        _ = manager.highlightedSelections(currentColor: Self.current, othersColor: Self.others)

        manager.searchResults[2].color = Self.sentinel
        manager.nextResult()
        let returned = manager.highlightedSelections(currentColor: Self.current, othersColor: Self.others)

        #expect(returned[0].color == Self.others)
        #expect(returned[1].color == Self.current)
        #expect(returned[2].color == Self.sentinel)
    }

    @Test
    func highlightingReturnsTheSameInstancesEveryCall() throws {
        let manager = SearchManager()
        manager.searchResults = try makeSelections()

        let first = manager.highlightedSelections(currentColor: Self.current, othersColor: Self.others)
        manager.nextResult()
        let second = manager.highlightedSelections(currentColor: Self.current, othersColor: Self.others)

        #expect(first.elementsEqual(second, by: ===))
        #expect(second.elementsEqual(manager.searchResults, by: ===))
    }

    /// clearSearch is the full recolor reset: the next result set must be
    /// fully walked again (a stale sentinel gets overwritten).
    @Test
    func clearSearchResetsTheRecolorState() throws {
        let manager = SearchManager()
        manager.searchResults = try makeSelections()
        _ = manager.highlightedSelections(currentColor: Self.current, othersColor: Self.others)

        manager.clearSearch()
        #expect(manager.searchResults.isEmpty)

        manager.searchResults = try makeSelections()
        manager.searchResults[2].color = Self.sentinel
        let returned = manager.highlightedSelections(currentColor: Self.current, othersColor: Self.others)
        #expect(returned[2].color == Self.others)
    }

    @Test
    func noResultsReturnsEmpty() {
        let manager = SearchManager()
        #expect(manager.highlightedSelections(currentColor: Self.current, othersColor: Self.others).isEmpty)
    }

    /// The restore path (tab re-activation) searches without debounce and
    /// clamps the restored index into the new result range.
    @Test
    func restoreSearchFindsHitsAndClampsTheIndex() async throws {
        let document = try #require(makeTextDocument(text: "alpha beta alpha"))
        let manager = SearchManager()

        manager.restoreSearch("alpha", resultIndex: 99, in: document)
        for _ in 0..<200 where manager.isSearching {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(!manager.isSearching)
        #expect(manager.searchResults.count == 2)
        #expect(manager.currentResultIndex == 1)
    }

    /// The reset asymmetry under test: a landing result set resets ONLY
    /// `fullyColored`, and that alone must force a full walk over the new
    /// selections — a bystander sentinel gets overwritten. Deleting the
    /// reset in performSearch's completion fails this (the stale pair path
    /// would leave the sentinel).
    @Test
    func aLandingResultSetForcesAFullRecolor() async throws {
        let document = try #require(makeTextDocument(text: "alpha beta alpha gamma alpha"))
        let manager = SearchManager()
        manager.searchResults = document.findString("alpha", withOptions: .caseInsensitive)
        _ = manager.highlightedSelections(currentColor: Self.current, othersColor: Self.others)

        manager.restoreSearch("alpha", resultIndex: 0, in: document)
        for _ in 0..<200 where manager.isSearching {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(manager.searchResults.count == 3)

        manager.searchResults[2].color = Self.sentinel
        let returned = manager.highlightedSelections(currentColor: Self.current, othersColor: Self.others)
        #expect(returned[2].color == Self.others)
    }

    /// The pair's application order (previous first, then current): when
    /// navigation wraps a single hit onto itself, the coinciding pair must
    /// end CURRENT-colored. Swapping the two writes fails this.
    @Test
    func navigatingASingleHitKeepsItCurrentColored() throws {
        let document = try #require(makeTextDocument(text: "only alpha here"))
        let manager = SearchManager()
        manager.searchResults = document.findString("alpha", withOptions: .caseInsensitive)
        try #require(manager.searchResults.count == 1)
        _ = manager.highlightedSelections(currentColor: Self.current, othersColor: Self.others)

        manager.nextResult()
        let returned = manager.highlightedSelections(currentColor: Self.current, othersColor: Self.others)
        #expect(returned[0].color == Self.current)
    }
}
