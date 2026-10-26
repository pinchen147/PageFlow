import Foundation

/// the reference editor's card stacking in the comment rail (doc 25 §4.3, its `EG`):
/// each card wants the top of its anchor; cards keep 8 apart; the pivot (the
/// draft, else the open card) stays on its anchor, cards above it move up
/// and cards below move down; the stack is pulled up to end above the
/// document's bottom, never more than 400 above a card's own anchor, and
/// what still hangs over grows the document's bottom padding.
enum CommentRailLayout {
    static let gap: CGFloat = 8
    /// A card not measured yet.
    static let estimatedHeight: CGFloat = 56
    /// How far a card may float above its anchor.
    static let maximumFloat: CGFloat = 400

    struct Slot: Equatable {
        var id: String
        /// The anchor's top.
        var y: CGFloat
        var height: CGFloat
        var created: Date
    }

    struct Result: Equatable {
        var tops: [String: CGFloat]
        /// How far the last card hangs below the document's bottom.
        var overhang: CGFloat
    }

    static func solve(_ unsorted: [Slot], pivot: String?, bottom: CGFloat) -> Result {
        let slots = unsorted.sorted { $0.y != $1.y ? $0.y < $1.y : $0.created < $1.created }
        guard !slots.isEmpty else { return Result(tops: [:], overhang: 0) }
        var tops = slots.map(\.y)
        let pivotIndex = pivot.flatMap { id in slots.firstIndex { $0.id == id } }
        let first = pivotIndex ?? 0
        // Down from the pivot (or the first card): never above the card before.
        for index in (first + 1)..<max(first + 1, slots.count) {
            tops[index] = max(tops[index - 1] + slots[index - 1].height + gap, slots[index].y)
        }
        // Up from the pivot: a card that would reach the one below moves up.
        if let pivotIndex, pivotIndex > 0 {
            for index in stride(from: pivotIndex - 1, through: 0, by: -1) {
                tops[index] = min(slots[index].y, tops[index + 1] - gap - slots[index].height)
            }
        }
        // Pull the stack up to end above the bottom, at most 400 above each anchor.
        var limit = bottom
        for index in stride(from: slots.count - 1, through: 0, by: -1) {
            let end = tops[index] + slots[index].height
            if end > limit {
                tops[index] = min(tops[index], max(limit - slots[index].height, slots[index].y - maximumFloat))
            }
            limit = tops[index] - gap
        }
        let last = slots.count - 1
        let overhang = max(0, tops[last] + slots[last].height - bottom)
        var result: [String: CGFloat] = [:]
        for (index, slot) in slots.enumerated() { result[slot.id] = tops[index] }
        return Result(tops: result, overhang: overhang)
    }
}
