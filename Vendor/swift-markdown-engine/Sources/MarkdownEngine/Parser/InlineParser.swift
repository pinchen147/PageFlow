//
//  InlineParser.swift
//  MarkdownEngine
//
//  Phase 2 of the regex→AST refactor: the inline-structure pass. Given the
//  text of a single inline-bearing block, it produces an inline AST node tree
//  with correct CommonMark precedence — replacing the per-construct regex soup
//  that the current tokenizer uses inside each block.
//
//  Built construct by construct, test-first. Ranges in the returned tree are
//  relative to the parsed string; callers offset to document coordinates.
//
//  Pipeline (each pass claims spans only in regions not already claimed, so
//  there are never partial overlaps and buildTree is a clean containment tree):
//    1. scanCodeSpans   — highest precedence, opaque interior.
//    2. scanEscapes      — `\x` becomes a claimed span, so the escaped char is
//                          automatically inert for every pass below.
//    3. scanLinkFamily   — ![[…]], [[…]], ![…](…), […](…), ~~…~~, $…$ in
//                          precedence order. URLs allow balanced parens. A
//                          candidate overlapping a claimed span is rejected
//                          (kept literal) — this is what stops a `$…$` from
//                          spanning across a code span.
//    4. resolveEmphasis  — `*`/`_` delimiter runs over text outside every
//                          claimed span; may wrap claimed spans.
//    5. buildTree        — containment tree. Emphasis nests already-collected
//                          spans; link/strikethrough content is re-parsed
//                          recursively; code/image/wiki/embed/latex/escape are
//                          opaque leaves.
//

import Foundation

enum EmphasisKind: Equatable { case italic, bold, boldItalic }

/// A node in the inline AST.
indirect enum InlineNode: Equatable {
    case text(NSRange)
    /// `` `code` `` — opaque; `range` covers the backticks, `content` strips single-space padding.
    case code(range: NSRange, content: NSRange)
    /// `*`/`_` emphasis. `markers` is `[openMarker, closeMarker]`.
    case emphasis(EmphasisKind, range: NSRange, markers: [NSRange], children: [InlineNode])
    /// `[text](url)`. `markers` is `[ "[", "]", "(", ")" ]`; text is recursively parsed.
    case link(range: NSRange, textRange: NSRange, url: NSRange, markers: [NSRange], children: [InlineNode])
    /// `![alt](url)`. `markers` is `[ "![", "]", "(", ")" ]`. Alt is opaque.
    case image(range: NSRange, alt: NSRange, url: NSRange, markers: [NSRange])
    /// `[[Name|id]]`. `markers` is `[ "[[", "]]" ]`; `id` is nil when no `|`.
    case wikiLink(range: NSRange, name: NSRange, id: NSRange?, markers: [NSRange])
    /// `![[target]]`. `markers` is `[ "![[", "]]" ]`.
    case imageEmbed(range: NSRange, target: NSRange, markers: [NSRange])
    /// `~~text~~`. `markers` is `[openMarker, closeMarker]`; content recursively parsed.
    case strikethrough(range: NSRange, markers: [NSRange], children: [InlineNode])
    /// `==text==` (the reference editor's highlight). `markers` is `[openMarker, closeMarker]`; content recursively parsed.
    case highlight(range: NSRange, markers: [NSRange], children: [InlineNode])
    /// `<u>text</u>`. `markers` is `[openTag, closeTag]`; content recursively parsed.
    case underline(range: NSRange, markers: [NSRange], children: [InlineNode])
    /// `$math$` — opaque. `markers` is `[ "$", "$" ]`.
    case inlineLatex(range: NSRange, content: NSRange, markers: [NSRange])
    /// Backslash escape `\x`; `marker` is the `\`, `character` the now-literal punctuation.
    case escape(range: NSRange, character: NSRange, marker: NSRange)
}

enum InlineParser {

    private static let backtick: unichar = 0x60
    private static let asterisk: unichar = 0x2A
    private static let underscore: unichar = 0x5F
    private static let newline: unichar = 0x0A
    private static let bang: unichar = 0x21
    private static let lbracket: unichar = 0x5B
    private static let rbracket: unichar = 0x5D
    private static let lparen: unichar = 0x28
    private static let rparen: unichar = 0x29
    private static let pipe: unichar = 0x7C
    private static let backslash: unichar = 0x5C
    private static let tilde: unichar = 0x7E
    private static let equals: unichar = 0x3D
    private static let dollar: unichar = 0x24
    private static let lessThan: unichar = 0x3C

    // MARK: - Entry point

    static func parse(_ text: String) -> [InlineNode] {
        let ns = text as NSString
        let len = ns.length
        guard len > 0 else { return [] }

        var claimed: [Span] = []
        PerfTrace.time("ip.code") { claimed = scanCodeSpans(ns, len: len) }
        PerfTrace.time("ip.escapes") { claimed += scanEscapes(ns, len: len, claimed: claimed.map(\.fullRange)) }
        PerfTrace.time("ip.links") { claimed += scanLinkFamily(ns, len: len, claimed: claimed) }
        var emphasis: [Span] = []
        PerfTrace.time("ip.emphasis") { emphasis = resolveEmphasis(ns, len: len, claimedRanges: claimed.map(\.fullRange)) }
        var tree: [InlineNode] = []
        PerfTrace.time("ip.tree") { tree = buildTree(region: NSRange(location: 0, length: len), spans: claimed + emphasis, ns: ns) }
        return tree
    }

