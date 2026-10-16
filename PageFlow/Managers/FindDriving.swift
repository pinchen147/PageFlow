//
//  FindDriving.swift
//  PageFlow
//
//  The content-agnostic Find backend the shared Find bar drives (S7a). PDF and
//  Markdown find share one ⌘F surface and one `SearchBar`; the bar holds a
//  `FindDriving` — the active tab's backend — instead of a concrete manager, so
//  the bar's UI is identical for both content types and a future content type
//  is one more conformance, never another bar.
//
//  `PDFFindDriver` (a value adapter over the PDF `SearchManager`, so the PDF search
//  path is byte-identical) and `MarkdownSearchManager` conform. The protocol is the
//  NAVIGATION + QUERY surface only — each conformer keeps its own content-specific
//  search execution and highlight delivery behind `runSearch()` / `next()` /
//  `previous()`. Not `AnyObject`-constrained, so a lightweight value type conforms.
//

import Foundation

/// The narrow surface the shared Find bar reads and drives. 1-based `currentMatch`
/// matches the "N of M" the bar shows; `resultCount` is M. Stepping (`next`/
/// `previous`) and `runSearch` are content-self-contained so the bar never
/// branches on content type.
@MainActor
protocol FindDriving {
    /// The live query text (read). The bar binds its text field to this. Written
    /// via `setQuery(_:)` — a get-only property plus a write method (rather than
    /// `{ get set }`) so a value-type conformer forwarding to its observable manager
    /// can be driven through `any FindDriving` without a mutable existential.
    /// Writing does NOT itself run a search (the bar calls `runSearch()` on change),
    /// so an empty query can route to `clear()` instead.
    var query: String { get }

    /// Set the live query text. Nonmutating for value-type conformers (it forwards
    /// to the backing manager); does not run a search.
    func setQuery(_ query: String)

    /// Total number of matches for the current query (M in "N of M").
    var resultCount: Int { get }

    /// The focused match, 1-based (N in "N of M"); 0 when there are no results.
    var currentMatch: Int { get }

    /// Whether there is at least one match — the bar's nav-button enable gate.
    var hasResults: Bool { get }

    /// Run a search for the current `query` and focus the first match. Each
    /// conformer captures whatever it needs (the PDF document, the markdown text)
    /// at construction, so the bar never supplies content.
    func runSearch()

    /// Advance to the next match (wrapping), revealing/highlighting it.
    func next()

    /// Advance to the previous match (wrapping), revealing/highlighting it.
    func previous()

    /// Reset the backend: clear the query, results, and any highlights.
    func clear()
}

extension FindDriving {
    var hasResults: Bool { resultCount > 0 }
}

/// Optional source-editing capability. Read-only Find backends do not conform.
@MainActor
protocol FindReplacing: FindDriving {
    var replacementText: String { get }
    var showsReplacement: Bool { get }
    func setReplacement(_ replacement: String)
    func setShowingReplacement(_ showing: Bool)
    @discardableResult func replaceCurrent() -> Bool
    @discardableResult func replaceAll() -> Int
}
