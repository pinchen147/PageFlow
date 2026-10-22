//
//  MarkdownFormatState.swift
//  MarkdownEngine
//
//  What the selection bar, the Format menu and the window toolbar show as
//  pressed, computed from the source and its parsed tokens (doc 24 §6.4,
//  §7.8.2). States are binary, as in the reference editor: a mark is on only when the
//  whole selection carries it.
//

import Foundation
import CoreGraphics

/// The formatting at the editor's selection.
public struct MarkdownFormatState: Equatable, Sendable {
    public enum Context: Equatable, Sendable {
        case none
        case text
        case cellText
        case cellRange(cells: Int)
        case codeBlock
        case image(alignment: ImageAltTokens.Alignment, hasCrop: Bool, width: CGFloat?)
    }

    /// The Text style trigger's label: "Aa" for text, "H1"…"H6" for a heading.
    public enum TextStyle: Equatable, Sendable {
        case text
        case heading(Int)
    }

    public enum ListKind: Equatable, Sendable {
        case bulleted
        case numbered
        case checklist
    }

    public var context: Context = .none
    /// The keyboard is in a table cell (a caret, text or a range of cells):
    /// lists, headings and other block commands can't apply there.
    public var inTableCell = false
    public var isEditable = true
    public var bold = false
    public var italic = false
    public var underline = false
    public var strikethrough = false
    public var code = false
    public var highlight = false
    public var link = false
    /// nil: the selection crosses a list, quote, table or code boundary ("Aa", no ✓).
    public var textStyle: TextStyle? = .text
    /// The List trigger: the kind of the line holding the selection start, else
    /// the one kind every touched list shares.
    public var listPressed: ListKind?
    /// The List menu's ✓: only the one kind every touched list shares.
    public var listChecked: ListKind?
    /// Any selected line is a list item (Indent and Outdent rows).
    public var showsIndentRows = false
    /// False for a range of more than one cell.
    public var linkEnabled = true

    public init() {}
}

/// Computes a `MarkdownFormatState` without parsing: it reads the source and
/// the editor's cached, location-sorted tokens, visiting only the tokens in
/// the selection's lines.
enum MarkdownFormatStateCalculator {

    /// Inline kinds whose `range − contentRange` is syntax, not text.
    private static let delimited: Set<MarkdownTokenKind> = [
        .bold, .italic, .boldItalic, .underline, .strikethrough, .highlight, .inlineCode, .link, .wikiLink, .backslashEscape,
    ]

    /// `tokens` are the parse's location-sorted tokens; `codeTokens` its code
    /// blocks and spans, also sorted.
    static func state(text: NSString, tokens: [MarkdownToken], codeTokens: [MarkdownToken], selection: NSRange,
                      isEditable: Bool) -> MarkdownFormatState {
        var state = MarkdownFormatState()
        state.isEditable = isEditable
        let length = text.length
        let selection = NSRange(location: min(max(0, selection.location), length),
                                length: max(0, min(selection.length, length - min(max(0, selection.location), length))))
        let lines = touchedLines(text, selection)
        let window = NSRange(location: lines.first?.location ?? selection.location,
                             length: (lines.last.map(NSMaxRange) ?? NSMaxRange(selection)) - (lines.first?.location ?? selection.location))
        let nearby = tokensIntersecting(window, in: tokens)

        if let block = lastToken(startingAtOrBefore: selection.location, in: codeTokens, kind: .codeBlock),
           NSLocationInRange(selection.location, block.range) {
            state.context = .codeBlock
            state.textStyle = nil
            return state
        }
        state.context = selection.length > 0 ? .text : .none
        readLines(lines, in: text, into: &state)

        if selection.length == 0 {
            func inside(_ kinds: Set<MarkdownTokenKind>) -> Bool {
                nearby.contains { kinds.contains($0.kind) && $0.contentRange.location < selection.location
                    && selection.location <= NSMaxRange($0.contentRange) }
            }
            state.bold = inside([.bold, .boldItalic])
            state.italic = inside([.italic, .boldItalic])
            state.underline = inside([.underline])
            state.strikethrough = inside([.strikethrough])
            state.code = inside([.inlineCode])
            state.highlight = inside([.highlight])
            state.link = inside([.link, .wikiLink])
            return state
        }

        let required = requiredText(lines: lines, selection: selection, text: text, tokens: nearby)
        guard !required.isEmpty else { return state }
        func covers(_ kinds: Set<MarkdownTokenKind>) -> Bool {
            let spans = nearby.filter { kinds.contains($0.kind) }.map(\.contentRange)
            return required.allSatisfy { piece in Self.isCovered(piece, by: spans) }
        }
        state.bold = covers([.bold, .boldItalic])
        state.italic = covers([.italic, .boldItalic])
        state.underline = covers([.underline])
        state.strikethrough = covers([.strikethrough])
        state.code = covers([.inlineCode])
        state.highlight = covers([.highlight])
        state.link = covers([.link, .wikiLink])
        return state
    }

