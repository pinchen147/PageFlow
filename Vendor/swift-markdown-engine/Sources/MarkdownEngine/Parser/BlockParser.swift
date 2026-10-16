//
//  BlockParser.swift
//  MarkdownEngine
//
//  Phase 1 of the regex→AST refactor: the block-structure pass. Splits the
//  document into a flat, gap-free (tiling) sequence of blocks following the
//  CommonMark two-phase model — block structure first, inline content later.
//  Inline parsing happens per inline-bearing block in a separate step.
//
//  Ranges are absolute UTF-16 NSRanges into the source (the editor is
//  NSTextView / TextKit-2 based, so UTF-16 offsets are the native currency).
//  Storing relative widths (green-tree style, for cheap incremental reparse)
//  is a deliberate Phase 3 concern and intentionally deferred here.
//
//  Line classification mirrors the recognition the current regex tokenizer /
//  styler perform, so block ranges line up with today's tokens:
//    • heading        — headingRegex        `^\s*#{1,6} +…`
//    • thematic break — styler HR pattern   `^\s*(-{3,}|\*{3,}|_{3,})\s*$`
//    • fenced code    — codeBlockRegex       opening/closing ``` line
//    • blockquote     — blockquoteRegex     `^[ \t]{0,3}(>…)`
//

import Foundation

/// The block-level classification of a run of lines.
enum BlockKind: Hashable {
    case paragraph       // inline-bearing
    case heading         // single ATX line (`# …`), inline-bearing content
    case blockquote      // consecutive `>` lines, inline-bearing per line
    case list            // consecutive list-item lines (`-`/`*`/`+` or `1.`/`1)`)
    case fencedCode      // ```…``` — opaque (no inline parsing inside)
    case blockLatex      // $$…$$ — opaque
    case table           // GFM table — opaque (rendered as a unit)
    case thematicBreak   // `---` / `***` / `___` — produces no token today
    case blank           // blank / whitespace-only line(s) — separator
}

/// One block; `range` is the absolute UTF-16 span of its lines, tiling with no gaps.
struct Block: Equatable {
    let kind: BlockKind
    let range: NSRange
}

enum BlockParser {

    private static let cacheLock = NSLock()
    private static var cachedChars: [unichar]?     // UTF-16 buffer of the last parse
    private static var cachedBlocks: [Block]?
    /// The length of the text the memo holds (tests).
    static var memoizedLength: Int? { cacheLock.withLock { cachedChars?.count } }

    /// Splits `text` into gap-free tiling blocks; memoizes the last parse so both per-keystroke callers share one line-scan.
    /// A text that is not the document (a cell, one block) passes `memoizing: false`
    /// so it never replaces the document's memo.
    static func parse(_ text: String) -> [Block] { parse(text, memoizing: true) }

    static func parse(_ text: String, memoizing: Bool) -> [Block] {
        guard memoizing else { return computeBlocks(text) }
        let textNS = text as NSString
        cacheLock.lock()
        let prevChars = cachedChars
        let prevBlocks = cachedBlocks
        cacheLock.unlock()

        let newChars = copiedUTF16(of: textNS)
        let newLen = newChars.count
        if let prevChars, let prevBlocks, prevChars == newChars {
            return prevBlocks
        }

        // Line scans run on a contiguous UTF-16 copy: `character(at:)` on the
        // text storage's own string was several times slower.
        let contiguous = NSString(characters: newChars, length: newLen)

        // Incremental: reparse only the affected block window, else fall back to a full reparse.
        if let prevChars, let prevBlocks,
           let (incr, _) = incrementalParse(oldChars: prevChars, oldBlocks: prevBlocks, newChars: newChars, newNS: contiguous) {
            cacheLock.lock(); cachedChars = newChars; cachedBlocks = incr; cacheLock.unlock()
            return incr
        }

        let blocks = computeBlocks(contiguous as String)
        cacheLock.lock(); cachedChars = newChars; cachedBlocks = blocks; cacheLock.unlock()
        return blocks
    }

    /// Does `[lo, hi)` (± margin for an edit-boundary delimiter) contain a `$$` or ``` that can ripple?
    static func hasBlockDelimiter(_ buf: [unichar], _ lo: Int, _ hi: Int) -> Bool {
        var i = max(0, lo - 3)
        let end = min(buf.count, hi + 3)
        while i < end {
            if buf[i] == 0x24 {                                          // $
                if i + 1 < end, buf[i + 1] == 0x24 { return true }       // $$
            } else if (buf[i] == 0x60 || buf[i] == 0x7E), i + 2 < end,
                      buf[i + 1] == buf[i], buf[i + 2] == buf[i] {
                var start = i
                while start > 0, buf[start - 1] != 0x0A, buf[start - 1] != 0x0D { start -= 1 }
                var lineEnd = i + 3
                while lineEnd < buf.count, buf[lineEnd] != 0x0A, buf[lineEnd] != 0x0D { lineEnd += 1 }
                let line = String(decoding: buf[start..<lineEnd], as: UTF16.self) as NSString
                if FencedCode.opening(in: line, line: NSRange(location: 0, length: line.length)) != nil {
                    return true
                }
            }
            i += 1
        }
        return false
    }

