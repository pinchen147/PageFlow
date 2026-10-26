//
//  MarkdownAST.swift
//  MarkdownEngine
//
//  Phase 2.5 foundation: the semantic document AST. Combines the block-structure
//  pass (BlockParser) with the inline pass (InlineParser) into one tree of
//  `BlockNode`s, each inline-bearing block carrying its parsed inline children
//  in absolute document coordinates. The AST-native styler (next increments)
//  walks this tree instead of consuming flat tokens.
//

import Foundation

/// One list-item line: marker run, optional GFM checkbox, and indent column count.
struct ListItem: Equatable {
    let range: NSRange          // the item's full line (incl. trailing newline)
    let marker: NSRange
    let ordered: Bool
    let number: Int?            // ordered start value, e.g. `5.` → 5
    let checkbox: NSRange?
    let checked: Bool
    let indent: Int
    let contentRange: NSRange   // text after the marker (and checkbox)
    let inlines: [InlineNode]
}

/// One GFM table cell: its trimmed content span (pipes and padding excluded)
/// and the inline markup inside it, in absolute document coordinates.
struct TableCell: Equatable {
    let range: NSRange
    let inlines: [InlineNode]
}

/// A top-level block in the document AST.
indirect enum BlockNode: Equatable {
    case paragraph(range: NSRange, inlines: [InlineNode])
    case heading(level: Int, range: NSRange, markers: [NSRange], inlines: [InlineNode])
    case blockquote(range: NSRange, inlines: [InlineNode])
    case list(range: NSRange, items: [ListItem])
    case codeBlock(range: NSRange)
    case blockLatex(range: NSRange)
    /// `cells` covers every row except the alignment separator, header first.
    case table(range: NSRange, cells: [TableCell])
    case thematicBreak(range: NSRange)
    case blank(range: NSRange)

    var range: NSRange {
        switch self {
        case .paragraph(let r, _), .heading(_, let r, _, _), .blockquote(let r, _),
             .list(let r, _), .codeBlock(let r), .blockLatex(let r), .table(let r, _),
             .thematicBreak(let r), .blank(let r):
            return r
        }
    }
}

enum DocumentAST {

    private static let hash: unichar = 0x23
    private static let space: unichar = 0x20
    private static let tab: unichar = 0x09

    /// Build the document AST; `scopedRanges` parses inlines only for intersecting blocks.
    ///
    /// A whole-document parse (no scope, or a scope covering the text) is memoized
    /// for the last text: a single ⌘A press asks for it from the formatter, the
    /// styler and the tokenizer in turn, and the inline parse of a 500 KB note is
    /// ~80 ms each time. Identity is the UTF-16 buffer (memcmp), like BlockParser.
    /// A text that is not the document passes `memoizing: false`: it neither
    /// reads nor replaces the memo.
    static func parse(_ text: String, scopedRanges: [NSRange]? = nil) -> [BlockNode] {
        parse(text, scopedRanges: scopedRanges, memoizing: true)
    }

    static func parse(_ text: String, scopedRanges: [NSRange]? = nil, memoizing: Bool) -> [BlockNode] {
        let ns = text as NSString
        guard memoizing else {
            return BlockParser.parse(text, memoizing: false).map { node(for: $0, ns: ns, scopedRanges: scopedRanges) }
        }
        // A scope that covers (nearly) the whole text — a ⌘A edit's restyle — is
        // served as the memoized whole parse: skipping inlines for the few blocks
        // outside it would cost more than it saves.
        let whole = scopedRanges.map { scope in
            let covered = scope.reduce(0) { $0 + NSIntersectionRange($1, NSRange(location: 0, length: ns.length)).length }
            return covered * 10 >= ns.length * 9
        } ?? true
        var chars = [unichar](repeating: 0, count: ns.length)
        if ns.length > 0 { ns.getCharacters(&chars, range: NSRange(location: 0, length: ns.length)) }
        memoLock.lock()
        let hit = memoChars.map { $0.count == chars.count && ($0.isEmpty || $0.withUnsafeBytes { a in chars.withUnsafeBytes { b in memcmp(a.baseAddress!, b.baseAddress!, a.count) == 0 } }) } ?? false
        let cached = hit ? memoBlocks : nil
        memoLock.unlock()
        if let cached {
            // A scoped request on memoized text is the whole parse cut to scope:
            // the idle restyle passes after a ⌘A format ask for one chunk each.
            return whole ? cached : cached.filter { inScope($0.range, scopedRanges) }
        }
        let blocks = BlockParser.parse(text)
        // Scoped mode: skip building BlockNodes for blocks outside the edit. A
        // near-whole scope builds every block, since that result is memoized as
        // the whole parse.
        let relevant = whole ? blocks : blocks.filter { inScope($0.range, scopedRanges) }
        let nodes = relevant.map { node(for: $0, ns: ns, scopedRanges: whole ? nil : scopedRanges) }
        if whole {
            memoLock.lock()
            memoChars = chars
            memoBlocks = nodes
            memoLock.unlock()
        }
        return nodes
    }

    private static let memoLock = NSLock()
    nonisolated(unsafe) private static var memoChars: [unichar]?
    nonisolated(unsafe) private static var memoBlocks: [BlockNode]?
    /// The length of the text the memo holds (tests).
    static var memoizedLength: Int? { memoLock.withLock { memoChars?.count } }

    private static func inScope(_ range: NSRange, _ scopedRanges: [NSRange]?) -> Bool {
        guard let scopedRanges else { return true }
        return scopedRanges.contains { NSIntersectionRange($0, range).length > 0 }
    }

