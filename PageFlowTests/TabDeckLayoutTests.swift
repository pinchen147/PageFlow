//
//  TabDeckLayoutTests.swift
//  PageFlowTests
//
//  The Deck decision: where each card of the compact tab strip sits, which
//  part of it shows, which card is on top, and how a drag previews its slot.
//

import Foundation
import Testing
@testable import PageFlow

@MainActor
struct TabDeckLayoutTests {
    /// Cards 100 wide, slivers 10 wide.
    private func deck(_ count: Int, focused: Int, expanded: Int? = nil, gap: TabDeckLayout.Gap? = nil) -> TabDeckLayout {
        TabDeckLayout(count: count, focusedIndex: focused, expandedIndex: expanded, gap: gap, cardWidth: 100, sliverWidth: 10)
    }

    private func visible(_ layout: TabDeckLayout) -> [ClosedRange<CGFloat>] {
        layout.cards.map { $0.visibleMinX...$0.visibleMaxX }
    }

    @Test
    func focusedCardShowsWholeBetweenSlivers() {
        let layout = deck(5, focused: 2)
        #expect(visible(layout) == [0...10, 10...20, 20...120, 120...130, 130...140])
        #expect(layout.cards.map(\.side) == [.leading, .leading, .focused, .trailing, .trailing])
        #expect(layout.width == 140)
    }

    @Test
    func leadingCardsHangRightAndTrailingCardsHangLeft() {
        let layout = deck(5, focused: 2)
        // Leading cards start at their sliver; trailing cards end at theirs.
        #expect(layout.cards[0].minX == 0)
        #expect(layout.cards[1].minX == 10)
        #expect(layout.cards[2].minX == 20)
        #expect(layout.cards[3].minX + 100 == 130)
        #expect(layout.cards[4].minX + 100 == 140)
    }

    @Test
    func focusedCardIsOnTopAndNeighboursOutrankFartherCards() {
        let z = deck(5, focused: 2).cards.map(\.zIndex)
        #expect(z[2] > z.enumerated().filter { $0.offset != 2 }.map(\.element).max()!)
        #expect(z[1] > z[0])
        #expect(z[3] > z[4])
    }

    @Test
    func noCardCoversAnotherCardsShownPart() {
        for focused in 0..<5 {
            for expanded in [nil] + Array(0..<5) {
                let layout = deck(5, focused: focused, expanded: expanded)
                for (index, card) in layout.cards.enumerated() {
                    for (otherIndex, other) in layout.cards.enumerated() where other.zIndex > card.zIndex {
                        let covered = max(card.visibleMinX, other.minX) < min(card.visibleMaxX, other.minX + 100)
                        #expect(!covered, "card \(otherIndex) covers card \(index) (focused \(focused), expanded \(String(describing: expanded)))")
                    }
                }
            }
        }
    }

    @Test
    func hoveredSliverSlidesOutWithoutMovingItsShownEdge() {
        let rest = deck(5, focused: 2)
        let leading = deck(5, focused: 2, expanded: 1)
        #expect(leading.cards[1].visibleMinX == rest.cards[1].visibleMinX)
        #expect(leading.cards[1].visibleMaxX - leading.cards[1].visibleMinX == 100)
        #expect(leading.width == rest.width + 90)

        let trailing = deck(5, focused: 2, expanded: 3)
        #expect(trailing.cards[3].visibleMinX == rest.cards[3].visibleMinX)
        // The slid-out trailing card shows whole: it now ends where it shows.
        #expect(trailing.cards[3].minX == trailing.cards[3].visibleMinX)
    }

    @Test
    func expandingTheFocusedCardChangesNothing() {
        #expect(deck(4, focused: 1, expanded: 1) == deck(4, focused: 1))
    }

    @Test
    func singleTabIsJustTheFocusedCard() {
        let layout = deck(1, focused: 0)
        #expect(visible(layout) == [0...100])
        #expect(layout.cards[0].side == .focused)
    }

    @Test
    func outOfRangeFocusIsClamped() {
        #expect(deck(3, focused: 7) == deck(3, focused: 2))
        #expect(deck(0, focused: 0).cards.isEmpty)
    }

    @Test
    func gapOpensAnEmptySlotForAnIncomingTab() {
        let layout = deck(3, focused: 0, gap: .init(index: 1, width: 50))
        #expect(visible(layout) == [0...100, 150...160, 160...170])
        #expect(deck(2, focused: 0, gap: .init(index: 2, width: 50)).width == 160)
    }

    @Test
    func previewOrderMatchesTheReorderCommit() {
        let ids = ["a", "b", "c", "d"]
        // Insertion index counts slots in the current order, like commitTabReorder.
        #expect(TabDeckLayout.previewOrder(ids, moving: "a", toInsertionIndex: 3) == ["b", "c", "a", "d"])
        #expect(TabDeckLayout.previewOrder(ids, moving: "d", toInsertionIndex: 1) == ["a", "d", "b", "c"])
        #expect(TabDeckLayout.previewOrder(ids, moving: "b", toInsertionIndex: 2) == ids)
        #expect(TabDeckLayout.previewOrder(ids, moving: "b", toInsertionIndex: 99) == ["a", "c", "d", "b"])
        #expect(TabDeckLayout.previewOrder(ids, moving: "z", toInsertionIndex: 0) == ids)
    }
}
