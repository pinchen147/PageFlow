//
//  RailFollow.swift
//  PageFlow
//
//  Pure "keep the current page visible" decision for the Thumbnails rail.
//

import SwiftUI

/// The pure decision behind **Rail Follow (keep-visible)**: given the page the
/// rail moved from, the page it moved to, and which page indices are currently
/// visible in the rail, decide whether to reposition the rail and where to land
/// the page.
///
/// Mirrors Apple Preview's model — the rail sits still while the current page is
/// comfortably in view and only repositions once that page reaches the visible
/// edge, bringing it back with headroom in the direction of travel so it then
/// stays put for many pages. It holds no SwiftUI state and reads no live view,
/// so the rule (and the rejected "continuous scroll mirroring" alternative it
/// replaced) is unit-testable in isolation. The caller performs the actual,
/// instant `scrollTo`.
///
/// Indices are in the caller's scroll-id space: the Thumbnails grid uses the
/// page index, which equals the cell position outside an in-progress reorder.
enum RailFollow {
    /// A request to scroll the rail so `pageIndex` lands at `anchor`.
    struct Move: Equatable {
        let pageIndex: Int
        let anchor: UnitPoint
    }

    /// The rail move for a current-page change, or `nil` to leave the rail still.
    ///
    /// - Repositions when visibility hasn't been measured yet (`visiblePages`
    ///   empty) or when the destination is at/past the visible edge.
    /// - No-ops only when the destination is strictly inside the visible band
    ///   (a cell of margin at each edge), so the rail stays put between moves.
    static func move(from oldIndex: Int, to newIndex: Int, visiblePages: Set<Int>) -> Move? {
        // Land the page near the leading edge of travel, leaving room ahead.
        let anchor = UnitPoint(x: 0.5, y: newIndex >= oldIndex ? 0.2 : 0.8)

        guard let firstVisible = visiblePages.min(), let lastVisible = visiblePages.max() else {
            return Move(pageIndex: newIndex, anchor: anchor)  // visibility not measured yet
        }

        // Comfortable = strictly inside the visible band; leave the rail still.
        if newIndex > firstVisible && newIndex < lastVisible {
            return nil
        }
        return Move(pageIndex: newIndex, anchor: anchor)
    }
}
