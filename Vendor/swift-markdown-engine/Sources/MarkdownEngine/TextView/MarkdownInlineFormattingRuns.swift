//
//  MarkdownInlineFormattingRuns.swift
//  MarkdownEngine
//
//  Pure, block-aware geometry for inline formatting (⌘B / ⌘I / ⌘U): given a selection and
//  the parsed block structure, which document sub-ranges should be wrapped/unwrapped. No
//  NSTextView, no Coordinator state — just NSString + ranges — so it is independently
//  testable. The side-effecting apply (text storage mutation, undo, cache) stays on the
//  Coordinator in `ContextMenu.swift`.
//

import Foundation

enum MarkdownInlineFormattingRuns {

    /// The sub-ranges of `targetRange` to wrap/unwrap: one per LINE of block content, every
    /// block marker excluded, inline code/LaTeX boundary-clipped (never mid-split). `blocks`
    /// is the parsed structure scoped to the target; `clips` are the inline code/LaTeX spans
    /// the wrap must not land inside. Excluding markers + clipping (instead of splitting at
    /// every protected span) is what fixes the marker/code corruption and keeps ⌘A's segment
    /// count at "one per selected line" rather than "one per code span" (the old freeze).
    ///
    /// Per line, not per block: the inline parser never matches a span across a line
    /// break (an unclosed marker on one line must not swallow the lines below), so a
    /// wrap around a soft-wrapped paragraph produced markup the parser could not see
    /// again — the next press found nothing to toggle off and wrapped a second time
    /// (`<u><u>…`, `****…`). One span per line is exactly what the parser renders.
    static func formattingRuns(
        targetRange: NSRange,
        blocks: [BlockNode],
        clips: [NSRange],
        nsText: NSString
    ) -> [NSRange] {
        var runs: [NSRange] = []
        let sortedClips = clips.sorted { $0.location < $1.location }
        for block in blocks {
            for content in blockContentRanges(block, nsText) {
                for line in lineRanges(in: content, nsText) {
                    let inSelection = NSIntersectionRange(line, targetRange)
                    guard inSelection.length > 0 else { continue }
                    let clipped = clipOutOfProtected(inSelection, clipsTouching(line, in: sortedClips), within: line)
                    let trimmed = MarkdownInlineFormatter.trimmedRange(clipped, in: nsText)
                    if trimmed.length > 0 { runs.append(trimmed) }
                }
            }
        }
        return runs
    }

