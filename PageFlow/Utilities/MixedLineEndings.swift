import Foundation

/// Physical separators for a file whose lines do not all use its dominant separator.
/// The source is the last successfully written normalized text, including comment metadata.
nonisolated struct MixedLineEndings: Equatable, Sendable {
    let source: String
    let separators: [LineEnding]

    func expanding(_ text: String, default ending: LineEnding, bodySeparators: [LineEnding]? = nil) -> (text: String, layout: MixedLineEndings) {
        let new = text.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [LineEnding]
        if let bodySeparators, bodySeparators.count == new.count - 1 {
            result = bodySeparators
        } else {
            result = matchedSeparators(for: new, default: ending)
            if let bodySeparators {
                let count = min(result.count, bodySeparators.count)
                result.replaceSubrange(0..<count, with: bodySeparators.prefix(count))
            }
        }
        var physical = ""
        physical.reserveCapacity(text.utf8.count)
        for (index, line) in new.enumerated() {
            physical.append(contentsOf: line)
            if index < result.count { physical += result[index].rawValue }
        }
        return (physical, MixedLineEndings(source: text, separators: result))
    }

    private func matchedSeparators(for new: [Substring], default ending: LineEnding) -> [LineEnding] {
        let old = source.split(separator: "\n", omittingEmptySubsequences: false)
        var result = Array(repeating: ending, count: new.count - 1)
        func retain(_ i: Int, at j: Int) {
            if separators.indices.contains(i), result.indices.contains(j) { result[j] = separators[i] }
        }

        var start = 0
        while start < min(old.count, new.count), old[start] == new[start] {
            retain(start, at: start)
            start += 1
        }
        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > start, newEnd > start, old[oldEnd - 1] == new[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
            retain(oldEnd, at: newEnd)
        }

        // Between unchanged lines, split lines keep the original separator at
        // the end of the replacement. Additional line breaks use the default.
        var oldCursor = start
        var newCursor = start
        func retainReplacement(upTo oldLimit: Int, _ newLimit: Int) {
            let count = min(oldLimit - oldCursor, newLimit - newCursor)
            for offset in 0..<count { retain(oldLimit - count + offset, at: newLimit - count + offset) }
        }
        if start < oldEnd, start < newEnd {
            // Reconcile disjoint edits using ordered matches in linear space and
            // time. Consume each candidate once, including repeated blank lines.
            var positions: [Substring: [Int]] = [:]
            for i in (start..<oldEnd).reversed() { positions[old[i], default: []].append(i) }
            for j in start..<newEnd {
                while let i = positions[new[j]]?.popLast() {
                    guard i >= oldCursor else { continue }
                    retainReplacement(upTo: i, j)
                    retain(i, at: j)
                    oldCursor = i + 1
                    newCursor = j + 1
                    break
                }
            }
            retainReplacement(upTo: oldEnd, newEnd)
        }

        return result
    }
}