    /// Shared block semantics for whole-document and incremental tokenization.
    static func node(for block: Block, ns: NSString, scopedRanges: [NSRange]?) -> BlockNode {
        let scoped = inScope(block.range, scopedRanges)
        switch block.kind {
        case .paragraph:
            return .paragraph(range: block.range, inlines: scoped ? InlineParser.parse(ns, range: block.range) : [])
        case .heading:
            return heading(block.range, ns, scoped: scoped)
        case .blockquote:
            return .blockquote(range: block.range, inlines: scoped ? InlineParser.parse(ns, range: block.range) : [])
        case .list:
            return list(block.range, ns, scoped: scoped)
        case .fencedCode:
            return .codeBlock(range: block.range)
        case .blockLatex:
            return .blockLatex(range: block.range)
        case .table:
            return .table(range: block.range, cells: scoped ? tableCells(block.range, ns) : [])
        case .thematicBreak:
            return .thematicBreak(range: block.range)
        case .blank:
            return .blank(range: block.range)
        }
    }

    /// Every cell of a GFM table block, header first, separator row skipped. The
    /// cell splitting (pipes, `\|` escapes, padding) is `MarkdownTableScanner`'s;
    /// each cell's inline markup is parsed in place so the styler treats a cell
    /// like any other inline-bearing span.
    private static func tableCells(_ range: NSRange, _ ns: NSString) -> [TableCell] {
        var cells: [TableCell] = []
        var cursor = range.location
        let end = NSMaxRange(range)
        while cursor < end {
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            cursor = NSMaxRange(line)
            let text = ns.substring(with: line)
            guard MarkdownTableScanner.isTableRow(text), !MarkdownTableScanner.isTableSeparator(text) else { continue }
            for cell in MarkdownTableScanner.cellContentRanges(inLine: line, of: ns) {
                cells.append(TableCell(range: cell, inlines: InlineParser.parse(ns, range: cell)))
            }
        }
        return cells
    }

    /// ATX heading: optional indent, `#`×level, space(s), then inline content.
    private static func heading(_ range: NSRange, _ ns: NSString, scoped: Bool = true) -> BlockNode {
        let end = NSMaxRange(range)
        var i = range.location
        while i < end, ns.character(at: i) == space || ns.character(at: i) == tab { i += 1 }
        let hashStart = i
        var level = 0
        while i < end, ns.character(at: i) == hash { level += 1; i += 1 }

        var contentStart = i
        while contentStart < end, ns.character(at: contentStart) == space { contentStart += 1 }
        // Markers span `#`(s) plus trailing space(s) so the whole syntax collapses on shrink.
        let markers = [NSRange(location: hashStart, length: contentStart - hashStart)]
        var contentEnd = end
        while contentEnd > contentStart, isLineBreak(ns.character(at: contentEnd - 1)) { contentEnd -= 1 }
        let contentRange = NSRange(location: contentStart, length: contentEnd - contentStart)

        return .heading(level: level, range: range, markers: markers,
                        inlines: scoped ? InlineParser.parse(ns, range: contentRange) : [])
    }

    /// Split a list block into one `ListItem` per physical line.
    private static func list(_ range: NSRange, _ ns: NSString, scoped: Bool = true) -> BlockNode {
        var items: [ListItem] = []
        var cursor = range.location
        let end = NSMaxRange(range)
        while cursor < end {
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            items.append(listItem(line, ns, scoped: scoped))
            cursor = NSMaxRange(line)
        }
        return .list(range: range, items: items)
    }

    /// Parse one list-item line: indent, marker, optional task checkbox, inline content.
    private static func listItem(_ lineRange: NSRange, _ ns: NSString, scoped: Bool = true) -> ListItem {
        let end = NSMaxRange(lineRange)
        var i = lineRange.location
        var indent = 0
        while i < end, ns.character(at: i) == space || ns.character(at: i) == tab { i += 1; indent += 1 }
        let markerStart = i
        var ordered = false
        var number: Int?
        let c = i < end ? ns.character(at: i) : 0
        if c == 0x2D || c == 0x2A || c == 0x2B {        // - * +
            i += 1
        } else {                                        // N. / N)
            var value = 0
            var digits = 0
            while i < end, ns.character(at: i) >= 0x30, ns.character(at: i) <= 0x39, digits < 9 {
                value = value * 10 + Int(ns.character(at: i) - 0x30); i += 1; digits += 1
            }
            ordered = true
            number = value
            if i < end { i += 1 }                       // the `.` or `)`
        }
        let marker = NSRange(location: markerStart, length: i - markerStart)
        if i < end, ns.character(at: i) == space || ns.character(at: i) == tab { i += 1 }
        var checkbox: NSRange?
        var checked = false
        if i + 2 < end, ns.character(at: i) == 0x5B, ns.character(at: i + 2) == 0x5D {   // [ x ]
            let mid = ns.character(at: i + 1)
            if mid == space || mid == 0x78 || mid == 0x58 {     // space / x / X
                checkbox = NSRange(location: i, length: 3)
                checked = (mid == 0x78 || mid == 0x58)
                i += 3
                if i < end, ns.character(at: i) == space || ns.character(at: i) == tab { i += 1 }
            }
        }
        var contentEnd = end
        while contentEnd > i, isLineBreak(ns.character(at: contentEnd - 1)) { contentEnd -= 1 }
        let content = NSRange(location: i, length: max(0, contentEnd - i))
        return ListItem(range: lineRange, marker: marker, ordered: ordered, number: number,
                        checkbox: checkbox, checked: checked, indent: indent,
                        contentRange: content, inlines: scoped ? InlineParser.parse(ns, range: content) : [])
    }

    private static func isLineBreak(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D }
}
