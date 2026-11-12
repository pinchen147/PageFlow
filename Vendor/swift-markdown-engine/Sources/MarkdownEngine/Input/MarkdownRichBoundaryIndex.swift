import Foundation

/// Source/visible coordinates only. Formatting traits and typing inheritance stay with their existing owners.
struct MarkdownRichBoundaryIndex {
    struct Envelope {
        let range: NSRange
        let content: NSRange
        let rich: Bool
        let literalEscape: Bool
    }
    private struct Run { let source: NSRange; let visible: NSRange }
    let source: String
    let hidden: [NSRange]
    let envelopes: [Envelope]
    let visible: NSString
    private let runs: [Run]

    init(source: String, tokens: [MarkdownToken], aliases: Bool, cell: Bool = false) {
        self.source = source
        let ns = source as NSString
        var envelopes: [Envelope] = []
        var hidden: [NSRange] = []
        for token in tokens where token.range.location >= 0 && NSMaxRange(token.range) <= ns.length {
            var content = token.contentRange
            let rich: Bool
            switch token.kind {
            case .bold, .italic, .boldItalic, .underline: rich = false
            case .highlight, .strikethrough, .inlineCode, .backslashEscape: rich = true
            case .link:
                guard !token.markerRanges.isEmpty else { continue }
                rich = true
            case .wikiLink:
                if aliases && !cell {
                    let fragment = ns.substring(with: token.range)
                    if let node = InlineParser.parse(fragment).first, case .wikiLink(_, _, let alias?, _) = node {
                        content = NSRange(location: token.range.location + alias.location, length: alias.length)
                    }
                }
                rich = true
            case .imageLink, .imageEmbed:
                let fragment = ns.substring(with: token.range)
                guard let node = InlineParser.parse(fragment).first else { continue }
                let local = fragment as NSString
                let label: NSRange
                switch node {
                case .image(_, let alt, let destination, _):
                    let description = ImageAltTokens.parse(local.substring(with: alt)).description
                    label = description.isEmpty ? destination : NSRange(location: alt.location, length: description.utf16.count)
                case .imageEmbed(_, let target, _):
                    let raw = local.substring(with: target)
                    let description = ImageAltTokens.parse(raw).description
                    let name = cell ? (ImageEmbedReference(content: raw)?.name ?? description) : description
                    let found = local.range(of: name, range: target)
                    guard found.location != NSNotFound else { continue }
                    label = found
                default: continue
                }
                content = NSRange(location: token.range.location + label.location, length: label.length)
                rich = true
            // These nodes reveal their editable Markdown when active.
            case .heading, .inlineLatex, .blockLatex, .codeBlock: continue
            default: continue
            }
            guard content.location >= token.range.location, NSMaxRange(content) <= NSMaxRange(token.range) else { continue }
            hidden.append(NSRange(location: token.range.location, length: content.location - token.range.location))
            hidden.append(NSRange(location: NSMaxRange(content), length: NSMaxRange(token.range) - NSMaxRange(content)))
            envelopes.append(Envelope(range: token.range, content: content, rich: rich,
                                      literalEscape: token.kind == .backslashEscape))
        }
        self.envelopes = envelopes
        self.hidden = Self.union(hidden.filter { $0.length > 0 })
        var runs: [Run] = [], pieces: [String] = []
        var start = 0, offset = 0
        for marker in self.hidden + [NSRange(location: ns.length, length: 0)] {
            if marker.location > start {
                let range = NSRange(location: start, length: marker.location - start)
                runs.append(Run(source: range, visible: NSRange(location: offset, length: range.length)))
                pieces.append(ns.substring(with: range)); offset += range.length
            }
            start = NSMaxRange(marker)
        }
        self.runs = runs
        self.visible = pieces.joined() as NSString
    }

    var hasRichSyntax: Bool { envelopes.contains { $0.rich && $0.range != $0.content } }
    var movementLimit: Int { hidden.count * 2 + 2 }