    /// The clips that touch `range`, from a location-sorted, non-overlapping list —
    /// a binary search plus a short walk, so a document with thousands of code
    /// spans costs each line O(log clips), not O(clips).
    static func clipsTouching(_ range: NSRange, in sortedClips: [NSRange]) -> [NSRange] {
        var lo = 0, hi = sortedClips.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(sortedClips[mid]) <= range.location { lo = mid + 1 } else { hi = mid }
        }
        var result: [NSRange] = []
        var i = lo
        while i < sortedClips.count, sortedClips[i].location < NSMaxRange(range) {
            result.append(sortedClips[i])
            i += 1
        }
        return result
    }

    /// `range` cut at its line breaks — the pieces between them, ascending, breaks excluded.
    static func lineRanges(in range: NSRange, _ ns: NSString) -> [NSRange] {
        var pieces: [NSRange] = []
        var start = range.location
        let end = NSMaxRange(range)
        var i = start
        while i < end {
            if isLineBreakChar(ns.character(at: i)) {
                if i > start { pieces.append(NSRange(location: start, length: i - start)) }
                start = i + 1
            }
            i += 1
        }
        if end > start { pieces.append(NSRange(location: start, length: end - start)) }
        return pieces
    }

    /// The formattable content range(s) of a block — after its marker, never the marker.
    static func blockContentRanges(_ block: BlockNode, _ ns: NSString) -> [NSRange] {
        switch block {
        case .paragraph(let range, _):
            return [range]
        case .heading(_, let range, let markers, _):
            let markerEnd = markers.map { NSMaxRange($0) }.max() ?? range.location
            return [NSRange(location: markerEnd, length: max(0, NSMaxRange(range) - markerEnd))]
        case .list(_, let items):
            return items.map(\.contentRange)
        case .blockquote(let range, _):
            return blockquoteContentRanges(range, ns)
        case .table(let range, _):
            return tableCellContentRanges(range, ns)
        case .codeBlock, .blockLatex, .thematicBreak, .blank:
            return []   // never inline-format these
        }
    }

    /// The trimmed content span of every cell in a table — excluding the pipe delimiters,
    /// the leading/trailing pipes, and the separator row (`|---|---|`). One range per cell,
    /// so a selection spanning two cells formats each independently (`| **a** | **b** |`),
    /// never wrapping a `|`. Lets ⌘B/I/U work inside table cells (the source IS the text).
    /// Pipe/escape splitting is delegated to `MarkdownTableScanner` (its canonical owner).
    static func tableCellContentRanges(_ blockRange: NSRange, _ ns: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var cursor = blockRange.location
        let blockEnd = NSMaxRange(blockRange)
        while cursor < blockEnd {
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            cursor = NSMaxRange(line)
            let lineStr = ns.substring(with: line)
            // Skip the alignment/separator row and any non-row line; format the rest's cells.
            if MarkdownTableScanner.isTableSeparator(lineStr) { continue }
            if !MarkdownTableScanner.isTableRow(lineStr) { continue }
            result.append(contentsOf: MarkdownTableScanner.cellContentRanges(inLine: line, of: ns))
        }
        return result
    }

    /// Per-line content of a blockquote, after each line's `>`-run (handles nested `>>`).
    static func blockquoteContentRanges(_ blockRange: NSRange, _ ns: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var cursor = blockRange.location
        let blockEnd = NSMaxRange(blockRange)
        while cursor < blockEnd {
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            cursor = NSMaxRange(line)
            var i = line.location
            let lineEnd = NSMaxRange(line)
            while i < lineEnd, isInlineWhitespace(ns.character(at: i)) { i += 1 }   // indent
            while i < lineEnd, ns.character(at: i) == 0x3E {                        // '>'
                i += 1
                if i < lineEnd, ns.character(at: i) == 0x20 { i += 1 }              // one optional space
            }
            var end = lineEnd
            while end > i, isLineBreakChar(ns.character(at: end - 1)) { end -= 1 }
            if end > i { result.append(NSRange(location: i, length: end - i)) }
        }
        return result
    }

    /// Move a range's start/end OUT of any protected (inline code/LaTeX) span it falls
    /// strictly inside — OUTWARD, so the run encloses the whole protected span. Wrap
    /// markers still never land inside a code span, but ⌘B/I/U on (or inside) a code
    /// span wraps the whole token — `<u>\`report.pdf\`</u>` — instead of no-op'ing.
    /// (The parser accepts containers wrapping code spans, so the result round-trips.)
    /// Interior spans are left untouched (the wrap already legally spans them).
    ///
    /// The result is then CLAMPED back to `bounds` — the block-content region the
    /// run was derived from. Clips are parsed over the whole block, so a code span
    /// can straddle a region edge (`` | a `x | y` b | ``: the span crosses the cell
    /// pipe); an unclamped outward snap would let the run escape its cell (wrapping
    /// a `|`, corrupting the table) and let two neighboring runs overlap (breaking
    /// the disjoint-ranges contract of the atomic multi-plan apply). An endpoint
    /// that clamping puts back INSIDE a straddling clip snaps INWARD, so markers
    /// still never land mid-token — the straddling span is simply not wrapped.
    static func clipOutOfProtected(_ range: NSRange, _ clips: [NSRange], within bounds: NSRange) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        for clip in clips {
            if start > clip.location, start < NSMaxRange(clip) { start = clip.location }
            if end > clip.location, end < NSMaxRange(clip) { end = NSMaxRange(clip) }
        }
        start = max(start, bounds.location)
        end = min(end, NSMaxRange(bounds))
        for clip in clips {
            if start > clip.location, start < NSMaxRange(clip) { start = NSMaxRange(clip) }
            if end > clip.location, end < NSMaxRange(clip) { end = clip.location }
        }
        return end > start ? NSRange(location: start, length: end - start) : NSRange(location: start, length: 0)
    }

    static func isInlineWhitespace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }
    static func isLineBreakChar(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D }

    /// The paragraph-union range to inline-parse so a target's emphasis tokens are complete
    /// (emphasis can't cross a paragraph, so parsing the touched paragraphs is sufficient).
    static func parseRange(in nsText: NSString, targetRange: NSRange) -> NSRange {
        guard nsText.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        let startProbe = min(max(targetRange.location, 0), max(nsText.length - 1, 0))
        let endProbe = min(max(NSMaxRange(targetRange) - 1, startProbe), max(nsText.length - 1, 0))
        let startParagraph = nsText.paragraphRange(for: NSRange(location: startProbe, length: 0))
        let endParagraph = nsText.paragraphRange(for: NSRange(location: endProbe, length: 0))
        return NSUnionRange(startParagraph, endParagraph)
    }

    /// ALL inline tokens within `range`, with locations rebased into the document.
    /// Callers build the emphasis index AND the inline code/LaTeX clips from this
    /// one result, so it must not be filtered to emphasis kinds.
    static func inlineTokens(in nsText: NSString, range: NSRange) -> [MarkdownToken] {
        let substring = nsText.substring(with: range)
        let tokens = InlineASTAdapter.tokens(from: InlineParser.parse(substring))
        return tokens.map { token in
            MarkdownToken(
                kind: token.kind,
                range: NSRange(location: token.range.location + range.location, length: token.range.length),
                contentRange: NSRange(location: token.contentRange.location + range.location, length: token.contentRange.length),
                markerRanges: token.markerRanges.map {
                    NSRange(location: $0.location + range.location, length: $0.length)
                }
            )
        }
    }
}