    /// Whether replacing `o[start..<oldEnd]` by `n[start..<newEnd]` leaves every
    /// `$$` / ``` / `~~~` run as it was: the lines the edit touches hold no run,
    /// before or after it. Whether a line opens or closes a block depends on the
    /// whole line (indent, text after a closer), so any edit on a run's line,
    /// or one that breaks or joins lines into one, falls back to a reparse.
    static func editKeepsDelimiters(_ o: [unichar], _ n: [unichar], _ start: Int, _ oldEnd: Int, _ newEnd: Int) -> Bool {
        !linesHoldDelimiter(o, start, oldEnd) && !linesHoldDelimiter(n, start, newEnd)
    }

    /// Whether the whole lines spanning `[lo, hi)` hold a `$$`, ``` or `~~~` run:
    /// any of them could open or close a block once the edit lands.
    static func linesHoldDelimiter(_ buf: [unichar], _ lo: Int, _ hi: Int) -> Bool {
        var start = min(max(0, lo), buf.count)
        while start > 0, buf[start - 1] != 0x0A, buf[start - 1] != 0x0D { start -= 1 }
        var end = min(max(start, hi), buf.count)
        while end < buf.count, buf[end] != 0x0A, buf[end] != 0x0D { end += 1 }
        var i = start
        while i + 1 < end {
            let c = buf[i]
            if c == 0x24, buf[i + 1] == 0x24 { return true }                         // $$
            if (c == 0x60 || c == 0x7E), i + 2 < end, buf[i + 1] == c, buf[i + 2] == c { return true }
            i += 1
        }
        return false
    }

    /// Diff old→new, reparse the affected window, splice between untouched prefix/suffix; nil to fall back to full.
    private static func incrementalParse(oldChars o: [unichar], oldBlocks: [Block], newChars n: [unichar], newNS: NSString) -> (blocks: [Block], window: Int)? {
        guard !oldBlocks.isEmpty else { return nil }
        let oldLen = o.count, newLen = n.count
        guard oldLen > 0, newLen > 0 else { return nil }

        // 1. Common prefix/suffix over the cached UTF-16 buffers (no re-extract).
        var p = 0
        let maxPre = min(oldLen, newLen)
        while p < maxPre, o[p] == n[p] { p += 1 }
        var s = 0
        let maxSuf = maxPre - p
        while s < maxSuf, o[oldLen - 1 - s] == n[newLen - 1 - s] { s += 1 }
        let delta = newLen - oldLen
        let changeStart = p
        let changeEnd = oldLen - s              // [changeStart, changeEnd) in old
        // A change spanning most of the text (a ⌘A format) reparses everything
        // anyway; the window search below would only add to it.
        if (newLen - s - changeStart) * 2 > newLen { return nil }

        // A fence/block-LaTeX delimiter in the edit can pair with a distant partner → full reparse.
        if hasBlockDelimiter(o, changeStart, changeEnd) || hasBlockDelimiter(n, changeStart, newLen - s) {
            return nil
        }

        // 2. Affected old-block window (±1 block margin for merges/splits).
        var firstIdx = 0
        while firstIdx + 1 < oldBlocks.count, oldBlocks[firstIdx + 1].range.location <= changeStart { firstIdx += 1 }
        var lastIdx = oldBlocks.count - 1
        while lastIdx > 0, NSMaxRange(oldBlocks[lastIdx - 1].range) >= changeEnd { lastIdx -= 1 }
        let winFirst = max(0, min(firstIdx, lastIdx) - 1)
        let winLast = min(oldBlocks.count - 1, max(firstIdx, lastIdx) + 1)

        // 3. Inside one fenced-code or block-LaTeX block, an edit that keeps
        //    every delimiter (`editKeepsDelimiters`) cannot change how they
        //    pair: the block only grows or shrinks by the edit and the blocks
        //    after it move. Typing in a code block or a formula stays O(edit)
        //    on a long note (a full reparse is 150 ms at 4.6 MB).
        let containing = oldBlocks[firstIdx]
        if containing.kind == .fencedCode || containing.kind == .blockLatex,
           changeEnd < NSMaxRange(containing.range),
           editKeepsDelimiters(o, n, changeStart, changeEnd, newLen - s) {
            var result = Array(oldBlocks[0..<firstIdx])
            result.append(Block(kind: containing.kind,
                                range: NSRange(location: containing.range.location, length: containing.range.length + delta)))
            result.append(contentsOf: oldBlocks[(firstIdx + 1)...].map { $0.shifted(by: delta) })
            return (result, 1)
        }

        // 4. Otherwise bail on opaque multi-line blocks — fences / block LaTeX can ripple.
        for b in oldBlocks[winFirst...winLast] where b.kind == .fencedCode || b.kind == .blockLatex {
            return nil
        }

        // 5. Window → new-text range (window start is before the edit → unchanged).
        let winStart = oldBlocks[winFirst].range.location
        let winEndNew = NSMaxRange(oldBlocks[winLast].range) + delta
        guard winStart >= 0, winEndNew >= winStart, winEndNew <= newLen else { return nil }

        // 6. Reparse just the window substring, shift to absolute new coords.
        let windowText = newNS.substring(with: NSRange(location: winStart, length: winEndNew - winStart))
        let reparsed = computeBlocks(windowText).map { $0.shifted(by: winStart) }
        // A trailing fence/latex reaching the window end might continue past it.
        if let last = reparsed.last, last.kind == .fencedCode || last.kind == .blockLatex,
           NSMaxRange(last.range) >= winEndNew {
            return nil
        }

        // Tiling alone cannot detect a paragraph/list/quote/table that merges across a cut.
        // Reparse both boundary blocks together before reusing either untouched neighbor.
        if winFirst > 0 {
            guard let first = reparsed.first,
                  seamIsStable(oldBlocks[winFirst - 1], first, in: newNS) else { return nil }
        }
        if winLast + 1 < oldBlocks.count {
            guard let last = reparsed.last,
                  seamIsStable(last, oldBlocks[winLast + 1].shifted(by: delta), in: newNS) else { return nil }
        }

        // 7. Splice: prefix (unchanged) + reparsed window + suffix (shifted).
        var result: [Block] = []
        result.append(contentsOf: oldBlocks[0..<winFirst])
        result.append(contentsOf: reparsed)
        if winLast + 1 < oldBlocks.count {
            result.append(contentsOf: oldBlocks[(winLast + 1)...].map { $0.shifted(by: delta) })
        }

        // 8. Validate gap-free tiling of [0, newLen); else full reparse.
        var cursor = 0
        for b in result {
            if b.range.location != cursor { return nil }
            cursor = NSMaxRange(b.range)
        }
        guard cursor == newLen else { return nil }
        return (result, reparsed.count)
    }