    /// Skip only syntax an actual native caret step has entered. Visible steps stay native.
    func skippingHiddenMovement(from before: NSRange, to after: NSRange) -> NSRange? {
        let oldEndpoint: Int, endpoint: Int, anchor: Int?
        if after.length == 0 {
            endpoint = after.location
            oldEndpoint = before.length == 0 ? before.location
                : (after.location == before.location ? NSMaxRange(before) : before.location)
            anchor = nil
        } else if after.location == before.location, NSMaxRange(after) != NSMaxRange(before) {
            oldEndpoint = NSMaxRange(before); endpoint = NSMaxRange(after); anchor = after.location
        } else if NSMaxRange(after) == NSMaxRange(before), after.location != before.location {
            oldEndpoint = before.location; endpoint = after.location; anchor = NSMaxRange(after)
        } else { return nil }
        guard endpoint != oldEndpoint,
              let marker = hidden.first(where: { endpoint > $0.location && endpoint < NSMaxRange($0) }) else { return nil }
        let destination = endpoint > oldEndpoint ? NSMaxRange(marker) : marker.location
        if let anchor {
            return NSRange(location: min(anchor, destination), length: abs(destination - anchor))
        }
        return NSRange(location: destination, length: 0)
    }

    func extendingEndpoints(from before: NSRange, to proposed: NSRange) -> (anchor: Int, active: Int)? {
        guard proposed.length > 0 else { return nil }
        if before.length == 0 { return (before.location, before.location) }
        if proposed.location == before.location, NSMaxRange(proposed) != NSMaxRange(before) {
            return (before.location, NSMaxRange(before))
        }
        if NSMaxRange(proposed) == NSMaxRange(before), proposed.location != before.location {
            return (NSMaxRange(before), before.location)
        }
        return nil
    }

    func nativeMovementProposal(from before: NSRange, to proposed: NSRange,
                                initialVisible: NSRange, expectedVisible: NSRange?) -> NSRange {
        guard before.location >= 0, NSMaxRange(before) <= (source as NSString).length,
              proposed.location >= 0, NSMaxRange(proposed) <= (source as NSString).length,
              visibleRange(proposed) == initialVisible else { return proposed }
        if let expectedVisible {
            if expectedVisible == initialVisible { return before }
            // Zero-width glyphs can propose a source offset opposite to the actual
            // visual arrow. Resolve that ambiguity with AppKit's visible-text result.
            if before.length == 0, proposed.length == 0, expectedVisible.length == 0 {
                let desired = sourceOffset(expectedVisible.location, downstream: true)
                if (desired > before.location && proposed.location < before.location)
                    || (desired < before.location && proposed.location > before.location) {
                    return NSRange(location: desired, length: 0)
                }
            }
        }
        return skippingHiddenMovement(from: before, to: proposed) ?? proposed
    }

    func owns(_ selection: NSRange) -> Bool {
        envelopes.contains { envelope in
            guard envelope.rich, envelope.range != envelope.content else { return false }
            return selection.length == 0
                ? selection.location >= envelope.range.location && selection.location <= NSMaxRange(envelope.range)
                : NSIntersectionRange(selection, envelope.range).length > 0
        }
    }

    func ownsNavigation(_ selection: NSRange) -> Bool {
        owns(selection) || (selection.length > 0 && envelopes.contains { envelope in
            envelope.rich && envelope.range != envelope.content
                && (selection.location == NSMaxRange(envelope.range)
                    || NSMaxRange(selection) == envelope.range.location)
        })
    }

    func visibleOffset(_ sourceOffset: Int) -> Int {
        let offset = min(max(sourceOffset, 0), (source as NSString).length)
        var removed = 0
        for marker in hidden {
            guard marker.location < offset else { break }
            removed += min(marker.length, offset - marker.location)
        }
        return offset - removed
    }

    func visibleRange(_ sourceRange: NSRange) -> NSRange {
        let start = visibleOffset(sourceRange.location), end = visibleOffset(NSMaxRange(sourceRange))
        return NSRange(location: start, length: end - start)
    }