    /// Parse the inline content of `range` within `ns`, returning nodes in absolute document coordinates.
    static func parse(_ ns: NSString, range: NSRange) -> [InlineNode] {
        offsetNodes(parse(ns.substring(with: range)), by: range.location)
    }

    /// A derived activation target; escape decoding never rewrites the stored Markdown.
    /// The decoded destination of a link or image whose `(` is at `openParen`:
    /// title and `<…>` excluded, backslash escapes resolved.
    static func linkDestination(in source: NSString, openParen: Int) -> String? {
        guard let range = linkDestinationRange(in: source, openParen: openParen) else { return nil }
        return decodedLinkDestination(in: source, range: range)
    }

    /// The literal destination range, excluding angle brackets and an optional title.
    static func linkDestinationRange(in source: NSString, openParen: Int) -> NSRange? {
        scanInlineLinkTarget(source, source.length, from: openParen + 1)?.destination
    }

    static func decodedLinkDestination(in source: NSString, range: NSRange) -> String {
        let units = Array(source.substring(with: range).utf16)
        var decoded: [UInt16] = []
        decoded.reserveCapacity(units.count)
        var cursor = 0
        while cursor < units.count {
            if units[cursor] == backslash, cursor + 1 < units.count,
               isAsciiPunctuationChar(units[cursor + 1]) { cursor += 1 }
            decoded.append(units[cursor])
            cursor += 1
        }
        return String(decoding: decoded, as: UTF16.self)
    }

    // MARK: - Span model

    private enum Span {
        case code(range: NSRange, content: NSRange)
        case emphasis(kind: EmphasisKind, range: NSRange, open: NSRange, close: NSRange)
        case link(range: NSRange, textRange: NSRange, url: NSRange, markers: [NSRange])
        case image(range: NSRange, alt: NSRange, url: NSRange, markers: [NSRange])
        case wikiLink(range: NSRange, name: NSRange, id: NSRange?, markers: [NSRange])
        case imageEmbed(range: NSRange, target: NSRange, markers: [NSRange])
        case strikethrough(range: NSRange, contentRange: NSRange, markers: [NSRange])
        case highlight(range: NSRange, contentRange: NSRange, markers: [NSRange])
        case underline(range: NSRange, contentRange: NSRange, markers: [NSRange])
        case inlineLatex(range: NSRange, content: NSRange, markers: [NSRange])
        case escape(range: NSRange, character: NSRange, marker: NSRange)

        var fullRange: NSRange {
            switch self {
            case .code(let r, _), .emphasis(_, let r, _, _), .link(let r, _, _, _),
                 .image(let r, _, _, _), .wikiLink(let r, _, _, _), .imageEmbed(let r, _, _),
                 .strikethrough(let r, _, _), .highlight(let r, _, _), .underline(let r, _, _),
                 .inlineLatex(let r, _, _), .escape(let r, _, _):
                return r
            }
        }
        /// Region whose interior holds collected child spans. Emphasis nests its
        /// children directly; underline/strikethrough re-parse their content in
        /// `buildTree`, but must still count as containers HERE so a claimed
        /// span they wrap (code inside `<u>…</u>`) is excluded from the top
        /// level instead of being emitted twice.
        var containerContent: NSRange? {
            switch self {
            case .emphasis(_, _, let open, let close):
                return NSRange(location: NSMaxRange(open), length: close.location - NSMaxRange(open))
            case .underline(_, let content, _), .strikethrough(_, let content, _), .highlight(_, let content, _):
                return content
            case .link(let range, _, _, _), .image(let range, _, _, _):
                return range
            default:
                return nil
            }
        }

        /// A link's text or an image's description, and its four markers.
        var labelAndMarkers: (label: NSRange, markers: [NSRange])? {
            switch self {
            case .link(_, let label, _, let markers), .image(_, let label, _, let markers): return (label, markers)
            default: return nil
            }
        }
    }

    // MARK: - 1. Code spans

    private static func scanCodeSpans(_ ns: NSString, len: Int) -> [Span] {
        var spans: [Span] = []
        var i = 0
        while i < len {
            guard ns.character(at: i) == backtick, !isEscaped(i, ns) else { i += 1; continue }
            let runStart = i
            var j = i
            while j < len, ns.character(at: j) == backtick { j += 1 }
            let runLen = j - runStart
            guard let close = closingBacktickRun(in: ns, from: j, length: len, runLen: runLen) else {
                i = j; continue
            }
            let codeRange = NSRange(location: runStart, length: (close + runLen) - runStart)
            let rawContent = NSRange(location: j, length: close - j)
            spans.append(.code(range: codeRange, content: strippedCodeContent(rawContent, in: ns)))
            i = close + runLen
        }
        return spans
    }

    private static func closingBacktickRun(in ns: NSString, from: Int, length len: Int, runLen: Int) -> Int? {
        var k = from
        while k < len {
            guard ns.character(at: k) == backtick, !isEscaped(k, ns) else { k += 1; continue }
            let start = k
            while k < len, ns.character(at: k) == backtick { k += 1 }
            if k - start == runLen { return start }
        }
        return nil
    }

