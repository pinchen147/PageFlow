//
//  BlockScopedTokenizer.swift
//  MarkdownEngine
//
//  The live tokenization pipeline. For each block from `BlockParser`:
//  block-level tokens (heading, blockquote, table, block LaTeX, code) come from
//  `BlockLevelTokenizer` (hand scanners, no regex), while ALL inline tokens come
//  from the AST (`InlineParser` → `InlineASTAdapter`). Results are offset back
//  into document coordinates. Fenced-code blocks emit only their code-block
//  token (no inline markup inside).
//

import Foundation

extension MarkdownTokenizer {

    private struct BlockTokenKey: Hashable {
        let kind: BlockKind
        let source: [UInt16]
    }

    /// Ranges address literal UTF-16 source; canonical-equivalent Strings cannot share entries.
    private static let blockTokenLock = NSLock()
    private static var blockTokenCache: [BlockTokenKey: [MarkdownToken]] = [:]
    private static var blockTokenOrder: [BlockTokenKey] = []
    private static let blockTokenCacheCap = 4096

    // Document-level token memo: re-tokenize only the touched blocks; the rest shift by the delta.
    private static let tokensLock = NSLock()
    private static var cachedTokenChars: [unichar]?
    private static var cachedTokens: [MarkdownToken]?
    /// The length of the text the document memo holds (tests).
    static var memoizedDocumentLength: Int? { tokensLock.withLock { cachedTokenChars?.count } }

    /// The live tokenizer: block-level tokens + inline AST tokens; fenced code emits only its code-block token.
    /// A text that is not the document (a cell, one block) passes `memoizing: false`:
    /// the parse layers keep one memo each, and a fragment would replace the
    /// document's, sending its next parse down the full path.
    static func parseTokensViaAST(in text: String) -> [MarkdownToken] { parseTokensViaAST(in: text, memoizing: true) }

    static func parseTokensViaAST(in text: String, memoizing: Bool) -> [MarkdownToken] {
        guard memoizing else {
            let ns = text as NSString
            return fullTokens(blocks: BlockParser.parse(text, memoizing: false), ns: ns, memoizing: false)
        }
        let ns = text as NSString
        let newLen = ns.length
        var newChars = [unichar](repeating: 0, count: newLen)
        if newLen > 0 { ns.getCharacters(&newChars, range: NSRange(location: 0, length: newLen)) }

        var blocks: [Block] = []
        PerfTrace.time("tok.blockParse") { blocks = BlockParser.parse(text) }

        tokensLock.lock()
        let prevChars = cachedTokenChars
        let prevTokens = cachedTokens
        tokensLock.unlock()

        var result: [MarkdownToken] = []
        var incr: [MarkdownToken]?
        PerfTrace.time("tok.incremental") {
            if let prevChars, let prevTokens,
               let (i, _) = incrementalTokens(oldChars: prevChars, prevTokens: prevTokens, newChars: newChars, blocks: blocks, ns: ns) { incr = i }
        }
        if let incr {
            result = incr
        } else {
            PerfTrace.time("tok.full") { result = fullTokens(blocks: blocks, ns: ns) }
        }

        tokensLock.lock(); cachedTokenChars = newChars; cachedTokens = result; tokensLock.unlock()
        return result
    }

    /// Every block re-tokenized (a whole-document change, or the first parse).
    /// Block-level tokens come from the block substrings as always; the inline
    /// tokens come from the document AST, which is memoized for this text and
    /// needed by the styler in the same turn — so the inline parse of the note
    /// happens once per change, not once here and again for the styler.
    private static func fullTokens(blocks: [Block], ns: NSString, memoizing: Bool = true) -> [MarkdownToken] {
        let nodes = DocumentAST.parse(ns as String, memoizing: memoizing)
        var result: [MarkdownToken] = []
        for (i, block) in blocks.enumerated() {
            let delta = block.range.location
            let sub = ns.substring(with: block.range)
            let blockLevel = BlockLevelTokenizer.tokens(for: block.kind, in: sub as NSString)
            result.append(contentsOf: blockLevel.map { $0.shifted(by: delta) })
            if i < nodes.count, block.kind != .fencedCode {
                result.append(contentsOf: InlineASTAdapter.tokens(from: inlineNodes(of: nodes[i])))
            }
        }
        return result
    }

    /// The inline nodes of a block node, in document order.
    private static func inlineNodes(of node: BlockNode) -> [InlineNode] {
        switch node {
        case .paragraph(_, let inlines), .heading(_, _, _, let inlines), .blockquote(_, let inlines):
            return inlines
        case .list(_, let items):
            return items.flatMap(\.inlines)
        case .table(_, let cells):
            return cells.flatMap(\.inlines)
        case .codeBlock, .blockLatex, .thematicBreak, .blank:
            return []
        }
    }

