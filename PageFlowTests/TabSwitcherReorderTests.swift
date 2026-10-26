//
//  TabSwitcherReorderTests.swift
//  PageFlowTests
//
//  The pure drop-target geometry behind Tab Switcher drag-reorder: resolve a
//  cursor point (in list space) to a (window group, insertion index) target,
//  within a group and across groups.
//

import CoreGraphics
import Foundation
import Testing
@testable import PageFlow

struct TabSwitcherReorderTests {

    // Distinct ObjectIdentifiers for synthetic groups.
    private final class GroupToken {}
    private let gA = GroupToken()
    private let gB = GroupToken()

    /// Three stacked rows (height 50, spacing 2) in one group `gid`, starting at `startY`.
    private func rows(_ gid: ObjectIdentifier, startY: CGFloat, count: Int) -> [TabRowFrame] {
        (0..<count).map { i in
            TabRowFrame(groupID: gid, tabID: UUID(), index: i,
                        frame: CGRect(x: 0, y: startY + CGFloat(i) * 52, width: 300, height: 50))
        }
    }

    @Test("within one group, insertion index follows the row midpoints")
    func singleGroupIndex() {
        let id = ObjectIdentifier(gA)
        let frames = rows(id, startY: 0, count: 3)  // midpoints 25, 77, 129

        #expect(TabSwitcherReorderGeometry.dropTarget(at: CGPoint(x: 10, y: 10), frames: frames)
            == TabDropTarget(groupID: id, index: 0))
        #expect(TabSwitcherReorderGeometry.dropTarget(at: CGPoint(x: 10, y: 40), frames: frames)
            == TabDropTarget(groupID: id, index: 1))
        #expect(TabSwitcherReorderGeometry.dropTarget(at: CGPoint(x: 10, y: 90), frames: frames)
            == TabDropTarget(groupID: id, index: 2))
        // Below the last row → append (index == count).
        #expect(TabSwitcherReorderGeometry.dropTarget(at: CGPoint(x: 10, y: 300), frames: frames)
            == TabDropTarget(groupID: id, index: 3))
    }

    @Test("cursor over a second group targets that group (cross-window)")
    func crossGroupTargeting() {
        let idA = ObjectIdentifier(gA), idB = ObjectIdentifier(gB)
        let frames = rows(idA, startY: 0, count: 2) + rows(idB, startY: 120, count: 2)
        // Band A: 0…102, Band B: 120…222.
        #expect(TabSwitcherReorderGeometry.dropTarget(at: CGPoint(x: 10, y: 60), frames: frames)?.groupID == idA)
        let inB = TabSwitcherReorderGeometry.dropTarget(at: CGPoint(x: 10, y: 150), frames: frames)
        #expect(inB == TabDropTarget(groupID: idB, index: 1))
    }

    @Test("a cursor in the gap between groups snaps to the nearest band")
    func gapSnapsToNearest() {
        let idA = ObjectIdentifier(gA), idB = ObjectIdentifier(gB)
        let frames = rows(idA, startY: 0, count: 2) + rows(idB, startY: 120, count: 2)
        // y=110 is 8pt below A (maxY 102) and 10pt above B (minY 120) → nearest A, appended.
        #expect(TabSwitcherReorderGeometry.dropTarget(at: CGPoint(x: 10, y: 110), frames: frames)
            == TabDropTarget(groupID: idA, index: 2))
    }

    @Test("empty frames yield no target")
    func emptyIsNil() {
        #expect(TabSwitcherReorderGeometry.dropTarget(at: CGPoint(x: 0, y: 0), frames: []) == nil)
    }
}