    private static func strippedCodeContent(_ raw: NSRange, in ns: NSString) -> NSRange {
        let space: unichar = 0x20
        guard raw.length >= 2,
              ns.character(at: raw.location) == space,
              ns.character(at: NSMaxRange(raw) - 1) == space else { return raw }
        var allSpaces = true
        for k in raw.location..<NSMaxRange(raw) where ns.character(at: k) != space {
            allSpaces = false; break
        }
        guard !allSpaces else { return raw }
        return NSRange(location: raw.location + 1, length: raw.length - 2)
    }

    // MARK: - 2. Backslash escapes (claimed → escaped chars are inert everywhere)

    private static func scanEscapes(_ ns: NSString, len: Int, claimed: [NSRange]) -> [Span] {
        func inClaimed(_ idx: Int) -> Bool { claimed.contains { NSLocationInRange(idx, $0) } }
        var spans: [Span] = []
        var i = 0
        while i < len - 1 {
            if ns.character(at: i) == backslash, !inClaimed(i), isAsciiPunctuationChar(ns.character(at: i + 1)) {
                spans.append(.escape(
                    range: NSRange(location: i, length: 2),
                    character: NSRange(location: i + 1, length: 1),
                    marker: NSRange(location: i, length: 1)
                ))
                i += 2   // the escaped char can't itself start a new escape (even/odd `\\`)
            } else {
                i += 1
            }
        }
        return spans
    }

    // MARK: - 3. Link family / strikethrough / inline LaTeX

