//
//  SearchRecolorTests.swift
//  PageFlowTests
//
//  The Search recolor decision: full walk for a changed result set,
//  pair-only recolor for navigation within an unchanged one.
//

import Testing
@testable import PageFlow

struct SearchRecolorTests {
    @Test
    func firstHighlightOfAResultSetWalksAll() {
        let (plan, next) = SearchRecolor.plan(state: .init(), currentIndex: 2, resultCount: 5)
        #expect(plan == .all)
        #expect(next == .init(fullyColored: true, lastColoredIndex: 2))
    }

    @Test
    func navigationRecolorsExactlyThePair() {
        let colored = SearchRecolor.State(fullyColored: true, lastColoredIndex: 2)
        let (plan, next) = SearchRecolor.plan(state: colored, currentIndex: 4, resultCount: 5)
        #expect(plan == .pair(previous: 2, current: 4))
        #expect(next == .init(fullyColored: true, lastColoredIndex: 4))
    }

    /// When previous and current coincide, the pair's documented application
    /// order (previous first, then current) means the current color wins.
    @Test
    func coincidingIndicesStillPairWithCurrentLast() {
        let colored = SearchRecolor.State(fullyColored: true, lastColoredIndex: 3)
        let (plan, _) = SearchRecolor.plan(state: colored, currentIndex: 3, resultCount: 5)
        #expect(plan == .pair(previous: 3, current: 3))
    }

    /// A landing result set resets only `fullyColored` (the manager's reset
    /// asymmetry) — that alone must force the full walk.
    @Test
    func newResultSetForcesAFullWalk() {
        var state = SearchRecolor.State(fullyColored: true, lastColoredIndex: 4)
        state.fullyColored = false
        let (plan, _) = SearchRecolor.plan(state: state, currentIndex: 0, resultCount: 3)
        #expect(plan == .all)
    }

    /// A stale last-colored index (result set shrank without the reset)
    /// degrades to a full walk — never an out-of-bounds pair.
    @Test
    func staleIndexDegradesToAFullWalk() {
        let stale = SearchRecolor.State(fullyColored: true, lastColoredIndex: 7)
        let (plan, next) = SearchRecolor.plan(state: stale, currentIndex: 1, resultCount: 3)
        #expect(plan == .all)
        #expect(next == .init(fullyColored: true, lastColoredIndex: 1))
    }
}
