import Foundation

/// Where a dropped file or a moved block may land (doc 26 §10.3): between
/// top-level blocks, never inside one and never inside a line of text.
///
/// A slot is a character offset: the start of every top-level block, the end
/// of the note, and the start and end of every image line, even one inside a
/// paragraph block (a pasted image can sit right under a paragraph with a
/// single newline). Fenced code, `$$` math, tables, lists and blockquotes are
/// one block each, so a blank line inside them is never a slot.
///
/// A long note is never parsed whole for this: `blocks(around:)` parses the
/// few blocks around the viewport from a point where the block structure
/// starts fresh, so the cost follows the viewport, not the note.
enum BlockDropSlots {
    /// The slots among `blocks` (`BlockParser`'s tiling of `text`, or of a
    /// stretch of it from `blocks(around:)`), ascending. With `window`, only
    /// the slots in it plus the nearest slot on either side are returned.
    static func slots(in text: NSString, blocks: [Block], window: NSRange? = nil) -> [Int] {
        let length = text.length
        guard length > 0 else { return [0] }
        guard let lastBlock = blocks.last else { return [] }
        var first = 0
        var last = blocks.count - 1
        if let window {
            first = max(0, blockIndex(containing: window.location, in: blocks) - 1)
            last = min(blocks.count - 1, blockIndex(containing: NSMaxRange(window), in: blocks) + 1)
            // Reach one block further on each side past blank separators.
            while first > 0, blocks[first].kind == .blank { first -= 1 }
            while last < blocks.count - 1, blocks[last].kind == .blank { last += 1 }
        }
        var slots: [Int] = []
        for block in blocks[first...last] where block.kind != .blank {
            slots.append(block.range.location)
            guard block.kind == .paragraph else { continue }
            var cursor = block.range.location
            while cursor < NSMaxRange(block.range) {
                let line = text.lineRange(for: NSRange(location: cursor, length: 0))
                if isImageLine(line, in: text) {
                    slots.append(line.location)
                    slots.append(NSMaxRange(line))
                }
                cursor = NSMaxRange(line)
            }
        }
        if last == blocks.count - 1, NSMaxRange(lastBlock.range) == length { slots.append(length) }
        // Two slots with only blank lines between them are one place: the end
        // of an image line and the next block's start. Keep the later one.
        var distinct: [Int] = []
        for slot in Array(Set(slots)).sorted() {
            if let previous = distinct.last, isBlank(text, from: previous, to: slot) {
                distinct[distinct.count - 1] = slot
            } else {
                distinct.append(slot)
            }
        }
        slots = distinct
        guard let window, !slots.isEmpty else { return slots }
        let lower = slots.lastIndex { $0 <= window.location } ?? 0
        let upper = slots.firstIndex { $0 >= NSMaxRange(window) } ?? slots.count - 1
        return Array(slots[lower...max(lower, upper)])
    }

