//
//  MarkdownSourceFormatting+Alignment.swift
//  MarkdownEngine
//
//  Paragraph alignment, clearing inline formatting, and moving lines. The
//  alignment is stored portably: the block wrapped as
//
//      <div align="center">
//
//      text, with **Markdown** still working
//
//      </div>
//
//  which GitHub, Obsidian's reading view and HTML exporters honour. The
//  blank lines keep the inner Markdown parsed. Left alignment is the absence
//  of a wrapper.
//

import Foundation

/// A paragraph alignment (``MarkdownFormat/align(_:)``).
public enum MarkdownTextAlignment: String, CaseIterable, Sendable {
    case left, center, right, justify
}

extension MarkdownSourceFormatting {
    private static let openTag = try! NSRegularExpression(
        pattern: #"^[ \t]*<div align="(left|center|right|justify)">[ \t]*$"#, options: [.caseInsensitive])
    private static let closeTag = try! NSRegularExpression(pattern: #"^[ \t]*</div>[ \t]*$"#, options: [.caseInsensitive])

    /// The alignment an opening wrapper line sets, if `line` is one.
    static func alignmentTag(in line: String) -> MarkdownTextAlignment? {
        let range = NSRange(location: 0, length: (line as NSString).length)
        guard let match = openTag.firstMatch(in: line, range: range) else { return nil }
        return MarkdownTextAlignment(rawValue: (line as NSString).substring(with: match.range(at: 1)).lowercased())
    }

    static func isClosingTag(_ line: String) -> Bool {
        closeTag.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    /// Aligns the block(s) the selection touches: wraps them, changes the
    /// wrapper they are in, or (for left) removes it. Code, front matter, and
    /// selections that cross a wrapper's edge are left alone.
    static func setAlignment(_ alignment: MarkdownTextAlignment, in text: NSString, selection: NSRange) -> MarkdownSourceEdit? {
        func line(at location: Int) -> NSRange { text.lineRange(for: NSRange(location: location, length: 0)) }
        func content(_ range: NSRange) -> String { text.substring(with: range).trimmingCharacters(in: .newlines) }
        func isBlank(_ range: NSRange) -> Bool { content(range).trimmingCharacters(in: .whitespaces).isEmpty }
        func isTag(_ range: NSRange) -> Bool { alignmentTag(in: content(range)) != nil || isClosingTag(content(range)) }
        let lastLocation = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
        let touched = NSUnionRange(line(at: selection.location), line(at: max(selection.location, lastLocation)))

        if MarkdownAlignmentStyling.fencedRanges(in: text).contains(where: { NSIntersectionRange($0, touched).length > 0 }) {
            return nil
        }
        if let frontMatterEnd = frontMatterEnd(in: text), touched.location < frontMatterEnd { return nil }

        // Inside (or on the tags of) an existing wrapper: change or remove it.
        let regions = MarkdownAlignmentStyling.regions(in: text)
        if let region = regions.first(where: { NSLocationInRange(touched.location, $0.span) }) {
            guard NSMaxRange(touched) <= NSMaxRange(region.span) else { return nil }
            if alignment == .left {
                var kept = text.substring(with: region.body)
                let closeBreak = text.substring(with: region.close).hasSuffix("\n") ? "\n" : ""
                if !kept.hasSuffix("\n") { kept += closeBreak }
                let removedBefore = region.body.location - region.open.location
                let caret = max(region.open.location, selection.location - removedBefore)
                return MarkdownSourceEdit(range: region.span, replacement: kept,
                                          selection: NSRange(location: min(caret, region.open.location + (kept as NSString).length),
                                                             length: 0))
            }
            let tag = "<div align=\"\(alignment.rawValue)\">"
            let openLength = (content(region.open) as NSString).length
            let shift = (tag as NSString).length - openLength
            return MarkdownSourceEdit(
                range: NSRange(location: region.open.location, length: openLength), replacement: tag,
                selection: NSRange(location: max(region.open.location, selection.location + shift), length: selection.length))
        }
        // A selection that reaches into a wrapper from outside is ambiguous.
        if regions.contains(where: { NSIntersectionRange($0.span, touched).length > 0 }) { return nil }

        var start = touched.location
        var end = NSMaxRange(touched)
        guard !isBlank(touched) else { return nil }
        while start > 0, case let previous = line(at: start - 1), !isBlank(previous), !isTag(previous) { start = previous.location }
        while end < text.length, case let next = line(at: end), !isBlank(next), !isTag(next) { end = NSMaxRange(next) }
        guard alignment != .left else { return nil }

        let block = text.substring(with: NSRange(location: start, length: end - start))
        let body = block.trimmingCharacters(in: .newlines)
        let trailingBreak = block.hasSuffix("\n") ? "\n" : ""
        // Blank lines around the wrapper so it never merges with neighbours.
        let needsBlankBefore = start > 0 && !isBlank(line(at: start - 1))
        let needsBlankAfter = end < text.length && !isBlank(line(at: end))
        let prefix = (needsBlankBefore ? "\n" : "") + "<div align=\"\(alignment.rawValue)\">\n\n"
        let suffix = "\n\n</div>" + trailingBreak + (needsBlankAfter ? "\n" : "")
        return MarkdownSourceEdit(
            range: NSRange(location: start, length: end - start),
            replacement: prefix + body + suffix,
            selection: NSRange(location: selection.location + (prefix as NSString).length, length: selection.length))
    }

    /// The end of a leading `---` front-matter block, if the note has one.
    private static func frontMatterEnd(in text: NSString) -> Int? {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return nil }
        let close = text.range(of: "\n---", options: [], range: NSRange(location: 3, length: text.length - 3))
        return close.location == NSNotFound ? nil : NSMaxRange(close)
    }

    /// Removes bold, italic, underline, strikethrough and highlight pairs from
    /// the selection (the caret's line when nothing is selected). Code spans,
    /// fenced code, dividers and list, quote and heading prefixes are kept.
    static func clearInlineFormatting(in text: NSString, selection: NSRange) -> MarkdownSourceEdit? {
        var target = selection
        if target.length == 0 {
            var start = 0, contentsEnd = 0
            text.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: selection.location, length: 0))
            target = NSRange(location: start, length: contentsEnd - start)
        }
        guard target.length > 0 else { return nil }
        let fences = MarkdownAlignmentStyling.fencedRanges(in: text)
        var lineStart = target.location
        var pieces: [String] = []
        while lineStart < NSMaxRange(target) {
            let full = text.lineRange(for: NSRange(location: lineStart, length: 0))
            let piece = NSIntersectionRange(full, target)
            let raw = text.substring(with: piece)
            let inCode = fences.contains { NSLocationInRange(piece.location, $0) }
            pieces.append(inCode || isDivider(raw) ? raw : cleanedLine(raw))
            lineStart = NSMaxRange(full)
        }
        let replacement = pieces.joined()
        guard replacement != text.substring(with: target) else { return nil }
        let length = (replacement as NSString).length
        return MarkdownSourceEdit(range: target, replacement: replacement,
                                  selection: selection.length > 0 ? NSRange(location: target.location, length: length)
                                      : NSRange(location: min(selection.location, target.location + length), length: 0))
    }