    func sourceOffset(_ visibleOffset: Int, downstream: Bool) -> Int {
        let offset = min(max(visibleOffset, 0), visible.length)
        for (index, run) in runs.enumerated() {
            if offset < NSMaxRange(run.visible) {
                if offset > run.visible.location { return run.source.location + offset - run.visible.location }
                return downstream ? run.source.location : (index == 0 ? 0 : NSMaxRange(runs[index - 1].source))
            }
        }
        return downstream ? (source as NSString).length : runs.last.map { NSMaxRange($0.source) } ?? 0
    }

    func normalized(_ selection: NSRange) -> NSRange {
        let range = visibleRange(selection)
        if selection.length > 0 {
            // Existing source-envelope selections remain exact; only endpoints inside syntax move out.
            var start = selection.location, end = NSMaxRange(selection)
            for marker in hidden {
                if start > marker.location && start < NSMaxRange(marker) { start = marker.location }
                if end > marker.location && end < NSMaxRange(marker) { end = NSMaxRange(marker) }
            }
            return NSRange(location: start, length: end - start)
        }
        if envelopes.contains(where: { $0.rich && selection.location == NSMaxRange($0.range)
            && NSMaxRange($0.range) > NSMaxRange($0.content) }) { return selection }
        let offset = range.location
        let contentBoundary = envelopes.filter { $0.rich }.compactMap { envelope -> Int? in
            if visibleOffset(envelope.content.location) == offset {
                return envelope.literalEscape ? envelope.range.location : envelope.content.location
            }
            if visibleOffset(NSMaxRange(envelope.content)) == offset { return NSMaxRange(envelope.content) }
            return nil
        }.min { abs($0 - selection.location) < abs($1 - selection.location) }
        let sourceOffset = contentBoundary ?? self.sourceOffset(offset, downstream: true)
        return NSRange(location: sourceOffset, length: 0)
    }

    func nextVisibleOffset(_ offset: Int, backward: Bool) -> Int {
        if backward {
            return offset > 0 ? visible.rangeOfComposedCharacterSequence(at: offset - 1).location : 0
        }
        return offset < visible.length ? NSMaxRange(visible.rangeOfComposedCharacterSequence(at: offset)) : visible.length
    }

    func replacement(_ range: NSRange, with text: String, sourceAnchor: Int? = nil) -> MarkdownSourceEdit? {
        guard range.location >= 0, NSMaxRange(range) <= visible.length, range.length > 0 || !text.isEmpty else { return nil }
        let insertion = sourceAnchor ?? sourceOffset(range.location, downstream: true)
        var cuts = runs.compactMap { run -> NSRange? in
            let overlap = NSIntersectionRange(range, run.visible)
            guard overlap.length > 0 else { return nil }
            return NSRange(location: run.source.location + overlap.location - run.visible.location, length: overlap.length)
        }
        for envelope in envelopes {
            let body = visibleRange(envelope.content)
            guard body.length > 0, body.location >= range.location, NSMaxRange(body) <= NSMaxRange(range) else { continue }
            // Replacement text retains the syntax surrounding its insertion point.
            if !text.isEmpty && !envelope.literalEscape
                && insertion >= envelope.content.location && insertion <= NSMaxRange(envelope.content) { continue }
            cuts.append(envelope.range)
        }
        cuts = Self.union(cuts)
        let removedBefore = cuts.reduce(0) { sum, cut in sum + max(0, min(cut.length, insertion - cut.location)) }
        let start = min(insertion, cuts.first?.location ?? insertion)
        let end = max(insertion, cuts.last.map(NSMaxRange) ?? insertion)
        let span = NSRange(location: start, length: end - start)
        let result = NSMutableString(string: (source as NSString).substring(with: span))
        for cut in cuts.reversed() {
            result.deleteCharacters(in: NSRange(location: cut.location - start, length: cut.length))
        }
        let at = insertion - removedBefore - start
        result.insert(text, at: at)
        guard !(result as String).utf16.elementsEqual((source as NSString).substring(with: span).utf16) else { return nil }
        return MarkdownSourceEdit(range: span, replacement: result as String,
            selection: NSRange(location: start + at + text.utf16.count, length: 0))
    }

    private static func union(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = result.last, NSMaxRange(last) >= range.location { result[result.count - 1] = NSUnionRange(last, range) }
            else { result.append(range) }
        }
        return result
    }
}
