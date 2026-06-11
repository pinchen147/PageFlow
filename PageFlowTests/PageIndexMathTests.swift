//
//  PageIndexMathTests.swift
//  PageFlowTests
//

import Testing
@testable import PageFlow

struct PageIndexMathTests {

    // MARK: - afterDeletion

    @Test
    func deletionBeforeCurrentShiftsCurrentDown() {
        #expect(PageIndexMath.afterDeletion(current: 2, deletedIndex: 1, newPageCount: 3) == 1)
    }

    @Test
    func deletionAfterCurrentLeavesCurrentInPlace() {
        #expect(PageIndexMath.afterDeletion(current: 0, deletedIndex: 1, newPageCount: 3) == 0)
    }

    @Test
    func deletingTheCurrentPageKeepsTheIndex() {
        // The page that slid into the slot is now shown at the same index.
        #expect(PageIndexMath.afterDeletion(current: 1, deletedIndex: 1, newPageCount: 3) == 1)
    }

    @Test
    func deletingTheLastPageWhileOnItClampsToNewLast() {
        // 4 pages, on the last (index 3), delete it -> new count 3 -> clamp to 2.
        #expect(PageIndexMath.afterDeletion(current: 3, deletedIndex: 3, newPageCount: 3) == 2)
    }

    // MARK: - afterInsertion

    @Test
    func insertionAtOrBeforeCurrentShiftsCurrentDown() {
        #expect(PageIndexMath.afterInsertion(current: 2, insertedIndex: 2) == 3) // at current
        #expect(PageIndexMath.afterInsertion(current: 3, insertedIndex: 2) == 4) // before current
    }

    @Test
    func insertionAfterCurrentLeavesCurrentInPlace() {
        #expect(PageIndexMath.afterInsertion(current: 1, insertedIndex: 2) == 1)
    }

    // MARK: - afterMove

    @Test
    func movingTheCurrentPageFollowsItToDestination() {
        #expect(PageIndexMath.afterMove(current: 1, from: 1, to: 3) == 3)
    }

    @Test
    func movingFromBeforeToAtOrAfterCurrentShiftsCurrentDown() {
        #expect(PageIndexMath.afterMove(current: 2, from: 0, to: 3) == 1)
    }

    @Test
    func movingFromAfterToAtOrBeforeCurrentShiftsCurrentUp() {
        #expect(PageIndexMath.afterMove(current: 1, from: 3, to: 0) == 2)
    }

    @Test
    func aMoveNotSpanningCurrentLeavesItInPlace() {
        #expect(PageIndexMath.afterMove(current: 1, from: 2, to: 3) == 1)
    }
}
