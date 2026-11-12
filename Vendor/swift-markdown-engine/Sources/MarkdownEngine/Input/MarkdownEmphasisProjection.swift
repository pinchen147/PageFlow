import Foundation

/// An immutable emphasis-only view of canonical Markdown, using UTF-16 coordinates.
/// Other Markdown syntax remains verbatim; only parser-admitted bold, italic and underline markers disappear by default.
public struct MarkdownEmphasisProjection {
    enum ParsingScope {
        case document, inline
        func tokens(in source: String) -> [MarkdownToken] {
            switch self {
            case .document: return MarkdownTokenizer.parseTokensViaAST(in: source, memoizing: false)
            case .inline: return InlineASTAdapter.tokens(from: InlineParser.parse(source, allowsEmphasisAcrossLineBreaks: true))
            }
        }
    }
    let includesDecorations: Bool
    let scope: ParsingScope
    let source: String
    let tokens: [MarkdownToken]
    let hiddenDelimiterRanges: [NSRange]
    let styleSpans: [MarkdownEmphasisStyleSpan]
    private let runs: [Run]
    private let hiddenPrefixLengths: [Int]
    private let spanPrefixEnds: [Int]
    private struct Run {
        let source: NSRange
        let visible: NSRange
    }
    /// Text with parser-recognized inline style delimiters omitted.
    public let visibleText: String

    /// Parses one canonical source snapshot. Retain the projection for repeated searches.
    /// Native editors instead reuse their existing admitted tokens through the internal initializer.
    public init(source: String) {
        self.init(source: source, scope: .document)
    }

    init(source: String, scope: ParsingScope, includesDecorations: Bool = false) {
        self.init(source: source, tokens: scope.tokens(in: source), scope: scope, includesDecorations: includesDecorations)
    }

    init(source: String, tokens: [MarkdownToken], scope: ParsingScope = .document,
         includesDecorations: Bool = false, hidesEscapes: Bool = false) {
        self.includesDecorations = includesDecorations
        self.scope = scope
        self.source = source
        let length = (source as NSString).length
        self.tokens = tokens.filter { $0.range.location >= 0 && NSMaxRange($0.range) <= length }
        let emphasis = self.tokens.filter {
            !MarkdownEmphasisTraits(kind: $0.kind).isEmpty
                && (includesDecorations || ![.highlight, .strikethrough].contains($0.kind))
        }
        var markers = emphasis.flatMap(\.markerRanges)
        if hidesEscapes {
            for token in self.tokens where token.kind == .backslashEscape {
                markers.append(contentsOf: token.markerRanges)
            }
        }
        markers.sort { $0.location < $1.location }
        var hidden: [NSRange] = []
        for marker in markers where marker.length > 0 {
            if let last = hidden.last, NSMaxRange(last) >= marker.location {
                hidden[hidden.count - 1] = NSUnionRange(last, marker)
            } else { hidden.append(marker) }
        }
        hiddenDelimiterRanges = hidden
        var totalHidden = 0
        let prefixLengths = hidden.map { range in totalHidden += range.length; return totalHidden }
        hiddenPrefixLengths = prefixLengths
        let ns = source as NSString
        var runs: [Run] = []
        var sourceCursor = 0, visibleCursor = 0
        var pieces: [String] = []
        for marker in hidden + [NSRange(location: length, length: 0)] {
            let range = NSRange(location: sourceCursor, length: marker.location - sourceCursor)
            if range.length > 0 {
                runs.append(Run(source: range, visible: NSRange(location: visibleCursor, length: range.length)))
                pieces.append(ns.substring(with: range))
                visibleCursor += range.length
            }
            sourceCursor = NSMaxRange(marker)
        }
        self.runs = runs
        visibleText = pieces.joined()
        let spans = emphasis.map { token in
            let start = Self.visibleOffset(token.contentRange.location, hidden: hidden, prefix: prefixLengths)
            let end = Self.visibleOffset(NSMaxRange(token.contentRange), hidden: hidden, prefix: prefixLengths)
            return MarkdownEmphasisStyleSpan(token: token, visibleRange: NSRange(location: start, length: end - start))
        }.sorted { $0.token.range.location < $1.token.range.location }
        styleSpans = spans
        var maximumEnd = 0
        spanPrefixEnds = spans.map { span in
            maximumEnd = max(maximumEnd, NSMaxRange(span.token.contentRange))
            return maximumEnd
        }
    }

    /// Returns disjoint canonical source ranges contributing to a visible UTF-16 range.
    /// Delimiters are excluded, so a match across emphasis may have several segments.
    /// Empty and invalid ranges return an empty array. Search navigation can use the
    /// envelope from the first segment's start through the last segment's end.
    public func sourceSegments(forVisibleRange range: NSRange) -> [NSRange] {
        guard valid(range), range.length > 0 else { return [] }
        var index = firstRun(endingAfter: range.location)
        var result: [NSRange] = []
        while index < runs.count, runs[index].visible.location < NSMaxRange(range) {
            let run = runs[index]
            let overlap = NSIntersectionRange(run.visible, range)
            if overlap.length > 0 {
                result.append(NSRange(location: run.source.location + overlap.location - run.visible.location,
                                      length: overlap.length))
            }
            index += 1
        }
        return result
    }