    // MARK: - Lines

    /// The lines the selection touches. A selection ending at a line's start
    /// does not touch that line.
    static func touchedLines(_ text: NSString, _ selection: NSRange) -> [NSRange] {
        guard text.length > 0 else { return [NSRange(location: 0, length: 0)] }
        var end = NSMaxRange(selection)
        if selection.length > 0, end > selection.location, end <= text.length,
           text.character(at: end - 1) == 0x0A { end -= 1 }
        var lines: [NSRange] = []
        var cursor = min(selection.location, text.length)
        repeat {
            let line = text.lineRange(for: NSRange(location: min(cursor, text.length), length: 0))
            lines.append(line)
            cursor = NSMaxRange(line)
        } while cursor <= end && cursor < text.length && lines.count < 1_000_000
        return lines
    }

    enum LineKind: Equatable {
        case text
        case heading(Int)
        case list(MarkdownFormatState.ListKind, markerEnd: Int)
        case quote(markerEnd: Int)
        case tableRow
        case blank
    }

    /// What a source line is, from its first characters.
    static func kind(ofLine line: NSRange, in text: NSString) -> LineKind {
        let end = NSMaxRange(line)
        var i = line.location
        var spaces = 0
        while i < end, text.character(at: i) == 0x20 || text.character(at: i) == 0x09 { i += 1; spaces += 1 }
        guard i < end, ![0x0A, 0x0D].contains(text.character(at: i)) else { return .blank }
        let first = text.character(at: i)
        func isSpace(_ index: Int) -> Bool { index < end && (text.character(at: index) == 0x20 || text.character(at: index) == 0x09) }
        func lineEnded(_ index: Int) -> Bool { index >= end || [0x0A, 0x0D].contains(text.character(at: index)) }
        if first == 0x7C { return .tableRow }
        if first == 0x3E { // >
            var j = i + 1
            while isSpace(j) { j += 1 }
            return .quote(markerEnd: j)
        }
        if first == 0x23, spaces <= 3 { // #
            var j = i
            while j < end, text.character(at: j) == 0x23 { j += 1 }
            let level = j - i
            if level <= 6, isSpace(j) || lineEnded(j) { return .heading(level) }
        }
        if [0x2D, 0x2A, 0x2B].contains(first), isSpace(i + 1) { // - * +
            var j = i + 1
            while isSpace(j) { j += 1 }
            if j + 2 < end, text.character(at: j) == 0x5B, [0x20, 0x78, 0x58].contains(text.character(at: j + 1)),
               text.character(at: j + 2) == 0x5D, isSpace(j + 3) || lineEnded(j + 3) {
                var k = j + 3
                while isSpace(k) { k += 1 }
                return .list(.checklist, markerEnd: k)
            }
            return .list(.bulleted, markerEnd: j)
        }
        if (0x30...0x39).contains(first) {
            var j = i
            while j < end, (0x30...0x39).contains(text.character(at: j)), j - i < 9 { j += 1 }
            if j < end, [0x2E, 0x29].contains(text.character(at: j)), isSpace(j + 1) {
                var k = j + 1
                while isSpace(k) { k += 1 }
                return .list(.numbered, markerEnd: k)
            }
        }
        return .text
    }

    /// Text style and list states from the touched lines (the reference editor's rules, doc 24 §6.4).
    private static func readLines(_ lines: [NSRange], in text: NSString, into state: inout MarkdownFormatState) {
        var kinds = lines.map { kind(ofLine: $0, in: text) }
        if kinds.count > 1 { kinds.removeAll { $0 == .blank } }
        var crossesBoundary = false
        var lastStyle: MarkdownFormatState.TextStyle = .text
        var listKinds: [MarkdownFormatState.ListKind] = []
        for kind in kinds {
            switch kind {
            case .heading(let level): lastStyle = .heading(level)
            case .text, .blank: lastStyle = .text
            case .list(let list, _):
                crossesBoundary = true
                listKinds.append(list)
            case .quote, .tableRow: crossesBoundary = true
            }
        }
        state.textStyle = crossesBoundary ? nil : lastStyle
        let shared = listKinds.first.flatMap { first in listKinds.allSatisfy { $0 == first } ? first : nil }
        if case .list(let first, _) = kinds.first { state.listPressed = first } else { state.listPressed = shared }
        state.listChecked = shared
        state.showsIndentRows = !listKinds.isEmpty
    }

    // MARK: - Marks

