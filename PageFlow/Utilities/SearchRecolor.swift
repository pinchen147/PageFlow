//
//  SearchRecolor.swift
//  PageFlow
//
//  The pure decision of which search-hit selections to recolor when the
//  current result changes.
//

import Foundation

/// The pure decision behind SearchManager's highlight recoloring: a changed
/// (or never-colored) result set walks every selection; navigation within an
/// unchanged set recolors exactly the previously-current and newly-current
/// pair. The caller threads `State` through and applies the returned `Plan`
/// to its live `PDFSelection`s — this module never touches PDFKit.
enum SearchRecolor {
    struct State: Equatable {
        /// Whether every selection in the current result set has been colored
        /// at least once. False again whenever a new result set lands, which
        /// is what forces the next pass to walk all hits.
        var fullyColored = false
        /// The index colored as "current" by the last applied plan.
        var lastColoredIndex = 0
    }

    enum Plan: Equatable {
        /// Walk every selection, coloring the current index as current.
        case all
        /// Recolor exactly two: `previous` to the others color, then
        /// `current` to the current color — in that order, so when the two
        /// coincide the current color wins.
        case pair(previous: Int, current: Int)
    }

    /// Decides the minimal recolor for marking `currentIndex` current, and
    /// the state the caller stores after applying it. The
    /// `lastColoredIndex < resultCount` check is defensive: a stale index
    /// (result set replaced without the fully-colored reset) degrades to a
    /// full walk, never an out-of-bounds pair.
    static func plan(
        state: State,
        currentIndex: Int,
        resultCount: Int
    ) -> (plan: Plan, next: State) {
        let next = State(fullyColored: true, lastColoredIndex: currentIndex)
        if state.fullyColored, state.lastColoredIndex < resultCount {
            return (.pair(previous: state.lastColoredIndex, current: currentIndex), next)
        }
        return (.all, next)
    }
}