    private static let linePrefix = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:>[ \t]*)*(?:#{1,6}[ \t]+|(?:[*+-]|\d+[.)])[ \t]+(?:\[[ xX]\][ \t]+)?)?"#)
    private static let codeSpan = try! NSRegularExpression(pattern: #"`[^`\n]*`"#)
    /// Paired marks only, so a lone `*` (as in `a * b`) survives.
    private static let markPairs: [(NSRegularExpression, String)] = [
        (#"\*\*(?=\S)(.+?)(?<=\S)\*\*"#, "$1"), (#"__(?=\S)(.+?)(?<=\S)__"#, "$1"),
        (#"~~(?=\S)(.+?)(?<=\S)~~"#, "$1"), (#"==(?=\S)(.+?)(?<=\S)=="#, "$1"),
        (#"<u>(.*?)</u>"#, "$1"),
        (#"(?<![*\w])\*(?=\S)(.+?)(?<=\S)\*(?![*\w])"#, "$1"), (#"(?<![_\w])_(?=\S)(.+?)(?<=\S)_(?![_\w])"#, "$1"),
    ].map { (try! NSRegularExpression(pattern: $0.0, options: [.caseInsensitive]), $0.1) }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        return compact.count >= 3 && Set(compact).count == 1 && "*-_".contains(compact.first!)
    }

    /// One line with its prefix kept and marks removed outside code spans.
    private static func cleanedLine(_ line: String) -> String {
        let ns = line as NSString
        let kept = linePrefix.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))?.range.length ?? 0
        let rest = ns.substring(from: kept) as NSString
        var output = ns.substring(to: kept)
        var cursor = 0
        func clean(_ part: String) -> String {
            markPairs.reduce(part) { value, pair in
                pair.0.stringByReplacingMatches(in: value, range: NSRange(location: 0, length: (value as NSString).length),
                                                withTemplate: pair.1)
            }
        }
        for span in codeSpan.matches(in: rest as String, range: NSRange(location: 0, length: rest.length)) {
            output += clean(rest.substring(with: NSRange(location: cursor, length: span.range.location - cursor)))
            output += rest.substring(with: span.range)
            cursor = NSMaxRange(span.range)
        }
        return output + clean(rest.substring(from: cursor))
    }

    /// Swaps the selected lines with the line above or below, keeping the
    /// selection on the moved text. Line endings (LF or CRLF) are preserved.
    static func moveLines(up: Bool, in text: NSString, selection: NSRange) -> MarkdownSourceEdit? {
        func lineBreak(_ line: NSString) -> String {
            line.hasSuffix("\r\n") ? "\r\n" : line.hasSuffix("\n") ? "\n" : ""
        }
        func body(_ line: NSString) -> String {
            line.substring(to: line.length - (lineBreak(line) as NSString).length)
        }
        let last = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
        let block = NSUnionRange(text.lineRange(for: NSRange(location: selection.location, length: 0)),
                                 text.lineRange(for: NSRange(location: max(selection.location, last), length: 0)))
        let moved = text.substring(with: block) as NSString
        if up {
            guard block.location > 0 else { return nil }
            let previous = text.lineRange(for: NSRange(location: block.location - 1, length: 0))
            let other = text.substring(with: previous) as NSString
            // The last line has no break of its own: it takes the one it displaces.
            let replacement = lineBreak(moved).isEmpty
                ? body(moved) + lineBreak(other) + body(other)
                : (moved as String) + (other as String)
            return MarkdownSourceEdit(range: NSUnionRange(previous, block), replacement: replacement,
                                      selection: NSRange(location: selection.location - previous.length, length: selection.length))
        }
        guard NSMaxRange(block) < text.length else { return nil }
        let next = text.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
        let other = text.substring(with: next) as NSString
        let otherOut = lineBreak(other).isEmpty ? body(other) + lineBreak(moved) : other as String
        let movedOut = lineBreak(other).isEmpty ? body(moved) : moved as String
        return MarkdownSourceEdit(range: NSUnionRange(block, next), replacement: otherOut + movedOut,
                                  selection: NSRange(location: selection.location + (otherOut as NSString).length,
                                                     length: selection.length))
    }
}
