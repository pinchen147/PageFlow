//
//  TabDeckLayout.swift
//  PageFlow
//
//  The pure decision of where each tab sits in the compact tab strip (the
//  Deck): the focused tab at full width, every other tab tucked under it as a
//  sliver, and one hovered sliver slid out to full width so its title shows.
//

import CoreGraphics

/// The Deck decision: given the tab count, the focused tab and the slid-out
/// tab, where every card sits, which part of it shows, and which is on top.
/// Cards left of the focused tab show their leading edge, cards right of it
/// their trailing edge. The shown parts never overlap and run left to right
/// in tab order, so hit-testing, hover and drop-index code written for
/// side-by-side tabs works unchanged on them.
struct TabDeckLayout: Equatable {
    enum Side: Equatable {
        case leading
        case focused
        case trailing
    }

    struct Card: Equatable {
        let side: Side
        /// The card's leading edge. Cards are `cardWidth` wide and overlap.
        let minX: CGFloat
        /// The part no other card covers.
        let visibleMinX: CGFloat
        let visibleMaxX: CGFloat
        /// Higher draws on top: the focused card, then cards nearer to it.
        let zIndex: Double
        /// The whole card shows (focused or slid out); otherwise a sliver.
        let showsWhole: Bool

        var visibleWidth: CGFloat { visibleMaxX - visibleMinX }
    }

    /// An empty slot opened for a tab dragged in from another window.
    struct Gap: Equatable {
        let index: Int
        let width: CGFloat
    }

    let cards: [Card]
    let width: CGFloat

    init(
        count: Int,
        focusedIndex: Int,
        expandedIndex: Int? = nil,
        gap: Gap? = nil,
        cardWidth: CGFloat = DesignTokens.tabMaxWidth,
        sliverWidth: CGFloat = DesignTokens.tabDeckSliverWidth
    ) {
        let focused = min(max(focusedIndex, 0), max(count - 1, 0))
        var cards: [Card] = []
        cards.reserveCapacity(count)
        var x: CGFloat = 0

        for index in 0..<count {
            if gap?.index == index { x += gap?.width ?? 0 }
            let showsWhole = index == focused || index == expandedIndex
            let shownWidth = showsWhole ? cardWidth : sliverWidth
            let side: Side = index < focused ? .leading : index == focused ? .focused : .trailing
            let zIndex: Double = switch side {
            case .leading: Double(index)
            case .focused: Double(count)
            case .trailing: Double(count - index)
            }
            cards.append(Card(
                side: side,
                // Leading cards hang right, under their neighbour; trailing
                // cards hang left. The focused card shows whole.
                minX: side == .trailing ? x + shownWidth - cardWidth : x,
                visibleMinX: x,
                visibleMaxX: x + shownWidth,
                zIndex: zIndex,
                showsWhole: showsWhole
            ))
            x += shownWidth
        }
        if let gap, gap.index >= count { x += gap.width }

        self.cards = cards
        self.width = x
    }

    /// The order the Deck shows while one of its own tabs is dragged: the tab
    /// moves to its landing slot. `insertionIndex` counts slots in the current
    /// order, the same convention as `TabManager.commitTabReorder`.
    static func previewOrder<ID: Equatable>(
        _ ids: [ID],
        moving id: ID,
        toInsertionIndex insertionIndex: Int
    ) -> [ID] {
        guard let source = ids.firstIndex(of: id) else { return ids }
        let clamped = min(max(insertionIndex, 0), ids.count)
        let target = clamped > source ? clamped - 1 : clamped
        var order = ids
        order.remove(at: source)
        order.insert(id, at: target)
        return order
    }
}
