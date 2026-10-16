//
//  MarkdownDetection.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Helper checks for questions like "is the cursor inside code or LaTeX?"
// and "which Markdown part is currently active?".
import Foundation

enum MarkdownDetection {

    // MARK: - Active Token Indices

    /// A table stays active for a selection inside it so a table shown through
    /// Edit Table Source keeps its source; the styler shows no other table.
    static let revealsForRangedSelection: Set<MarkdownTokenKind> = [.inlineLatex, .blockLatex, .imageEmbed, .imageLink, .codeBlock, .table]

    static func computeActiveTokenIndices(
        selectionRange: NSRange,
        tokens: [MarkdownToken],
        in text: NSString,
        suppressed: Bool = false
    ) -> Set<Int> {
        // Read-only mode (no caret) hides all tokens regardless of any trailing selection.
        if suppressed { return [] }
        var indices: Set<Int> = []
        // A selection that merely OVERLAPS a rendered element — ⌘A (anchor at
        // offset 0), a drag whose low endpoint lands inside a formula — must not
        // un-render it (2026-07-04 field report; the "jumpiness" Obsidian users
        // complain about). A selection that lies ENTIRELY inside an element is
        // the opposite case: the user is working within its revealed source
        // (selecting a word in a table cell to bold it), and collapsing the
        // element would hide the very text being selected.
        //
        // the reference editor never shows Markdown for a selection (doc 24 §6.11): a
        // ranged selection reveals only rendered replacements whose source is
        // the thing being selected — math, images and code blocks (deviation a).
        guard selectionRange.length == 0 else {
            for (index, token) in tokens.enumerated()
            where Self.revealsForRangedSelection.contains(token.kind)
                && NSIntersectionRange(selectionRange, token.range) == selectionRange {
                indices.insert(index)
            }
            return propagateActiveContainers(indices, tokens: tokens)
        }
        let caretLocation = selectionRange.location
        for (index, token) in tokens.enumerated() {
            let start = token.range.location
            let end = NSMaxRange(token.range)
            if caretLocation >= start && caretLocation < end {
                indices.insert(index)
                continue
            }
            if caretLocation == end {
                let lastIndex = end - 1
                if lastIndex >= start && lastIndex < text.length {
                    let lastChar = text.substring(with: NSRange(location: lastIndex, length: 1))
                    if lastChar != "\n" {
                        indices.insert(index)
                    }
                }
            }
        }

        return propagateActiveContainers(indices, tokens: tokens)
    }

    /// When a container token (a table) is active, every inline token inside it is active too.
    private static func propagateActiveContainers(_ indices: Set<Int>, tokens: [MarkdownToken]) -> Set<Int> {
        var result = indices
        let containers = indices.map { tokens[$0] }.filter { $0.kind == .table }
        guard !containers.isEmpty else { return result }
        for (i, token) in tokens.enumerated() where !result.contains(i) {
            if containers.contains(where: { NSIntersectionRange(token.range, $0.range) == token.range }) {
                result.insert(i)
            }
        }
        return result
    }

    // MARK: - Code Block Detection

    /// Slow: parses tokens each call
    static func isInsideCodeBlock(range: NSRange, in text: String) -> Bool {
        let codeTokens = MarkdownTokenizer.parseTokensViaAST(in: text).filter { $0.kind == .codeBlock || $0.kind == .inlineCode }
        return isInsideCodeBlock(range: range, codeTokens: codeTokens)
    }

    static func isInsideCodeBlock(location: Int, in text: String) -> Bool {
        isInsideCodeBlock(range: NSRange(location: location, length: 0), in: text)
    }

    /// Fast: uses pre-parsed tokens
    static func isInsideCodeBlock(range: NSRange, codeTokens: [MarkdownToken]) -> Bool {
        guard !codeTokens.isEmpty else { return false }
        for token in codeTokens {
            let start = token.range.location
            let end = start + token.range.length
            if range.length == 0 {
                let unfinishedFence = token.kind == .codeBlock && token.markerRanges.count == 1
                if range.location >= start,
                   range.location < end || (range.location == end && unfinishedFence) { return true }
            } else {
                if range.location < end && range.location + range.length > start { return true }
            }
        }
        return false
    }

    static func isInsideCodeBlock(location: Int, codeTokens: [MarkdownToken]) -> Bool {
        isInsideCodeBlock(range: NSRange(location: location, length: 0), codeTokens: codeTokens)
    }

    // MARK: - LaTeX Detection

    static func isInsideLatex(location: Int, in text: String) -> Bool {
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let latexTokens = tokens.filter { $0.kind == .inlineLatex || $0.kind == .blockLatex }
        return isInsideLatex(location: location, latexTokens: latexTokens)
    }

    static func isInsideLatex(location: Int, latexTokens: [MarkdownToken]) -> Bool {
        guard !latexTokens.isEmpty else { return false }
        for token in latexTokens {
            let start = token.range.location
            let end = start + token.range.length
            if location >= start && location <= end { return true }
        }
        return false
    }

}
