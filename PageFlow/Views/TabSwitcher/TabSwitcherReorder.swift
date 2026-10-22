//
//  TabSwitcherReorder.swift
//  PageFlow
//
//  Pure, testable geometry + state for press-and-hold drag-reorder in the Tab
//  Switcher's OPEN TABS list. The view records each open row's frame (in the
//  list's coordinate space) and this resolves the cursor into a concrete drop
//  target — a (window group, insertion index) pair — that works both WITHIN a
//  window and ACROSS windows. No AppKit/SwiftUI view logic here.
//

import CoreGraphics
import Foundation

/// One draggable open-tab row's laid-out frame, tagged with the window group it
/// belongs to and its index within that group.
struct TabRowFrame: Equatable {
    let groupID: ObjectIdentifier
    let tabID: UUID
    /// Index of this tab within its group's `tabs`.
    let index: Int
    /// The row's frame in the list's named coordinate space.
    let frame: CGRect
}

/// A resolved drop location: insert before position `index` of the group's tabs
/// (an index in `0...count`).
struct TabDropTarget: Equatable {
    let groupID: ObjectIdentifier
    let index: Int
}

/// Live state for an in-flight press-and-hold reorder drag.
struct TabReorderDrag: Equatable {
    let tabID: UUID
    let sourceGroupID: ObjectIdentifier
    /// Vertical drag translation, for the lifted row's follow-the-cursor offset.
    var translationY: CGFloat = 0
    /// The current resolved drop location (nil until the cursor is over a group).
    var target: TabDropTarget?
}

enum TabSwitcherReorderGeometry {

    /// Resolve the cursor `point` (in the list's coordinate space) to a drop
    /// target. Picks the group whose vertical band contains the cursor (clamped
    /// to the nearest band when between groups), then the insertion index by
    /// comparing the cursor to each row's vertical midpoint.
    ///
    /// `frames` may be in any order; it is grouped and sorted internally.
    static func dropTarget(at point: CGPoint, frames: [TabRowFrame]) -> TabDropTarget? {
        guard !frames.isEmpty else { return nil }

        // Group the rows, preserving each group's row order by index.
        var byGroup: [ObjectIdentifier: [TabRowFrame]] = [:]
        for f in frames { byGroup[f.groupID, default: []].append(f) }
        for key in byGroup.keys { byGroup[key]?.sort { $0.index < $1.index } }

        // Vertical band (minY…maxY) of each group, in list space.
        let bands: [(groupID: ObjectIdentifier, minY: CGFloat, maxY: CGFloat, rows: [TabRowFrame])] =
            byGroup.map { key, rows in
                let minY = rows.map(\.frame.minY).min() ?? 0
                let maxY = rows.map(\.frame.maxY).max() ?? 0
                return (key, minY, maxY, rows)
            }.sorted { $0.minY < $1.minY }

        // Choose the band containing the cursor, else the nearest one (so a drag
        // above the first / below the last group still resolves to an end slot).
        let chosen: (groupID: ObjectIdentifier, minY: CGFloat, maxY: CGFloat, rows: [TabRowFrame])
        if let inside = bands.first(where: { point.y >= $0.minY && point.y <= $0.maxY }) {
            chosen = inside
        } else if let nearest = bands.min(by: { distance(point.y, $0) < distance(point.y, $1) }) {
            chosen = nearest
        } else {
            return nil
        }

        // Insertion index: count rows whose midpoint is above the cursor.
        var index = 0
        for row in chosen.rows {
            if point.y > row.frame.midY { index += 1 } else { break }
        }
        return TabDropTarget(groupID: chosen.groupID, index: index)
    }

    private static func distance(_ y: CGFloat, _ band: (groupID: ObjectIdentifier, minY: CGFloat, maxY: CGFloat, rows: [TabRowFrame])) -> CGFloat {
        if y < band.minY { return band.minY - y }
        if y > band.maxY { return y - band.maxY }
        return 0
    }
}