    /// Reuse prefix/suffix tokens (suffix shifted) and re-tokenize only touched blocks; nil to fall back to full.
    private static func incrementalTokens(oldChars o: [unichar], prevTokens: [MarkdownToken], newChars n: [unichar], blocks: [Block], ns: NSString) -> (tokens: [MarkdownToken], retok: Int)? {
        let oldLen = o.count, newLen = n.count
        guard oldLen > 0, newLen > 0, !blocks.isEmpty else { return nil }

        var p = 0
        let maxPre = min(oldLen, newLen)
        while p < maxPre, o[p] == n[p] { p += 1 }
        var s = 0
        let maxSuf = maxPre - p
        while s < maxSuf, o[oldLen - 1 - s] == n[newLen - 1 - s] { s += 1 }
        let delta = newLen - oldLen
        let changeStart = p, changeEndNew = newLen - s
        if (changeEndNew - changeStart) * 2 > newLen { return nil }   // most of the text changed: full pass

        // A fence/block-LaTeX delimiter can pair with a distant partner and ripple far → full tokenization.
        if BlockParser.hasBlockDelimiter(o, changeStart, oldLen - s)
            || BlockParser.hasBlockDelimiter(n, changeStart, changeEndNew) { return nil }

        // New blocks touching the changed char range [changeStart, changeEndNew].
        var lo = blocks.count, hi = -1
        for (i, b) in blocks.enumerated()
        where b.range.location <= changeEndNew && NSMaxRange(b.range) >= changeStart {
            lo = min(lo, i); hi = max(hi, i)
        }
        if hi < 0 { return delta == 0 ? (prevTokens, 0) : nil }

        // Widen the window until no previous token straddles either cut (a block's extent can change in place).
        var expanded = true
        while expanded {
            expanded = false
            for t in prevTokens {
                let cutStart = blocks[lo].range.location
                if t.range.location < cutStart, NSMaxRange(t.range) > cutStart {
                    while lo > 0, blocks[lo].range.location > t.range.location { lo -= 1; expanded = true }
                }
                let cutEndOld = NSMaxRange(blocks[hi].range) - delta
                if t.range.location < cutEndOld, NSMaxRange(t.range) > cutEndOld {
                    while hi < blocks.count - 1, NSMaxRange(blocks[hi].range) - delta < NSMaxRange(t.range) { hi += 1; expanded = true }
                }
            }
        }

        let regionStart = blocks[lo].range.location
        let regionEndOld = NSMaxRange(blocks[hi].range) - delta

        var result: [MarkdownToken] = []
        for t in prevTokens where NSMaxRange(t.range) <= regionStart { result.append(t) }   // prefix, unchanged
        for i in lo...hi {                                                                   // changed window, retokenized
            let off = blocks[i].range.location
            let rel = cachedBlockTokens(kind: blocks[i].kind, sub: ns.substring(with: blocks[i].range))
            result.append(contentsOf: rel.map { $0.shifted(by: off) })
        }
        for t in prevTokens where t.range.location >= regionEndOld { result.append(t.shifted(by: delta)) }  // suffix, shifted
        return (result, hi - lo + 1)
    }

    /// Cached block-relative tokens for `sub` (computed on miss); a pure memo over the token logic.
    private static func cachedBlockTokens(kind: BlockKind, sub: String) -> [MarkdownToken] {
        let key = BlockTokenKey(kind: kind, source: Array(sub.utf16))
        blockTokenLock.lock()
        if let cached = blockTokenCache[key] {
            blockTokenLock.unlock()
            return cached
        }
        blockTokenLock.unlock()

        let blockLevel = BlockLevelTokenizer.tokens(for: kind, in: sub as NSString)
        // Use the same cell, list-content and opaque-block boundaries as a full parse.
        let ns = sub as NSString
        let block = Block(kind: kind, range: NSRange(location: 0, length: ns.length))
        let node = DocumentAST.node(for: block, ns: ns, scopedRanges: nil)
        let inline = InlineASTAdapter.tokens(from: inlineNodes(of: node))
        let computed = blockLevel + inline

        blockTokenLock.lock()
        if blockTokenCache[key] == nil {
            blockTokenCache[key] = computed
            blockTokenOrder.append(key)
            if blockTokenOrder.count > blockTokenCacheCap {
                // Drop the oldest half at once: a per-insert removeFirst shifted
                // the whole order array on every miss of a whole-document change.
                let dropped = blockTokenCacheCap / 2
                for key in blockTokenOrder.prefix(dropped) { blockTokenCache[key] = nil }
                blockTokenOrder.removeFirst(dropped)
            }
        }
        blockTokenLock.unlock()
        return computed
    }
}

private extension MarkdownToken {
    /// Returns a copy with every range moved forward by `delta` UTF-16 units.
    func shifted(by delta: Int) -> MarkdownToken {
        func move(_ r: NSRange) -> NSRange {
            NSRange(location: r.location + delta, length: r.length)
        }
        return MarkdownToken(
            kind: kind,
            range: move(range),
            contentRange: move(contentRange),
            markerRanges: markerRanges.map(move)
        )
    }
}
