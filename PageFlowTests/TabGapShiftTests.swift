//
//  TabGapShiftTests.swift
//  PageFlowTests
//
//  The Gap shift decision: which tabs slide aside during a drag, by how
//  much, and in which direction.
//

import Foundation
import Testing
@testable import PageFlow

struct TabGapShiftTests {
    /// draggedWidth 100 + spacing 2.
    private func offset(_ index: Int, source: Int?, insertion: Int) -> CGFloat {
        TabGapShift.offset(
            index: index,
            sourceIndex: source,
            insertionIndex: insertion,
            draggedWidth: 100,
            tabSpacing: 2
        )
    }

    @Test
    func localForwardDragShiftsTheInBetweenTabsLeft() {
        // Dragging tab 0 toward slot 3: tabs 1 and 2 close the vacated slot.
        #expect(offset(0, source: 0, insertion: 3) == 0)     // the source slot itself
        #expect(offset(1, source: 0, insertion: 3) == -102)
        #expect(offset(2, source: 0, insertion: 3) == -102)
        #expect(offset(3, source: 0, insertion: 3) == 0)     // at the gap, stays put
    }

    @Test
    func localBackwardDragShiftsTheInBetweenTabsRight() {
        // Dragging tab 3 toward slot 1: tabs 1 and 2 make room.
        #expect(offset(0, source: 3, insertion: 1) == 0)
        #expect(offset(1, source: 3, insertion: 1) == 102)
        #expect(offset(2, source: 3, insertion: 1) == 102)
        #expect(offset(3, source: 3, insertion: 1) == 0)     // the source slot itself
    }

    @Test
    func adjacentInsertionShiftsNothing() {
        // Dropping right back beside the source: both shift ranges are empty.
        for index in 0..<4 {
            #expect(offset(index, source: 1, insertion: 2) == 0)
            #expect(offset(index, source: 1, insertion: 1) == 0)
        }
    }

    @Test
    func crossWindowDropShiftsTheTailRight() {
        // Incoming tab targets slot 1 of a 4-tab strip: 1, 2, 3 slide right.
        #expect(offset(0, source: nil, insertion: 1) == 0)
        #expect(offset(1, source: nil, insertion: 1) == 102)
        #expect(offset(2, source: nil, insertion: 1) == 102)
        #expect(offset(3, source: nil, insertion: 1) == 102)
    }

    @Test
    func crossWindowDropAtTheEndShiftsNothing() {
        // Appending after the last tab: no existing tab needs to move.
        for index in 0..<4 {
            #expect(offset(index, source: nil, insertion: 4) == 0)
        }
    }
}
