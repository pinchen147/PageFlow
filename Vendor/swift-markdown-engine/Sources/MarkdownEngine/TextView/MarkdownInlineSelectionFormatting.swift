import Foundation

/// Rewrites only the connected inline spans crossed by a selection.
/// Native storage, structural editing and history remain owned by the caller.
enum MarkdownInlineSelectionFormatting {
    static func plan(text: NSString, selection: NSRange, style: MarkdownInlineStyle,
                     tokens: [MarkdownToken], removeStyle: Bool, normalizeFragments: Bool) -> MarkdownInlineFormatPlan? {
        let intersects = tokens.filter { NSIntersectionRange($0.range, selection).length > 0 }
        // AppKit can include one concealed delimiter when the visible selection
        // ends at a style boundary. Wrapping that range would split the marker pair.
        let crosses = intersects.contains {
            !MarkdownInlineFormatter.rangeContains($0.contentRange, selection)
                && !MarkdownInlineFormatter.rangeContains(selection, $0.range)
        }
        let hasExplicitMarks = intersects.contains {
            [.bold, .italic, .highlight, .strikethrough].contains($0.kind)
                && text.character(at: $0.range.location) == 60
        }
        let selectedSource = text.substring(with: selection)
        let includesBoundaryWhitespace = selectedSource.first?.isWhitespace == true || selectedSource.last?.isWhitespace == true
        guard crosses || hasExplicitMarks || includesBoundaryWhitespace || normalizeFragments else { return nil }
        var region = selection
        var previous: NSRange
        repeat {
            previous = region
            for token in tokens where NSIntersectionRange(token.range, region).length > 0 {
                region = NSUnionRange(region, token.range)
            }
        } while region != previous
        let source = text.substring(with: region)
        guard !source.contains("\n"), !source.contains("\r"),
              let decoded = projection(source) else { return nil }
        let local = NSRange(location: selection.location - region.location, length: selection.length)
        guard decoded.protectedRanges.allSatisfy({ NSIntersectionRange($0, local).length == 0 }) else { return nil }
        let start = decoded.positions.prefix { $0 < local.location }.count
        let end = decoded.positions.prefix { $0 < NSMaxRange(local) }.count
        if end == start {
            return MarkdownInlineFormatPlan(replacementRange: selection, replacement: text.substring(with: selection),
                selectionAfter: selection, actionName: style.actionName)
        }
        let selected = NSRange(location: start, length: end - start)
        guard let updated = applying(style, remove: removeStyle, to: selected, in: decoded.text),
              let replacement = explicitSource(updated),
              let encoded = projection(replacement), encoded.text == updated,
              start < encoded.positions.count, end > start else { return nil }
        let selectedStart = encoded.positions[start]
        let selectedEnd = encoded.positions[end - 1] + 1
        return MarkdownInlineFormatPlan(replacementRange: region, replacement: replacement,
            selectionAfter: NSRange(location: region.location + selectedStart, length: selectedEnd - selectedStart),
            actionName: style.actionName)
    }

    /// Compact Markdown delimiters can change meaning at their neighbours, even when
    /// the selected source parses in isolation. Keep compact syntax when it round-trips.
    static func validating(_ compact: MarkdownInlineFormatPlan, text: NSString, selection: NSRange,
                           style: MarkdownInlineStyle, tokens: [MarkdownToken], removeStyle: Bool) -> MarkdownInlineFormatPlan? {
        let neighbours = NSRange(location: max(0, selection.location - 1),
            length: min(text.length, NSMaxRange(selection) + 1) - max(0, selection.location - 1))
        let first = selection.location
        let end = NSMaxRange(selection)
        let boundaryHasPunctuation = [first - 1, first, end - 1, end].contains { offset in
            offset >= 0 && offset < text.length && InlineParser.isAsciiPunctuationChar(text.character(at: offset))
        }
        guard boundaryHasPunctuation || tokens.contains(where: { NSIntersectionRange(neighbours, $0.range).length > 0 })
            else { return compact }

        var begin = 0, lineEnd = 0
        text.getLineStart(&begin, end: nil, contentsEnd: &lineEnd, for: selection)
        let line = NSRange(location: begin, length: lineEnd - begin)
        guard MarkdownInlineFormatter.rangeContains(line, compact.replacementRange),
              MarkdownInlineFormatter.rangeContains(line, selection) else { return compact }
        let original = text.substring(with: line)
        let replacement = NSRange(location: compact.replacementRange.location - begin, length: compact.replacementRange.length)
        let candidate = (original as NSString).replacingCharacters(in: replacement, with: compact.replacement)
        guard let before = projection(original), let after = projection(candidate) else { return compact }
        func visibleRange(_ range: NSRange, positions: [Int]) -> NSRange {
            let start = positions.prefix { $0 < range.location - begin }.count
            let end = positions.prefix { $0 < NSMaxRange(range) - begin }.count
            return NSRange(location: start, length: end - start)
        }
        let selected = visibleRange(selection, positions: before.positions)
        guard let expected = applying(style, remove: removeStyle, to: selected, in: before.text),
              after.text != expected || visibleRange(compact.selectionAfter, positions: after.positions) != selected
            else { return compact }
        return plan(text: text, selection: selection, style: style, tokens: tokens,
                    removeStyle: removeStyle, normalizeFragments: true)
    }