    func sourceOffset(forVisibleOffset offset: Int, affinity: MarkdownEmphasisAffinity) -> Int {
        let offset = min(max(0, offset), (visibleText as NSString).length)
        let index = firstRun(endingAfter: offset)
        if index < runs.count {
            let run = runs[index]
            if offset > run.visible.location { return run.source.location + offset - run.visible.location }
            if affinity == .downstream { return run.source.location }
        }
        if index == runs.count, affinity == .downstream { return (source as NSString).length }
        if index > 0 { return NSMaxRange(runs[index - 1].source) }
        return affinity == .downstream ? (source as NSString).length : 0
    }

    func visibleOffset(forSourceOffset offset: Int) -> Int {
        let offset = min(max(0, offset), (source as NSString).length)
        var low = 0, high = hiddenDelimiterRanges.count
        while low < high {
            let middle = (low + high) / 2
            if hiddenDelimiterRanges[middle].location < offset { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return offset }
        let last = hiddenDelimiterRanges[low - 1]
        let previous = low > 1 ? hiddenPrefixLengths[low - 2] : 0
        return offset - previous - min(last.length, offset - last.location)
    }

    func traits(atVisibleOffset offset: Int, affinity: MarkdownEmphasisAffinity) -> MarkdownEmphasisTraits {
        let sourceOffset = self.sourceOffset(forVisibleOffset: offset, affinity: affinity)
        return traits(atSourceOffset: sourceOffset)
    }

    func traits(atSourceOffset offset: Int) -> MarkdownEmphasisTraits {
        var low = 0, high = styleSpans.count
        while low < high {
            let middle = (low + high) / 2
            if styleSpans[middle].token.range.location <= offset { low = middle + 1 } else { high = middle }
        }
        var result = MarkdownEmphasisTraits()
        var index = low - 1
        while index >= 0, spanPrefixEnds[index] >= offset {
            let content = styleSpans[index].token.contentRange
            if offset >= content.location && offset <= NSMaxRange(content) { result.formUnion(styleSpans[index].traits) }
            index -= 1
        }
        return result
    }

    /// Returns a UTF-16 boundary one extended grapheme away, clamped to the visible text.
    func nextVisibleOffset(from offset: Int, direction: Int) -> Int {
        let ns = visibleText as NSString
        let offset = min(max(0, offset), ns.length)
        guard direction != 0 else { return offset }
        if direction < 0 {
            guard offset > 0 else { return 0 }
            return ns.rangeOfComposedCharacterSequence(at: offset - 1).location
        }
        guard offset < ns.length else { return ns.length }
        return NSMaxRange(ns.rangeOfComposedCharacterSequence(at: offset))
    }

    /// Exports just the selected visible text, adding the original spellings of
    /// intersecting emphasis wrappers. Leading/trailing whitespace stays outside markers.
    func balancedMarkdown(forVisibleRange range: NSRange) -> String {
        guard valid(range), range.length > 0 else { return "" }
        struct Event {
            let offset: Int
            let opening: Bool
            let depth: Int
            let text: String
        }
        let ns = visibleText as NSString
        let source = source as NSString
        var events: [Event] = []
        for span in styleSpans {
            let overlap = NSIntersectionRange(range, span.visibleRange)
            guard overlap.length > 0 else { continue }
            let core = MarkdownInlineFormatter.trimmedRange(overlap, in: ns)
            guard core.length > 0, let open = span.token.markerRanges.first,
                  let close = span.token.markerRanges.last, span.token.markerRanges.count >= 2 else { continue }
            events.append(Event(offset: core.location, opening: true, depth: span.token.range.length,
                                text: source.substring(with: open)))
            events.append(Event(offset: NSMaxRange(core), opening: false, depth: span.token.range.length,
                                text: source.substring(with: close)))
        }
        events.sort {
            if $0.offset != $1.offset { return $0.offset < $1.offset }
            if $0.opening != $1.opening { return !$0.opening }
            return $0.opening ? $0.depth > $1.depth : $0.depth < $1.depth
        }
        var result = "", cursor = range.location
        for event in events {
            result += ns.substring(with: NSRange(location: cursor, length: event.offset - cursor))
            result += event.text
            cursor = event.offset
        }
        result += ns.substring(with: NSRange(location: cursor, length: NSMaxRange(range) - cursor))
        return result
    }

    private func valid(_ range: NSRange) -> Bool {
        range.location >= 0 && range.location <= (visibleText as NSString).length
            && range.length >= 0 && range.length <= (visibleText as NSString).length - range.location
    }

    private func firstRun(endingAfter offset: Int) -> Int {
        var low = 0, high = runs.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(runs[middle].visible) <= offset { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private static func visibleOffset(_ offset: Int, hidden: [NSRange], prefix: [Int]) -> Int {
        var low = 0, high = hidden.count
        while low < high {
            let middle = (low + high) / 2
            if hidden[middle].location < offset { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return offset }
        let previous = low > 1 ? prefix[low - 2] : 0
        let marker = hidden[low - 1]
        return offset - previous - min(marker.length, offset - marker.location)
    }
}

enum MarkdownEmphasisAffinity { case upstream, downstream }

struct MarkdownEmphasisStyleSpan {
    let token: MarkdownToken
    let visibleRange: NSRange
    var traits: MarkdownEmphasisTraits { MarkdownEmphasisTraits(kind: token.kind) }
    var sourceRange: NSRange { token.contentRange }
}