    /// The blocks of the stretch of `text` around `window`: from a point
    /// before it where parsing starts fresh (the note's start, or a line
    /// after a blank line, outside fenced code and `$$` math) to the first
    /// line of the next block after it. `opaqueRanges` are the note's fenced
    /// code and `$$` math blocks, sorted by location: the only blocks a blank
    /// line can sit inside. A run of more than `maxLines` lines without a
    /// blank line is refused rather than inventing a block boundary at the cap.
    static func blocks(around window: NSRange, in text: NSString, opaqueRanges opaque: [NSRange], maxLines: Int = 4_000) -> [Block] {
        let length = text.length
        guard length > 0 else { return [] }
        /// The opaque block `location` sits strictly inside, past its first character.
        func enclosing(_ location: Int) -> NSRange? {
            var low = 0
            var high = opaque.count
            while low < high {
                let mid = (low + high) / 2
                if opaque[mid].location < location { low = mid + 1 } else { high = mid }
            }
            guard low > 0, location < NSMaxRange(opaque[low - 1]) else { return nil }
            return opaque[low - 1]
        }
        func isBlankLine(_ line: NSRange) -> Bool { isBlank(text, from: line.location, to: NSMaxRange(line)) }

        var start = text.lineRange(for: NSRange(location: min(max(0, window.location), length - 1), length: 0)).location
        var steps = 0
        while start > 0, steps < maxLines {
            if let block = enclosing(start) {
                start = block.location
                continue
            }
            let previous = text.lineRange(for: NSRange(location: start - 1, length: 0))
            if isBlankLine(previous), enclosing(previous.location) == nil { break }
            start = previous.location
            steps += 1
        }
        // A capped scan can stop inside a list, table or paragraph. Parsing
        // that suffix as a new document would advertise a false drop slot.
        if start > 0 {
            let previous = text.lineRange(for: NSRange(location: start - 1, length: 0))
            guard isBlankLine(previous), enclosing(previous.location) == nil else { return [] }
        }

        var end = min(length, max(start, NSMaxRange(window)))
        if end < length { end = text.lineRange(for: NSRange(location: end, length: 0)).location }
        var reachedBlank = false
        steps = 0
        while end < length, steps < maxLines {
            if let block = enclosing(end) {
                end = NSMaxRange(block)
                continue
            }
            let line = text.lineRange(for: NSRange(location: end, length: 0))
            if isBlankLine(line) {
                reachedBlank = true
            } else if reachedBlank {
                // The next block's first line: its start is the slot after.
                end = NSMaxRange(line)
                break
            }
            end = NSMaxRange(line)
            steps += 1
        }

        let stretch = NSRange(location: start, length: end - start)
        return BlockParser.parse(text.substring(with: stretch), memoizing: false).map {
            Block(kind: $0.kind, range: NSRange(location: $0.range.location + start, length: $0.range.length))
        }
    }

    /// The slot nearest `offset` in text order: the first slot at or after it,
    /// else the last one. Used to re-seat a slot after the text changed.
    static func slot(atOrAfter offset: Int, in slots: [Int]) -> Int? {
        slots.first { $0 >= offset } ?? slots.last
    }

    /// The text to insert at `slot` so `markdown` stands as its own block:
    /// exactly one blank line before it (unless at the start of the note) and
    /// after it (unless at the end, where one newline ends it). `caret` is the
    /// offset, from `slot`, of the line after `markdown`.
    static func insertion(of markdown: String, at slot: Int, in text: NSString) -> (text: String, caret: Int) {
        func newlines(from start: Int, step: Int) -> Int {
            var count = 0
            var index = start
            while index >= 0, index < text.length, count < 2, text.character(at: index) == 0x0A {
                count += 1
                index += step
            }
            return count
        }
        let prefix = slot == 0 ? "" : String(repeating: "\n", count: 2 - newlines(from: slot - 1, step: -1))
        let suffix = slot >= text.length ? "\n" : String(repeating: "\n", count: 2 - newlines(from: slot, step: 1))
        let body = prefix + markdown
        // A newline always follows the body: the suffix's, or the text's own.
        return (body + suffix, (body as NSString).length + 1)
    }

    /// Whether `line`'s whole content, spaces aside, is one image:
    /// `![alt](destination)` or `![[name]]`.
    static func isImageLine(_ line: NSRange, in text: NSString) -> Bool {
        var start = line.location
        var end = NSMaxRange(line)
        while start < end, isSpace(text.character(at: start)) { start += 1 }
        while end > start, isSpace(text.character(at: end - 1)) { end -= 1 }
        guard end - start >= 5, text.character(at: start) == 0x21, text.character(at: start + 1) == 0x5B else { return false }
        let source = text.substring(with: NSRange(location: start, length: end - start))
        return MarkdownTokenizer.parseTokensViaAST(in: source, memoizing: false).contains {
            ($0.kind == .imageLink || $0.kind == .imageEmbed)
                && $0.range == NSRange(location: 0, length: end - start)
        }
    }

    private static func isSpace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09 || character == 0x0A || character == 0x0D
    }

    private static func isBlank(_ text: NSString, from start: Int, to end: Int) -> Bool {
        var index = start
        while index < end {
            guard isSpace(text.character(at: index)) else { return false }
            index += 1
        }
        return true
    }

    /// The index of the block holding `location` (the last block for the end).
    private static func blockIndex(containing location: Int, in blocks: [Block]) -> Int {
        var low = 0
        var high = blocks.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if blocks[mid].range.location <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