    /// The visible characters a mark must cover: each line's part of the
    /// selection, trimmed of edge whitespace, minus line markers and inline
    /// delimiters (hidden or not).
    private static func requiredText(lines: [NSRange], selection: NSRange, text: NSString, tokens: [MarkdownToken]) -> [NSRange] {
        var syntax: [NSRange] = []
        for token in tokens where delimited.contains(token.kind) {
            let content = token.contentRange
            if content.location > token.range.location {
                syntax.append(NSRange(location: token.range.location, length: content.location - token.range.location))
            }
            if NSMaxRange(token.range) > NSMaxRange(content) {
                syntax.append(NSRange(location: NSMaxRange(content), length: NSMaxRange(token.range) - NSMaxRange(content)))
            }
        }
        for token in tokens where token.kind == .heading || token.kind == .blockquote {
            syntax.append(contentsOf: token.markerRanges)
        }
        var pieces: [NSRange] = []
        for line in lines {
            var start = max(line.location, selection.location)
            switch kind(ofLine: line, in: text) {
            case .list(_, let markerEnd), .quote(let markerEnd): start = max(start, markerEnd)
            default: break
            }
            var end = min(NSMaxRange(line), NSMaxRange(selection))
            while end > start, isWhitespace(text.character(at: end - 1)) { end -= 1 }
            while start < end, isWhitespace(text.character(at: start)) { start += 1 }
            guard start < end else { continue }
            pieces.append(contentsOf: subtract(syntax, from: NSRange(location: start, length: end - start)))
        }
        return pieces
    }

    private static func isWhitespace(_ unit: unichar) -> Bool { unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D }

    /// `range` minus every range in `holes`.
    private static func subtract(_ holes: [NSRange], from range: NSRange) -> [NSRange] {
        var pieces = [range]
        for hole in holes where NSIntersectionRange(hole, range).length > 0 {
            pieces = pieces.flatMap { piece -> [NSRange] in
                let cut = NSIntersectionRange(piece, hole)
                guard cut.length > 0 else { return [piece] }
                var rest: [NSRange] = []
                if cut.location > piece.location { rest.append(NSRange(location: piece.location, length: cut.location - piece.location)) }
                if NSMaxRange(piece) > NSMaxRange(cut) { rest.append(NSRange(location: NSMaxRange(cut), length: NSMaxRange(piece) - NSMaxRange(cut))) }
                return rest
            }
        }
        return pieces
    }

    /// Whether the union of `spans` contains all of `piece`.
    private static func isCovered(_ piece: NSRange, by spans: [NSRange]) -> Bool {
        var cursor = piece.location
        let end = NSMaxRange(piece)
        let ordered = spans.filter { NSMaxRange($0) > piece.location && $0.location < end }.sorted { $0.location < $1.location }
        for span in ordered {
            if span.location > cursor { return false }
            cursor = max(cursor, NSMaxRange(span))
            if cursor >= end { return true }
        }
        return cursor >= end
    }

    // MARK: - Tokens

    /// The tokens that intersect `window`. Tokens are sorted by location, so a
    /// binary search finds the first that could; block tokens (code blocks,
    /// tables) that start earlier are found by a short backward walk.
    static func tokensIntersecting(_ window: NSRange, in tokens: [MarkdownToken]) -> [MarkdownToken] {
        guard !tokens.isEmpty else { return [] }
        var low = 0, high = tokens.count
        while low < high {
            let mid = (low + high) / 2
            if tokens[mid].range.location < window.location { low = mid + 1 } else { high = mid }
        }
        var found: [MarkdownToken] = []
        // Emphasis can run across a paragraph's soft line breaks: a short
        // backward walk finds spans that began before the window.
        var back = low - 1
        var steps = 0
        while back >= 0, steps < 64 {
            let token = tokens[back]
            if NSMaxRange(token.range) > window.location || (window.length == 0 && NSMaxRange(token.range) >= window.location) {
                found.append(token)
            }
            back -= 1
            steps += 1
        }
        var index = low
        let end = NSMaxRange(window)
        while index < tokens.count, tokens[index].range.location <= end {
            found.append(tokens[index])
            index += 1
        }
        return found
    }

    /// The last token of `kind` that starts at or before `location` (binary search).
    static func lastToken(startingAtOrBefore location: Int, in tokens: [MarkdownToken], kind: MarkdownTokenKind) -> MarkdownToken? {
        var low = 0, high = tokens.count
        while low < high {
            let mid = (low + high) / 2
            if tokens[mid].range.location <= location { low = mid + 1 } else { high = mid }
        }
        var index = low - 1
        while index >= 0, low - index <= 64 {
            if tokens[index].kind == kind { return tokens[index] }
            index -= 1
        }
        return nil
    }
}