    private static func seamIsStable(_ left: Block, _ right: Block, in source: NSString) -> Bool {
        let joined = NSRange(location: left.range.location, length: NSMaxRange(right.range) - left.range.location)
        guard joined.location >= 0, NSMaxRange(joined) <= source.length else { return false }
        let blocks = computeBlocks(source.substring(with: joined)).map { $0.shifted(by: joined.location) }
        return blocks == [left, right]
    }

    private static func computeBlocks(_ text: String) -> [Block] {
        let nsText = text as NSString
        let length = nsText.length
        guard length > 0 else { return [] }

        // 1. Slice into physical lines (each includes its trailing newline).
        var lines: [NSRange] = []
        var cursor = 0
        while cursor < length {
            let r = nsText.lineRange(for: NSRange(location: cursor, length: 0))
            lines.append(r)
            cursor = NSMaxRange(r)
        }

        func lineText(_ i: Int) -> String { nsText.substring(with: lines[i]) }

        /// Line index of the `$$` closing a block-LaTeX run opened at `start`; nil if none.
        func blockLatexCloseIndex(from start: Int) -> Int? {
            let open = lineText(start).trimmingCharacters(in: .whitespacesAndNewlines)
            if open.dropFirst(2).contains("$$") { return start }
            var j = start + 1
            while j < lines.count { if lineText(j).contains("$$") { return j }; j += 1 }
            return nil
        }

        // 2. Classify + group.
        var blocks: [Block] = []
        var i = 0
        while i < lines.count {
            let line = lineText(i)

            if isBlank(line) {
                var end = i
                while end + 1 < lines.count, isBlank(lineText(end + 1)) { end += 1 }
                blocks.append(Block(kind: .blank, range: union(lines[i...end])))
                i = end + 1

            } else if let opening = FencedCode.opening(in: nsText, line: lines[i]) {
                // Opaque: consume through the closing fence (or to EOF if none).
                var end = lines.count - 1
                var scan = i + 1
                while scan < lines.count {
                    if FencedCode.closingMarker(in: nsText, line: lines[scan], opening: opening) != nil {
                        end = scan; break
                    }
                    scan += 1
                }
                blocks.append(Block(kind: .fencedCode, range: union(lines[i...end])))
                i = end + 1

            } else if isThematicBreak(line) {
                blocks.append(Block(kind: .thematicBreak, range: lines[i]))
                i += 1

            } else if isHeading(line) {
                blocks.append(Block(kind: .heading, range: lines[i]))
                i += 1

            } else if isBlockquote(line) {
                var end = i
                while end + 1 < lines.count, isBlockquote(lineText(end + 1)) { end += 1 }
                blocks.append(Block(kind: .blockquote, range: union(lines[i...end])))
                i = end + 1

            } else if isListItem(line) {
                // Consecutive list-item lines form one list block; per-item detail is parsed in DocumentAST.
                var end = i
                while end + 1 < lines.count, isListItem(lineText(end + 1)) { end += 1 }
                blocks.append(Block(kind: .list, range: union(lines[i...end])))
                i = end + 1

            } else if i + 1 < lines.count, MarkdownTableScanner.isTableStart(header: line, separator: lineText(i + 1)) {
                // GFM table: header row, delimiter row, then optional data rows.
                var end = i + 1
                while end + 1 < lines.count, isTableRow(lineText(end + 1)) { end += 1 }
                blocks.append(Block(kind: .table, range: union(lines[i...end])))
                i = end + 1

            } else if isBlockLatexOpen(line), let end = blockLatexCloseIndex(from: i) {
                // Block LaTeX `$$…$$` — a single line or a `$$`-delimited run.
                blocks.append(Block(kind: .blockLatex, range: union(lines[i...end])))
                i = end + 1

            } else {
                // Paragraph: merge consecutive plain (non-blank, non-special) lines.
                var end = i
                while end + 1 < lines.count {
                    let next = lineText(end + 1)
                    if isBlank(next) || FencedCode.opening(in: nsText, line: lines[end + 1]) != nil || isThematicBreak(next)
                        || isHeading(next) || isBlockquote(next) || isListItem(next) { break }
                    // A table (row + separator) or a block-LaTeX run interrupts it.
                    if end + 2 < lines.count, MarkdownTableScanner.isTableStart(header: next, separator: lineText(end + 2)) { break }
                    if isBlockLatexOpen(next), blockLatexCloseIndex(from: end + 1) != nil { break }
                    end += 1
                }
                blocks.append(Block(kind: .paragraph, range: union(lines[i...end])))
                i = end + 1
            }
        }
        return blocks
    }

