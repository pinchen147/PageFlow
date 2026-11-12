import Foundation

struct SourceUTF16Offset: Equatable, Sendable {
    let rawValue: Int
}

struct VisibleUTF16Offset: Equatable, Sendable {
    let rawValue: Int
}

/// Immutable provenance for one imported revision, never an editable source buffer.
struct SemanticSourceMap {
    enum Affinity { case leading, trailing }
    enum Kind: Equatable { case literal, delimiter, escape, entity, object, lineEnding }

    struct Segment: Equatable {
        let source: NSRange
        let visible: NSRange
        let kind: Kind

        func shifted(sourceBy sourceOffset: Int, visibleBy visibleOffset: Int) -> Self {
            Self(source: NSRange(location: source.location + sourceOffset, length: source.length),
                 visible: NSRange(location: visible.location + visibleOffset, length: visible.length), kind: kind)
        }
    }

    /// Prefix maximum ends admit overlapping intervals without scanning earlier segments.
    private struct Index {
        let order: [Int]
        let maximumEnds: [Int]

        init(_ segments: [Segment], forward: Bool) {
            let order = segments.indices.sorted {
                let a = forward ? segments[$0].source : segments[$0].visible
                let b = forward ? segments[$1].source : segments[$1].visible
                return a.location == b.location ? a.length < b.length : a.location < b.location
            }
            self.order = order
            var maximum = 0
            maximumEnds = order.map { index in
                maximum = max(maximum, NSMaxRange(forward ? segments[index].source : segments[index].visible))
                return maximum
            }
        }
    }

    let segments: [Segment]
    let sourceUTF16Count: Int
    let visibleUTF16Count: Int
    private let sourceText: String?
    private let visibleText: String?
    private let sourceIndex: Index
    private let visibleIndex: Index

    init(segments: [Segment], sourceUTF16Count: Int, visibleUTF16Count: Int,
         sourceText: String? = nil, visibleText: String? = nil) {
        func valid(_ range: NSRange, count: Int) -> Bool {
            range.location >= 0 && range.length >= 0 && range.location <= count
                && range.length <= count - range.location
        }
        precondition(sourceUTF16Count >= 0 && visibleUTF16Count >= 0)
        precondition(segments.allSatisfy {
            valid($0.source, count: sourceUTF16Count) && valid($0.visible, count: visibleUTF16Count)
        })
        precondition(sourceText == nil || sourceText?.utf16.count == sourceUTF16Count)
        precondition(visibleText == nil || visibleText?.utf16.count == visibleUTF16Count)
        self.segments = segments
        self.sourceUTF16Count = sourceUTF16Count
        self.visibleUTF16Count = visibleUTF16Count
        self.sourceText = sourceText
        self.visibleText = visibleText
        sourceIndex = Index(segments, forward: true)
        visibleIndex = Index(segments, forward: false)
    }

    func visibleOffset(for offset: SourceUTF16Offset, affinity: Affinity) -> VisibleUTF16Offset? {
        guard offset.rawValue >= 0, offset.rawValue <= sourceUTF16Count else { return nil }
        let snapped = Self.snap(offset.rawValue, text: sourceText, affinity: affinity)
        guard let result = mapped(snapped, affinity: affinity, forward: true) else { return nil }
        return VisibleUTF16Offset(rawValue: Self.snap(result, text: visibleText, affinity: affinity))
    }

    func sourceOffset(for offset: VisibleUTF16Offset, affinity: Affinity) -> SourceUTF16Offset? {
        guard offset.rawValue >= 0, offset.rawValue <= visibleUTF16Count else { return nil }
        let snapped = Self.snap(offset.rawValue, text: visibleText, affinity: affinity)
        guard let result = mapped(snapped, affinity: affinity, forward: false) else { return nil }
        return SourceUTF16Offset(rawValue: Self.snap(result, text: sourceText, affinity: affinity))
    }

    private func mapped(_ offset: Int, affinity: Affinity, forward: Bool) -> Int? {
        if segments.isEmpty { return offset == 0 ? 0 : nil }
        let index = forward ? sourceIndex : visibleIndex
        var low = 0, high = index.order.count
        while low < high {
            let middle = (low + high) / 2
            if index.maximumEnds[middle] < offset { low = middle + 1 } else { high = middle }
        }
        var candidate: Int?
        var position = low
        while position < index.order.count {
            let segment = segments[index.order[position]]
            let from = forward ? segment.source : segment.visible
            if from.location > offset { break }
            position += 1
            guard offset <= NSMaxRange(from) else { continue }
            let to = forward ? segment.visible : segment.source
            let result: Int
            if from.length == 0 {
                result = affinity == .leading ? to.location : NSMaxRange(to)
            } else if offset == from.location {
                result = to.location
            } else if offset == NSMaxRange(from) {
                result = NSMaxRange(to)
            } else if segment.kind == .literal || segment.kind == .lineEnding,
                      from.length == to.length {
                result = to.location + offset - from.location
            } else {
                result = affinity == .leading ? to.location : NSMaxRange(to)
            }
            candidate = candidate.map { affinity == .leading ? min($0, result) : max($0, result) } ?? result
        }
        return candidate
    }

    /// Foundation resolves only the local composed sequence. No per-character index
    /// arrays or unsafe String.Index conversions are needed for an interior offset.
    private static func snap(_ offset: Int, text: String?, affinity: Affinity) -> Int {
        guard let text else { return offset }
        let ns = text as NSString
        guard offset < ns.length else { return offset }
        let range = ns.rangeOfComposedCharacterSequence(at: offset)
        if offset == range.location { return offset }
        return affinity == .leading ? range.location : NSMaxRange(range)
    }
}
