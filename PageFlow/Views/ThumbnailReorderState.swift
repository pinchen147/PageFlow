//
//  ThumbnailReorderState.swift
//  PageFlow
//
//  Pure visual reorder mapping for thumbnail drag-and-drop.
//

struct ThumbnailReorderState: Equatable {
    var fromIndex: Int?
    var toIndex: Int?

    var isActive: Bool {
        fromIndex != nil
    }

    var pendingMove: (from: Int, to: Int)? {
        guard let fromIndex, let toIndex, fromIndex != toIndex else { return nil }
        return (fromIndex, toIndex)
    }

    mutating func begin(at index: Int) {
        fromIndex = index
        toIndex = index
    }

    mutating func updateTarget(to index: Int) {
        guard isActive, toIndex != index else { return }
        toIndex = index
    }

    mutating func reset() {
        fromIndex = nil
        toIndex = nil
    }

    func isDraggingPlaceholder(at position: Int) -> Bool {
        isActive && position == toIndex
    }

    func visualIndex(for position: Int) -> Int {
        guard let fromIndex, let toIndex, fromIndex != toIndex else {
            return position
        }

        if position == toIndex {
            return fromIndex
        }

        if fromIndex < toIndex {
            if position >= fromIndex && position < toIndex {
                return position + 1
            }
        } else if position > toIndex && position <= fromIndex {
            return position - 1
        }

        return position
    }
}
