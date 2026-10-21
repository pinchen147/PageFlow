import Foundation

/// Source intervals derived from the canonical block snapshot, never from a second parser.
struct MarkdownFoldRegion: Equatable {
    let heading: NSRange
    let body: NSRange
    let level: Int
    let hiddenBlockCount: Int
}

struct MarkdownFoldIndex {
    let regions: [MarkdownFoldRegion]

    init(regions: [MarkdownFoldRegion]) {
        self.regions = regions
    }

    init(source: NSString, blocks: [Block]) {
        var counts = [0]
        counts.reserveCapacity(blocks.count + 1)
        for block in blocks {
            counts.append(counts.last! + (block.kind == .blank ? 0 : 1))
        }
        struct OpenHeading {
            let blockIndex: Int
            let level: Int
        }
        var stack: [OpenHeading] = []
        var completed = [MarkdownFoldRegion?](repeating: nil, count: blocks.count)
        func close(_ open: OpenHeading, at end: Int, blockEnd: Int) {
            let heading = blocks[open.blockIndex].range
            let start = NSMaxRange(heading)
            let count = counts[blockEnd] - counts[open.blockIndex + 1]
            guard end > start, count > 0 else { return }
            completed[open.blockIndex] = MarkdownFoldRegion(
                heading: heading, body: NSRange(location: start, length: end - start),
                level: open.level, hiddenBlockCount: count)
        }
        for (i, block) in blocks.enumerated() where block.kind == .heading {
            // Classification already established the grammar. Only measure the rank.
            var cursor = block.range.location
            while cursor < NSMaxRange(block.range),
                  CharacterSet.whitespaces.contains(UnicodeScalar(source.character(at: cursor))!) {
                cursor += 1
            }
            var level = 0
            while cursor < NSMaxRange(block.range), source.character(at: cursor) == 0x23 {
                level += 1
                cursor += 1
            }
            guard (1...6).contains(level) else { continue }
            while let previous = stack.last, previous.level >= level {
                close(stack.removeLast(), at: block.range.location, blockEnd: i)
            }
            stack.append(OpenHeading(blockIndex: i, level: level))
        }
        while let previous = stack.popLast() {
            close(previous, at: source.length, blockEnd: blocks.count)
        }
        regions = completed.compactMap { $0 }
    }
}