    private static func applying(_ style: MarkdownInlineStyle, remove: Bool, to selected: NSRange,
                                 in content: SemanticInlineText) -> SemanticInlineText? {
        let mark: SemanticInlineMarks
        switch style {
        case .bold: mark = .bold
        case .italic: mark = .italic
        case .underline: mark = .underline
        case .highlight: mark = .highlight
        case .strikethrough: mark = .strikethrough
        }
        guard let slice = try? content.slice(in: selected) else { return nil }
        let changed = SemanticInlineText(runs: slice.runs.map {
            SemanticInlineRun(payload: $0.payload,
                marks: remove ? $0.marks.subtracting(mark) : $0.marks.union(mark), link: $0.link)
        })
        return try? content.replacing(selected, with: changed)
    }

    private static func projection(_ source: String) -> (text: SemanticInlineText, positions: [Int], protectedRanges: [NSRange])? {
        let tokens = InlineASTAdapter.tokens(from: InlineParser.parse(source))
        let leaves = tokens.filter { [.inlineCode, .link, .inlineLatex, .imageLink, .wikiLink, .imageEmbed].contains($0.kind) }.sorted {
            $0.range.location == $1.range.location ? $0.range.length > $1.range.length : $0.range.location < $1.range.location
        }
        var protectedRanges: [NSRange] = []
        for leaf in leaves where protectedRanges.last.map({ NSMaxRange($0) <= leaf.range.location }) ?? true {
            protectedRanges.append(leaf.range)
        }
        var hidden = IndexSet()
        let ns = source as NSString
        var styles = Array(repeating: SemanticInlineMarks(), count: ns.length)
        for token in tokens {
            if protectedRanges.contains(where: { MarkdownInlineFormatter.rangeContains($0, token.range) }) { continue }
            let mark: SemanticInlineMarks
            switch token.kind {
            case .bold: mark = .bold
            case .italic: mark = .italic
            case .boldItalic: mark = [.bold, .italic]
            case .underline: mark = .underline
            case .highlight: mark = .highlight
            case .strikethrough: mark = .strikethrough
            case .backslashEscape: mark = []
            default: return nil
            }
            for marker in token.markerRanges { hidden.insert(integersIn: marker.location..<NSMaxRange(marker)) }
            if !mark.isEmpty {
                for offset in token.contentRange.location..<NSMaxRange(token.contentRange) { styles[offset].formUnion(mark) }
            }
        }
        var protectedByStart: [Int: NSRange] = [:]
        for range in protectedRanges {
            protectedByStart[range.location] = range
            hidden.insert(integersIn: (range.location + 1)..<NSMaxRange(range))
        }
        let positions = (0..<ns.length).filter { !hidden.contains($0) }
        var runs: [SemanticInlineRun] = []
        var units: [unichar] = []
        var current: SemanticInlineMarks = []
        func flush() {
            if !units.isEmpty { runs.append(.init(text: String(decoding: units, as: UTF16.self), marks: current)) }
            units.removeAll(keepingCapacity: true)
        }
        for at in positions {
            let marks = styles[at]
            if marks != current { flush(); current = marks }
            if let range = protectedByStart[at] {
                flush()
                runs.append(.init(object: .opaque(ns.substring(with: range)), marks: marks))
                continue
            }
            units.append(ns.character(at: at))
        }
        flush()
        return (SemanticInlineText(runs: runs), positions, protectedRanges)
    }

    private static func explicitSource(_ content: SemanticInlineText) -> String? {
        var result = ""
        let punctuation = Set("\\`*_{}[]()#+-.!<>~=&|$".unicodeScalars)
        for run in content.runs {
            guard run.link == nil else { return nil }
            var body: String
            switch run.payload {
            case .text(let text):
                body = text.unicodeScalars.map { punctuation.contains($0) ? "\\" + String($0) : String($0) }.joined()
            case .object(.opaque(let source)): body = source
            default: return nil
            }
            for (mark, tag) in SemanticInlineCodecHTML.markTags.reversed() where run.marks.contains(mark) {
                body = "<\(tag)>" + body + "</\(tag)>"
            }
            result += body
        }
        return result
    }

}