    // MARK: - Line classification

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `^\s*(-{3,}|\*{3,}|_{3,})\s*$` — a solid run of 3+ of one of `- * _`.
    private static func isThematicBreak(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3, let first = t.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return t.allSatisfy { $0 == first }
    }

    /// `^\s*#{1,6} +…` — 1–6 hashes after optional indent, then at least one space.
    private static func isHeading(_ line: String) -> Bool {
        var rest = Substring(line).drop { $0 == " " || $0 == "\t" }
        var hashes = 0
        while let c = rest.first, c == "#" { hashes += 1; rest = rest.dropFirst() }
        guard (1...6).contains(hashes) else { return false }
        return rest.first == " "
    }

    /// `^[ \t]{0,3}>…` — up to 3 leading spaces/tabs, then a `>`.
    private static func isBlockquote(_ line: String) -> Bool {
        var rest = Substring(line)
        var indent = 0
        while indent < 3, let c = rest.first, c == " " || c == "\t" {
            rest = rest.dropFirst(); indent += 1
        }
        return rest.first == ">"
    }

    /// A list-item line: optional indent, a bullet (`-`/`*`/`+`) or ordered marker (`1.`/`1)`), then a space/tab.
    static func isListItem(_ line: String) -> Bool {
        var rest = Substring(line).drop { $0 == " " || $0 == "\t" }
        guard let first = rest.first else { return false }
        if first == "-" || first == "*" || first == "+" {
            rest = rest.dropFirst()
        } else if first.isNumber {
            var digits = 0
            while let c = rest.first, c.isNumber, digits < 9 { rest = rest.dropFirst(); digits += 1 }
            guard let d = rest.first, d == "." || d == ")" else { return false }
            rest = rest.dropFirst()
        } else {
            return false
        }
        // A space/tab must follow the marker — a bare `-`/`*`/`1.` stays literal (pre-AST bullet behavior).
        guard let after = rest.first else { return false }
        return after == " " || after == "\t"
    }

    /// GFM table row; outer pipes are optional.
    private static func isTableRow(_ line: String) -> Bool {
        MarkdownTableScanner.isTableRow(line)
    }

    /// A block-LaTeX opener: a line whose content starts with `$$`.
    private static func isBlockLatexOpen(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("$$")
    }

    private static func union(_ ranges: ArraySlice<NSRange>) -> NSRange {
        let lo = ranges.first!.location
        let hi = NSMaxRange(ranges.last!)
        return NSRange(location: lo, length: hi - lo)
    }
}

private extension Block {
    /// A copy with the range moved by `d` UTF-16 units.
    func shifted(by d: Int) -> Block {
        Block(kind: kind, range: NSRange(location: range.location + d, length: range.length))
    }
}
