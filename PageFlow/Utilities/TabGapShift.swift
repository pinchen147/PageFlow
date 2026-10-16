//
//  TabGapShift.swift
//  PageFlow
//
//  The pure decision of how far each tab pill slides to open the insertion
//  gap during a drag.
//

import Foundation

/// The Gap shift decision: given resolved indices and the gap's width inputs,
/// how far does the tab at `index` slide while a drag targets
/// `insertionIndex`? The view resolves tab ids to indices and applies the
/// returned offset — this module never reads live drag state.
enum TabGapShift {
    /// - Parameters:
    ///   - index: The tab being laid out.
    ///   - sourceIndex: The dragged tab's slot in THIS strip, or nil for a
    ///     cross-window drag (the dragged tab isn't in this strip). Callers
    ///     must not pass nil for a local drag whose source row vanished —
    ///     that case shifts nothing and is theirs to guard.
    ///   - insertionIndex: Where the drop would land.
    ///   - draggedWidth: The dragged pill's width; with `tabSpacing` it forms
    ///     the gap width.
    static func offset(
        index: Int,
        sourceIndex: Int?,
        insertionIndex: Int,
        draggedWidth: CGFloat,
        tabSpacing: CGFloat
    ) -> CGFloat {
        let shiftWidth = draggedWidth + tabSpacing

        guard let sourceIndex else {
            // Cross-window drop: tabs at and after the insertion index shift
            // right to make room for the incoming tab.
            return index >= insertionIndex ? shiftWidth : 0
        }

        // Local drag: tabs between the source slot and the insertion gap
        // shift toward the source slot to open the gap. Both ranges exclude
        // the source itself, so the dragged tab's own slot never shifts.
        if sourceIndex < insertionIndex,
           (sourceIndex + 1..<insertionIndex).contains(index) {
            return -shiftWidth
        }
        if insertionIndex < sourceIndex,
           (insertionIndex..<sourceIndex).contains(index) {
            return shiftWidth
        }
        return 0
    }
}
