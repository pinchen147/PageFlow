import AppKit

/// Rank geometry depends only on document count and available height, never hover or scroll.
nonisolated struct NavigationRailGeometry: Equatable {
    struct Mark: Equatable {
        let ranks: Range<Int>
        let y: CGFloat
        var representative: Int { ranks.lowerBound }
        func isActive(_ visible: Set<Int>) -> Bool { visible.contains { ranks.contains($0) } }
    }
    var marks: [Mark] = []

    init(totalRanks: Int, height: CGFloat, topInset: CGFloat = 0) {
        guard totalRanks > 0, height.isFinite, topInset.isFinite else { return }
        let start = max(0, topInset) + 20
        let available = height - 20 - start
        guard available >= 0 else { return }
        let capacity = min(256, Int(min(available / 4, 255)) + 1)
        let count = min(totalRanks, capacity)
        let pitch = count > 1 ? min(11, available / CGFloat(count - 1)) : 0
        marks = (0..<count).map { index in
            // Integer partitioning covers every rank with deterministic first members.
            let lower = index * (totalRanks / count) + min(index, totalRanks % count)
            let next = index + 1
            let upper = next * (totalRanks / count) + min(next, totalRanks % count)
            return Mark(ranks: lower..<upper, y: start + CGFloat(index) * pitch)
        }
    }

    func representative(at y: CGFloat) -> Int? {
        guard y.isFinite, let first = marks.first, let last = marks.last else { return nil }
        guard marks.count > 1 else { return first.representative }
        let pitch = (last.y - first.y) / CGFloat(marks.count - 1)
        let index = Int(min(CGFloat(marks.count - 1), max(0, ((y - first.y) / pitch).rounded())))
        return marks[index].representative
    }
}