    private static func scanLinkFamily(_ ns: NSString, len: Int, claimed: [Span]) -> [Span] {
        // Claimed spans (code, escapes) sorted once; every lookup below is a
        // binary search or a cursor step instead of a scan of the whole list —
        // a note full of code spans and escaped dollars made this pass half of
        // the inline parse.
        let sortedSpans = claimed.sorted { $0.fullRange.location < $1.fullRange.location }
        let sorted = sortedSpans.map(\.fullRange)
        /// Index of the first claimed span ending after `location`.
        func firstEnding(after location: Int) -> Int {
            var lo = 0, hi = sorted.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if NSMaxRange(sorted[mid]) <= location { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
        func overlapsClaimed(_ range: NSRange) -> Bool {
            let k = firstEnding(after: range.location)
            return k < sorted.count && sorted[k].location < NSMaxRange(range)
        }
        /// A container span (one with `containerContent` — underline/strikethrough)
        /// may legitimately WRAP claimed spans — `<u>a \`code\` b</u>` is one
        /// underline holding a code child — so it is accepted iff every claimed
        /// overlap falls wholly inside its content (markers clear by construction).
        /// Non-containers keep the strict full-range rule. Deriving the rule from
        /// `containerContent` keeps this and `buildTree`'s child-nesting in lockstep:
        /// a kind can't be accepted here without also nesting there. Without this,
        /// the span was silently dropped, so a re-applied ⌘U saw no enclosing token
        /// and nested a fresh `<u>` on every press.
        func accepts(_ span: Span) -> Bool {
            let full = span.fullRange
            guard let content = span.containerContent else {
                return !overlapsClaimed(full)
            }
            var k = firstEnding(after: full.location)
            while k < sorted.count, sorted[k].location < NSMaxRange(full) {
                let overlap = NSIntersectionRange(sorted[k], full)
                if overlap.length > 0 {
                    if let (label, markers) = span.labelAndMarkers {
                        if !rangeContains(label, sorted[k]) {
                            let target = NSRange(location: NSMaxRange(markers[2]),
                                                 length: markers[3].location - NSMaxRange(markers[2]))
                            guard case .escape = sortedSpans[k], rangeContains(target, sorted[k]) else { return false }
                        }
                    } else if !rangeContains(content, overlap) { return false }
                }
                k += 1
            }
            return true
        }
        var spans: [Span] = []
        var i = 0
        var next = 0   // cursor into `sorted`: the first claimed span that can still contain `i`
        while i < len {
            while next < sorted.count, NSMaxRange(sorted[next]) <= i { next += 1 }
            if next < sorted.count, sorted[next].location <= i { i = NSMaxRange(sorted[next]); continue }
            let c = ns.character(at: i)
            guard c == bang || c == lbracket || c == tilde || c == equals || c == lessThan || c == dollar else { i += 1; continue }
            if let span = matchClaimedSpan(ns, len, at: i, claimed: sorted), accepts(span) {
                spans.append(span)
                i = NSMaxRange(span.fullRange)
            } else {
                i += 1
            }
        }
        return spans
    }

    private static func matchClaimedSpan(_ ns: NSString, _ len: Int, at i: Int, claimed: [NSRange]) -> Span? {
        let c = ns.character(at: i)
        let c1 = peek(ns, i + 1, len)
        let c2 = peek(ns, i + 2, len)
        if c == bang, c1 == lbracket, c2 == lbracket { return matchImageEmbed(ns, len, start: i) }
        if c == lbracket, c1 == lbracket { return matchWikiLink(ns, len, start: i) }
        if c == bang, c1 == lbracket { return matchImage(ns, len, start: i, claimed: claimed) }
        if c == lbracket { return matchLink(ns, len, start: i, claimed: claimed) }
        if c == tilde, c1 == tilde { return matchStrikethrough(ns, len, start: i, claimed: claimed) }
        if c == equals, c1 == equals { return matchHighlight(ns, len, start: i, claimed: claimed) }
        if c == lessThan { return matchUnderline(ns, len, start: i, claimed: claimed) }
        if c == dollar, c1 != dollar { return matchInlineLatex(ns, len, start: i) }
        return nil
    }

    private static func peek(_ ns: NSString, _ idx: Int, _ len: Int) -> unichar? {
        (idx >= 0 && idx < len) ? ns.character(at: idx) : nil
    }

    /// `![[ target ]]`
    private static func matchImageEmbed(_ ns: NSString, _ len: Int, start i: Int) -> Span? {
        let contentStart = i + 3
        guard let close = closeDoubleBracket(ns, len, from: contentStart) else { return nil }
        return .imageEmbed(
            range: NSRange(location: i, length: (close + 2) - i),
            target: NSRange(location: contentStart, length: close - contentStart),
            markers: [NSRange(location: i, length: 3), NSRange(location: close, length: 2)]
        )
    }

    /// `[[ name (| id)? ]]`
    private static func matchWikiLink(_ ns: NSString, _ len: Int, start i: Int) -> Span? {
        let contentStart = i + 2
        var k = contentStart
        var pipeIdx = -1
        while k < len {
            let ch = ns.character(at: k)
            if ch == newline { return nil }
            if ch == pipe, pipeIdx == -1 { pipeIdx = k }
            if ch == rbracket {
                guard peek(ns, k + 1, len) == rbracket else { return nil }
                let range = NSRange(location: i, length: (k + 2) - i)
                let markers = [NSRange(location: i, length: 2), NSRange(location: k, length: 2)]
                if pipeIdx >= 0 {
                    return .wikiLink(range: range,
                                     name: NSRange(location: contentStart, length: pipeIdx - contentStart),
                                     id: NSRange(location: pipeIdx + 1, length: k - (pipeIdx + 1)),
                                     markers: markers)
                }
                return .wikiLink(range: range,
                                 name: NSRange(location: contentStart, length: k - contentStart),
                                 id: nil, markers: markers)
            }
            k += 1
        }
        return nil
    }

    /// `![ alt ]( url )`. The description ends where a link's text would, so
    /// an escaped `\]` or `\|` (which PageFlow writes in descriptions) stays
    /// inside it.
    private static func matchImage(_ ns: NSString, _ len: Int, start i: Int, claimed: [NSRange]) -> Span? {
        let altStart = i + 2
        guard let closeBracket = linkLabelEnd(ns, len, from: altStart, claimed: claimed),
              peek(ns, closeBracket + 1, len) == lparen,
              let target = scanInlineLinkTarget(ns, len, from: closeBracket + 2) else { return nil }
        let closeParen = target.close
        return .image(
            range: NSRange(location: i, length: (closeParen + 1) - i),
            alt: NSRange(location: altStart, length: closeBracket - altStart),
            url: target.destination,
            markers: [
                NSRange(location: i, length: 2),
                NSRange(location: closeBracket, length: 1),
                NSRange(location: closeBracket + 1, length: 1),
                NSRange(location: closeParen, length: 1),
            ]
        )
    }

    /// `[ text ]( url )`
    private static func matchLink(_ ns: NSString, _ len: Int, start i: Int, claimed: [NSRange]) -> Span? {
        let textStart = i + 1
        guard let closeBracket = linkLabelEnd(ns, len, from: textStart, claimed: claimed),
              closeBracket > textStart,
              peek(ns, closeBracket + 1, len) == lparen,
              let target = scanInlineLinkTarget(ns, len, from: closeBracket + 2) else { return nil }
        let closeParen = target.close
        return .link(
            range: NSRange(location: i, length: (closeParen + 1) - i),
            textRange: NSRange(location: textStart, length: closeBracket - textStart),
            url: target.destination,
            markers: [
                NSRange(location: i, length: 1),
                NSRange(location: closeBracket, length: 1),
                NSRange(location: closeBracket + 1, length: 1),
                NSRange(location: closeParen, length: 1),
            ]
        )
    }

    /// Code and escaped brackets have no structural role in a link label.
    private static func linkLabelEnd(_ ns: NSString, _ len: Int, from: Int, claimed: [NSRange]) -> Int? {
        var lo = 0, hi = claimed.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(claimed[mid]) <= from { lo = mid + 1 } else { hi = mid }
        }
        var next = lo, cursor = from, depth = 0
        while cursor < len {
            while next < claimed.count, NSMaxRange(claimed[next]) <= cursor { next += 1 }
            if next < claimed.count, claimed[next].location <= cursor {
                cursor = NSMaxRange(claimed[next]); continue
            }
            let unit = ns.character(at: cursor)
            if unit == newline || unit == 0x0D { return nil }
            if unit == lbracket { depth += 1 }
            if unit == rbracket {
                if depth == 0 { return cursor }
                depth -= 1
            }
            cursor += 1
        }
        return nil
    }

    /// Scan the destination separately from its optional title, retaining literal source ranges.
    private static func scanInlineLinkTarget(_ ns: NSString, _ len: Int, from: Int) -> (destination: NSRange, close: Int)? {
        func whitespace(_ unit: unichar) -> Bool { unit == 0x20 || unit == 0x09 }
        var cursor = from
        while cursor < len, whitespace(ns.character(at: cursor)) { cursor += 1 }
        guard cursor < len else { return nil }
        let start: Int
        let end: Int
        if ns.character(at: cursor) == lessThan {
            cursor += 1
            start = cursor
            while cursor < len {
                let unit = ns.character(at: cursor)
                if unit == backslash, cursor + 1 < len, isAsciiPunctuationChar(ns.character(at: cursor + 1)) {
                    cursor += 2; continue
                }
                if unit == 0x3E { break }
                if unit == lessThan || unit == newline || unit == 0x0D { return nil }
                cursor += 1
            }
            guard cursor < len else { return nil }
            end = cursor
            cursor += 1
        } else {
            start = cursor
            var depth = 0
            while cursor < len {
                let unit = ns.character(at: cursor)
                if unit == backslash, cursor + 1 < len, isAsciiPunctuationChar(ns.character(at: cursor + 1)) {
                    cursor += 2; continue
                }
                if unit == newline || unit == 0x0D || unit == lessThan { return nil }
                if whitespace(unit) { break }
                if unit == lparen { depth += 1 }
                if unit == rparen {
                    if depth == 0 { break }
                    depth -= 1
                }
                cursor += 1
            }
            guard depth == 0 else { return nil }
            end = cursor
        }
        let destination = NSRange(location: start, length: end - start)
        let afterDestination = cursor
        while cursor < len, whitespace(ns.character(at: cursor)) { cursor += 1 }
        guard cursor < len else { return nil }
        if ns.character(at: cursor) == rparen { return (destination, cursor) }
        guard cursor > afterDestination else { return nil }
        let quote = ns.character(at: cursor)
        guard quote == 0x22 || quote == 0x27 || quote == lparen else { return nil }
        let titleEnd = quote == lparen ? rparen : quote
        cursor += 1
        while cursor < len {
            let unit = ns.character(at: cursor)
            if unit == backslash, cursor + 1 < len, isAsciiPunctuationChar(ns.character(at: cursor + 1)) {
                cursor += 2; continue
            }
            if unit == titleEnd { break }
            if unit == newline || unit == 0x0D || (quote == lparen && unit == lparen) { return nil }
            cursor += 1
        }
        guard cursor < len else { return nil }
        cursor += 1
        while cursor < len, whitespace(ns.character(at: cursor)) { cursor += 1 }
        guard cursor < len, ns.character(at: cursor) == rparen else { return nil }
        return (destination, cursor)
    }

    /// `~~ text ~~` — text has no `~` outside claimed spans; not part of a
    /// longer `~` run. Claimed (code) interiors are skipped whole, so a `~~`
    /// inside `` `code` `` can neither close nor abort the span.
    private static func matchStrikethrough(_ ns: NSString, _ len: Int, start i: Int, claimed: [NSRange]) -> Span? {
        if i > 0, ns.character(at: i - 1) == tilde { return nil }
        let contentStart = i + 2
        var k = contentStart
        while k < len {
            if let inside = claimed.first(where: { NSLocationInRange(k, $0) }) {
                k = NSMaxRange(inside)
                continue
            }
            let ch = ns.character(at: k)
            if ch == newline { return nil }
            if ch == tilde {
                guard peek(ns, k + 1, len) == tilde else { return nil }
                guard k > contentStart, peek(ns, k + 2, len) != tilde else { return nil }
                return .strikethrough(
                    range: NSRange(location: i, length: (k + 2) - i),
                    contentRange: NSRange(location: contentStart, length: k - contentStart),
                    markers: [NSRange(location: i, length: 2), NSRange(location: k, length: 2)]
                )
            }
            k += 1
        }
        return nil
    }

    /// `==text==`: the content may not start or end with whitespace (so `a == b`
    /// stays text), and a run of three or more `=` neither opens nor closes it.
    private static func matchHighlight(_ ns: NSString, _ len: Int, start i: Int, claimed: [NSRange]) -> Span? {
        if i > 0, ns.character(at: i - 1) == equals { return nil }
        let contentStart = i + 2
        guard let first = peek(ns, contentStart, len), first != equals, first != 0x20, first != 0x09, first != newline else { return nil }
        var k = contentStart
        while k < len {
            if let inside = claimed.first(where: { NSLocationInRange(k, $0) }) {
                k = NSMaxRange(inside)
                continue
            }
            let ch = ns.character(at: k)
            if ch == newline { return nil }
            if ch == equals, peek(ns, k + 1, len) == equals, k > contentStart, peek(ns, k + 2, len) != equals {
                let last = ns.character(at: k - 1)
                guard last != 0x20, last != 0x09 else { k += 2; continue }
                return .highlight(
                    range: NSRange(location: i, length: (k + 2) - i),
                    contentRange: NSRange(location: contentStart, length: k - contentStart),
                    markers: [NSRange(location: i, length: 2), NSRange(location: k, length: 2)]
                )
            }
            k += 1
        }
        return nil
    }

    /// CommonMark-compatible raw HTML underline generated by the editor command.
    /// Claimed (code) interiors are skipped whole, so a `</u>` inside `` `code` ``
    /// cannot close the span.
    private static func matchUnderline(_ ns: NSString, _ len: Int, start i: Int, claimed: [NSRange]) -> Span? {
        guard matches(ns, len, at: i, literal: "<u>") else { return nil }
        let contentStart = i + 3
        var k = contentStart
        while k < len {
            if let inside = claimed.first(where: { NSLocationInRange(k, $0) }) {
                k = NSMaxRange(inside)
                continue
            }
            // Like every other span: an underline never crosses a line — an
            // unclosed `<u>` in one table cell must not swallow the rows below.
            if ns.character(at: k) == newline { return nil }
            if matches(ns, len, at: k, literal: "</u>") {
                guard k > contentStart else { return nil }
                return .underline(
                    range: NSRange(location: i, length: (k + 4) - i),
                    contentRange: NSRange(location: contentStart, length: k - contentStart),
                    markers: [NSRange(location: i, length: 3), NSRange(location: k, length: 4)]
                )
            }
            k += 1
        }
        return nil
    }

    /// `$ math $` — single dollars, content has no `$`, passes the math heuristic.
    private static func matchInlineLatex(_ ns: NSString, _ len: Int, start i: Int) -> Span? {
        if i > 0, ns.character(at: i - 1) == dollar { return nil }
        let contentStart = i + 1
        var k = contentStart
        while k < len {
            let ch = ns.character(at: k)
            if ch == newline { return nil }
            if ch == dollar {
                guard k > contentStart, peek(ns, k + 1, len) != dollar else { return nil }
                let content = NSRange(location: contentStart, length: k - contentStart)
                guard isInlineMathContent(ns, content) else { return nil }
                return .inlineLatex(
                    range: NSRange(location: i, length: (k + 1) - i),
                    content: content,
                    markers: [NSRange(location: i, length: 1), NSRange(location: k, length: 1)]
                )
            }
            k += 1
        }
        return nil
    }

    private static func closeDoubleBracket(_ ns: NSString, _ len: Int, from: Int) -> Int? {
        var k = from
        while k < len {
            let ch = ns.character(at: k)
            if ch == newline { return nil }
            if ch == rbracket { return peek(ns, k + 1, len) == rbracket ? k : nil }
            k += 1
        }
        return nil
    }

    /// Rejects currency-looking `$…$`; otherwise single-dollar spans are math.
    /// Works on the string in place: a money-heavy note tries this for every `$`.
    private static func isInlineMathContent(_ ns: NSString, _ content: NSRange) -> Bool {
        var start = content.location
        var end = NSMaxRange(content)
        while start < end, isWhitespaceOrBoundary(start, ns, end) { start += 1 }
        while end > start, isWhitespaceOrBoundary(end - 1, ns, end) { end -= 1 }
        guard end > start else { return false }
        return !isCurrencyLike(ns, from: start, to: end)
    }

    private static func isCurrencyLike(_ ns: NSString, from start: Int, to n: Int) -> Bool {
        func digit(_ x: Int) -> Bool { x >= start && x < n && ns.character(at: x) >= 0x30 && ns.character(at: x) <= 0x39 }
        var i = start
        if i < n, ns.character(at: i) == 0x2B || ns.character(at: i) == 0x2D { i += 1 }   // + / -
        guard digit(i) else { return false }
        var sawDigit = false
        while i < n {
            if digit(i) { sawDigit = true; i += 1 }
            else if ns.character(at: i) == 0x2C, digit(i + 1), digit(i + 2), digit(i + 3), !digit(i + 4) {
                i += 4   // a strict `,DDD` thousands group
            } else { break }
        }
        guard sawDigit else { return false }
        if i < n, ns.character(at: i) == 0x2E {            // optional `.DDD+`
            i += 1
            guard digit(i) else { return false }
            while digit(i) { i += 1 }
        }
        return i == n
    }

    // MARK: - 4. Emphasis (delimiter runs)

    private struct DelimRun {
        let char: unichar
        let originalLength: Int
        var leftEdge: Int
        var rightEdge: Int
        let canOpen: Bool
        let canClose: Bool
        let lineIdx: Int
        var remaining: Int { rightEdge - leftEdge }
    }

    private static func resolveEmphasis(_ ns: NSString, len: Int, claimedRanges: [NSRange]) -> [Span] {
        var runs = collectDelimiterRuns(ns, len: len, claimedRanges: claimedRanges)
        guard !runs.isEmpty else { return [] }
        var stack: [Int] = []
        var spans: [Span] = []
        for idx in runs.indices {
            if runs[idx].canClose {
                closeAgainstStack(closerIdx: idx, runs: &runs, stack: &stack, spans: &spans)
            }
            if runs[idx].canOpen && runs[idx].remaining > 0 {
                stack.append(idx)
            }
        }
        return spans
    }

    private static func collectDelimiterRuns(_ ns: NSString, len: Int, claimedRanges: [NSRange]) -> [DelimRun] {
        func inClaimed(_ idx: Int) -> Bool {
            for r in claimedRanges where NSLocationInRange(idx, r) { return true }
            return false
        }
        var runs: [DelimRun] = []
        var lineIdx = 0
        var i = 0
        while i < len {
            let c = ns.character(at: i)
            if c == newline { lineIdx += 1; i += 1; continue }
            guard c == asterisk || c == underscore, !inClaimed(i) else { i += 1; continue }
            var j = i
            while j < len, ns.character(at: j) == c { j += 1 }

            let before = i - 1, after = j
            let beforeWs = isWhitespaceOrBoundary(before, ns, len)
            let beforePunct = isAsciiPunctuation(before, ns, len)
            let afterWs = isWhitespaceOrBoundary(after, ns, len)
            let afterPunct = isAsciiPunctuation(after, ns, len)
            let leftFlanking = !afterWs && (!afterPunct || beforeWs || beforePunct)
            let rightFlanking = !beforeWs && (!beforePunct || afterWs || afterPunct)

            let canOpen: Bool, canClose: Bool
            if c == underscore {
                canOpen = leftFlanking && (!rightFlanking || beforePunct)
                canClose = rightFlanking && (!leftFlanking || afterPunct)
            } else {
                canOpen = leftFlanking
                canClose = rightFlanking
            }
            runs.append(DelimRun(
                char: c, originalLength: j - i, leftEdge: i, rightEdge: j,
                canOpen: canOpen, canClose: canClose, lineIdx: lineIdx
            ))
            i = j
        }
        return runs
    }

    private static func closeAgainstStack(
        closerIdx: Int, runs: inout [DelimRun], stack: inout [Int], spans: inout [Span]
    ) {
        var sp = stack.count - 1
        while sp >= 0, runs[closerIdx].remaining > 0 {
            let openerIdx = stack[sp]
            if runs[openerIdx].char != runs[closerIdx].char { sp -= 1; continue }
            if runs[openerIdx].lineIdx != runs[closerIdx].lineIdx {
                stack.remove(at: sp); sp -= 1; continue
            }
            let avail = min(runs[openerIdx].remaining, runs[closerIdx].remaining)
            if avail == 0 { stack.remove(at: sp); sp -= 1; continue }

            let openerBoth = runs[openerIdx].canOpen && runs[openerIdx].canClose
            let closerBoth = runs[closerIdx].canOpen && runs[closerIdx].canClose
            if openerBoth || closerBoth {
                let sum = runs[openerIdx].originalLength + runs[closerIdx].originalLength
                let bothMod3 = runs[openerIdx].originalLength % 3 == 0 && runs[closerIdx].originalLength % 3 == 0
                if sum % 3 == 0 && !bothMod3 { sp -= 1; continue }
            }

            let matchLen = avail >= 3 ? 3 : (avail >= 2 ? 2 : 1)
            let openerMarkerStart = runs[openerIdx].rightEdge - matchLen
            let closerMarkerStart = runs[closerIdx].leftEdge
            let kind: EmphasisKind = matchLen == 3 ? .boldItalic : (matchLen == 2 ? .bold : .italic)

            spans.append(.emphasis(
                kind: kind,
                range: NSRange(location: openerMarkerStart, length: (closerMarkerStart + matchLen) - openerMarkerStart),
                open: NSRange(location: openerMarkerStart, length: matchLen),
                close: NSRange(location: closerMarkerStart, length: matchLen)
            ))

            runs[openerIdx].rightEdge -= matchLen
            runs[closerIdx].leftEdge += matchLen
            if runs[openerIdx].remaining == 0 { stack.remove(at: sp) }
            sp -= 1
        }
    }

    // MARK: - 5. Containment tree

    private static func buildTree(region: NSRange, spans: [Span], ns: NSString) -> [InlineNode] {
        let inRegion = spans.filter { rangeContains(region, $0.fullRange) }
            .sorted { $0.fullRange.location != $1.fullRange.location
                ? $0.fullRange.location < $1.fullRange.location
                : $0.fullRange.length > $1.fullRange.length }

        // Top-level spans: those no earlier-starting container holds. One sweep
        // over the location-sorted spans with a stack of open containers, instead
        // of testing every span against every other (a table row with dozens of
        // links and code spans made that the slowest part of the parse).
        var top: [Span] = []
        var open: [NSRange] = []   // content ranges of containers still open, outermost first
        for span in inRegion {
            let full = span.fullRange
            while let last = open.last, NSMaxRange(last) <= full.location { open.removeLast() }
            let isChild = open.contains { rangeContains($0, full) }
            if !isChild { top.append(span) }
            if let content = span.containerContent { open.append(content) }
        }
        var result: [InlineNode] = []
        var cursor = region.location

        for span in top {
            let fr = span.fullRange
            if fr.location > cursor {
                result.append(.text(NSRange(location: cursor, length: fr.location - cursor)))
            }
            switch span {
            case .code(let range, let content):
                result.append(.code(range: range, content: content))
            case .emphasis(let kind, let range, let open, let close):
                let content = NSRange(location: NSMaxRange(open), length: close.location - NSMaxRange(open))
                let childSpans = inRegion.filter { rangeContains(content, $0.fullRange) && !equalRange($0.fullRange, fr) }
                result.append(.emphasis(kind, range: range, markers: [open, close],
                                        children: buildTree(region: content, spans: childSpans, ns: ns)))
            case .link(let range, let textRange, let url, let markers):
                result.append(.link(range: range, textRange: textRange, url: url, markers: markers,
                                     children: reparse(textRange, ns: ns)))
            case .image(let range, let alt, let url, let markers):
                result.append(.image(range: range, alt: alt, url: url, markers: markers))
            case .wikiLink(let range, let name, let id, let markers):
                result.append(.wikiLink(range: range, name: name, id: id, markers: markers))
            case .imageEmbed(let range, let target, let markers):
                result.append(.imageEmbed(range: range, target: target, markers: markers))
            case .strikethrough(let range, let contentRange, let markers):
                result.append(.strikethrough(range: range, markers: markers,
                                             children: reparse(contentRange, ns: ns)))
            case .highlight(let range, let contentRange, let markers):
                result.append(.highlight(range: range, markers: markers,
                                         children: reparse(contentRange, ns: ns)))
            case .underline(let range, let contentRange, let markers):
                result.append(.underline(range: range, markers: markers,
                                         children: reparse(contentRange, ns: ns)))
            case .inlineLatex(let range, let content, let markers):
                result.append(.inlineLatex(range: range, content: content, markers: markers))
            case .escape(let range, let character, let marker):
                result.append(.escape(range: range, character: character, marker: marker))
            }
            cursor = NSMaxRange(fr)
        }
        if cursor < NSMaxRange(region) {
            result.append(.text(NSRange(location: cursor, length: NSMaxRange(region) - cursor)))
        }
        return result
    }

    /// Recursively parse a sub-range's content, offset back to absolute coordinates.
    private static func reparse(_ range: NSRange, ns: NSString) -> [InlineNode] {
        offsetNodes(parse(ns.substring(with: range)), by: range.location)
    }

    // MARK: - Helpers

    private static func offsetNodes(_ nodes: [InlineNode], by delta: Int) -> [InlineNode] {
        nodes.map { offset($0, by: delta) }
    }

    private static func offset(_ node: InlineNode, by d: Int) -> InlineNode {
        func s(_ r: NSRange) -> NSRange { NSRange(location: r.location + d, length: r.length) }
        switch node {
        case .text(let r): return .text(s(r))
        case .code(let r, let c): return .code(range: s(r), content: s(c))
        case .emphasis(let k, let r, let m, let ch): return .emphasis(k, range: s(r), markers: m.map(s), children: offsetNodes(ch, by: d))
        case .link(let r, let tr, let u, let m, let ch): return .link(range: s(r), textRange: s(tr), url: s(u), markers: m.map(s), children: offsetNodes(ch, by: d))
        case .image(let r, let a, let u, let m): return .image(range: s(r), alt: s(a), url: s(u), markers: m.map(s))
        case .wikiLink(let r, let n, let id, let m): return .wikiLink(range: s(r), name: s(n), id: id.map(s), markers: m.map(s))
        case .imageEmbed(let r, let t, let m): return .imageEmbed(range: s(r), target: s(t), markers: m.map(s))
        case .strikethrough(let r, let m, let ch): return .strikethrough(range: s(r), markers: m.map(s), children: offsetNodes(ch, by: d))
        case .highlight(let r, let m, let ch): return .highlight(range: s(r), markers: m.map(s), children: offsetNodes(ch, by: d))
        case .underline(let r, let m, let ch): return .underline(range: s(r), markers: m.map(s), children: offsetNodes(ch, by: d))
        case .inlineLatex(let r, let c, let m): return .inlineLatex(range: s(r), content: s(c), markers: m.map(s))
        case .escape(let r, let c, let m): return .escape(range: s(r), character: s(c), marker: s(m))
        }
    }

    private static func rangeContains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    private static func equalRange(_ a: NSRange, _ b: NSRange) -> Bool {
        a.location == b.location && a.length == b.length
    }

    private static func isWhitespaceOrBoundary(_ idx: Int, _ ns: NSString, _ len: Int) -> Bool {
        guard idx >= 0, idx < len else { return true }
        let c = ns.character(at: idx)
        return c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
    }

    private static func isAsciiPunctuation(_ idx: Int, _ ns: NSString, _ len: Int) -> Bool {
        guard idx >= 0, idx < len else { return false }
        return isAsciiPunctuationChar(ns.character(at: idx))
    }

    private static func isAsciiPunctuationChar(_ c: unichar) -> Bool {
        (c >= 0x21 && c <= 0x2F) || (c >= 0x3A && c <= 0x40)
            || (c >= 0x5B && c <= 0x60) || (c >= 0x7B && c <= 0x7E)
    }

    private static func matches(_ ns: NSString, _ len: Int, at location: Int, literal: String) -> Bool {
        let literalLength = literal.utf16.count
        guard location >= 0, location + literalLength <= len else { return false }
        return ns.substring(with: NSRange(location: location, length: literalLength)) == literal
    }

    /// A character is backslash-escaped when preceded by an odd run of `\`.
    private static func isEscaped(_ idx: Int, _ ns: NSString) -> Bool {
        var count = 0
        var k = idx - 1
        while k >= 0, ns.character(at: k) == backslash { count += 1; k -= 1 }
        return count % 2 == 1
    }
}
