import Foundation

/// One canonical replacement; the adapter owns its native transaction and Undo grouping.
struct MarkdownEmphasisEditPlan: Equatable {
    let replacementRange: NSRange
    let replacement: String
    let selectionAfter: NSRange
}

enum MarkdownEmphasisEditPlanner {
    private struct Patch {
        let range: NSRange
        let text: String
        let order: Int
        init(range: NSRange, text: String, order: Int = 0) {
            self.range = range; self.text = text; self.order = order
        }
    }

    /// A native word can cross several source wrappers. Remove only this trait
    /// from its intersections first, retaining orthogonal and outside styles;
    /// mixed words then receive the requested style through the existing formatter.
    static func formatting(style: MarkdownInlineStyle, visibleRange word: NSRange, caret: Int,
                           projection: MarkdownEmphasisProjection) -> MarkdownEmphasisEditPlan? {
        let trait = MarkdownEmphasisTraits(style: style)
        guard !trait.isEmpty, word.length > 0 else { return nil }
        let spans = projection.styleSpans.filter { $0.traits.contains(trait) && NSIntersectionRange($0.visibleRange, word).length > 0 }
        var coveredEnd = word.location
        for span in spans.sorted(by: { $0.visibleRange.location < $1.visibleRange.location }) {
            let overlap = NSIntersectionRange(span.visibleRange, word)
            if overlap.location > coveredEnd { break }
            coveredEnd = max(coveredEnd, NSMaxRange(overlap))
        }
        let removesStyle = coveredEnd == NSMaxRange(word)
        var current = projection
        func sourceRange(_ visible: NSRange, in current: MarkdownEmphasisProjection) -> NSRange? {
            let segments = current.sourceSegments(forVisibleRange: visible)
            guard let first = segments.first, let last = segments.last else { return nil }
            var target = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
            for span in current.styleSpans where MarkdownInlineFormatter.rangeContains(visible, span.visibleRange) {
                target = NSUnionRange(target, span.token.range)
            }
            return target
        }
        func applying(_ targets: [NSRange], to current: MarkdownEmphasisProjection) -> MarkdownEmphasisProjection? {
            let plans = MarkdownInlineFormatter.plans(text: current.source as NSString,
                targetRanges: targets, style: style, index: EnclosingTokenIndex(tokens: current.tokens, style: style))
            guard plans.count == targets.count else { return nil }
            let source = NSMutableString(string: current.source)
            for plan in plans.reversed() { source.replaceCharacters(in: plan.replacementRange, with: plan.replacement) }
            let result = MarkdownEmphasisProjection(source: source as String, scope: projection.scope, includesDecorations: projection.includesDecorations)
            guard result.visibleText.utf16.elementsEqual(projection.visibleText.utf16) else { return nil }
            return result
        }
        // Each pass removes at least one admitted same-style span's intersection.
        // The bounded loop also refuses any unexpected parser non-convergence.
        for _ in 0..<spans.count {
            guard let span = current.styleSpans.first(where: {
                $0.traits.contains(trait) && NSIntersectionRange($0.visibleRange, word).length > 0
            }) else { break }
            let overlap = NSIntersectionRange(span.visibleRange, word)
            guard let target = sourceRange(overlap, in: current), let next = applying([target], to: current) else { return nil }
            current = next
        }
        guard !current.styleSpans.contains(where: {
            $0.traits.contains(trait) && NSIntersectionRange($0.visibleRange, word).length > 0
        }) else { return nil }
        if !removesStyle {
            // A wrapper crossing a word edge cannot nest around one outer word
            // wrapper. Partition the requested style at that container boundary
            // instead: <u>lead pla</u>net becomes <u>lead **pla**</u>**net**.
            // Existing orthogonal wrappers, including their outside whitespace,
            // remain untouched. Fully contained/containing spans need no split.
            var boundaries = Set([word.location, NSMaxRange(word)])
            for span in current.styleSpans where NSIntersectionRange(span.visibleRange, word).length > 0
                && !MarkdownInlineFormatter.rangeContains(word, span.visibleRange)
                && !MarkdownInlineFormatter.rangeContains(span.visibleRange, word) {
                for edge in [span.visibleRange.location, NSMaxRange(span.visibleRange)]
                    where edge > word.location && edge < NSMaxRange(word) { boundaries.insert(edge) }
            }
            let ordered = boundaries.sorted()
            var targets: [NSRange] = []
            for (start, end) in zip(ordered, ordered.dropFirst()) {
                guard let target = sourceRange(NSRange(location: start, length: end - start), in: current) else { return nil }
                targets.append(target)
            }
            // These are one semantic edit: a new <u> next to ** can change its
            // delimiter flanking until the neighboring partition is wrapped too.
            // Parse the complete batch, never a transient half-formatted word.
            guard let next = applying(targets, to: current) else { return nil }
            current = next
        }
        return boundedPlan(original: projection.source as NSString,
            region: NSRange(location: 0, length: projection.source.utf16.count), replacement: current.source,
            caret: current.sourceOffset(forVisibleOffset: caret, affinity: .downstream))
    }

    static func insertion(text: String, atSourceOffset offset: Int, traits: MarkdownEmphasisTraits,
                          projection: MarkdownEmphasisProjection) -> MarkdownEmphasisEditPlan? {
        guard !text.isEmpty, offset >= 0, offset <= (projection.source as NSString).length else { return nil }
        let trailingCount = text.reversed().prefix(while: \.isWhitespace).reduce(0) { $0 + String($1).utf16.count }
        if trailingCount > 0, trailingCount < text.utf16.count {
            let nsText = text as NSString
            let body = nsText.substring(to: nsText.length - trailingCount)
            let trailing = nsText.substring(from: nsText.length - trailingCount)
            return insertingBodyThenWhitespace(body: body, whitespace: trailing, offset: offset, traits: traits, projection: projection)
        }
        let visible = projection.visibleOffset(forSourceOffset: offset)
        let upstream = projection.sourceOffset(forVisibleOffset: visible, affinity: .upstream)
        let downstream = projection.sourceOffset(forVisibleOffset: visible, affinity: .downstream)
        // Prefer a boundary inside the requested style, so end typing extends a run.
        let candidates = [offset, upstream, downstream]
        let insertion = candidates.min {
            projection.traits(atSourceOffset: $0).symmetricDifference(traits).rawValue.nonzeroBitCount
                < projection.traits(atSourceOffset: $1).symmetricDifference(traits).rawValue.nonzeroBitCount
        } ?? offset
        let inherited = projection.traits(atSourceOffset: insertion)
        let ns = projection.source as NSString

        // Whitespace typed beyond a styled run stays outside its closing markers;
        // CommonMark cannot recognize a closing delimiter preceded by whitespace.
        if text.allSatisfy(\.isWhitespace), !traits.isEmpty,
           let span = projection.styleSpans.filter({
               NSMaxRange($0.visibleRange) == visible && $0.traits.isSubset(of: traits)
           }).max(by: { NSMaxRange($0.token.range) < NSMaxRange($1.token.range) }) {
            let end = NSMaxRange(span.token.range)
            return MarkdownEmphasisEditPlan(replacementRange: NSRange(location: end, length: 0), replacement: text,
                                            selectionAfter: NSRange(location: end + text.utf16.count, length: 0))
        }

        // Resume a pending style across trailing spaces by moving the existing closing
        // markers. This keeps a single run instead of wrapping every committed character.
        if !traits.isEmpty, !text.allSatisfy(\.isWhitespace), inherited != traits,
           let span = projection.styleSpans.reversed().first(where: { span in
               let end = NSMaxRange(span.token.range)
               guard end <= offset, span.traits.isSubset(of: traits), end < offset else { return false }
               let gap = ns.substring(with: NSRange(location: end, length: offset - end))
               return gap.allSatisfy { $0.isWhitespace && !$0.isNewline }
                   && projection.traits(atSourceOffset: projection.sourceOffset(forVisibleOffset: NSMaxRange(span.visibleRange), affinity: .upstream)) == traits
           }) {
            let start = projection.sourceOffset(forVisibleOffset: NSMaxRange(span.visibleRange), affinity: .upstream)
            let suffix = NSRange(location: start, length: NSMaxRange(span.token.range) - start)
            if suffix.length > 0 {
                let markers = ns.substring(with: suffix)
                let gap = ns.substring(with: NSRange(location: NSMaxRange(span.token.range), length: offset - NSMaxRange(span.token.range)))
                let replacement = gap + text + markers
                return MarkdownEmphasisEditPlan(replacementRange: NSRange(location: start, length: offset - start),
                                                replacement: replacement,
                                                selectionAfter: NSRange(location: start + gap.utf16.count + text.utf16.count, length: 0))
            }
        }
        var region = ns.paragraphRange(for: NSRange(location: insertion, length: 0))
        for span in projection.styleSpans where insertion >= span.token.contentRange.location && insertion <= NSMaxRange(span.token.contentRange) {
            region = NSUnionRange(region, span.token.range)
        }
        return materialize(source: ns, region: region, patches: [Patch(range: NSRange(location: insertion, length: 0), text: text)],
                           insertedAt: insertion, insertedLength: text.utf16.count, inherited: inherited, desired: traits,
                           admittedTokens: projection.styleSpans.map(\.token), scope: projection.scope)
    }

    private static func insertingBodyThenWhitespace(body: String, whitespace: String, offset: Int,
                                                   traits: MarkdownEmphasisTraits,
                                                   projection: MarkdownEmphasisProjection) -> MarkdownEmphasisEditPlan? {
        guard let first = insertion(text: body, atSourceOffset: offset, traits: traits, projection: projection) else { return nil }
        let source = projection.source as NSString
        var region = source.paragraphRange(for: NSRange(location: offset, length: 0))
        region = NSUnionRange(region, first.replacementRange)
        for span in projection.styleSpans where offset >= span.token.range.location && offset <= NSMaxRange(span.token.range) {
            region = NSUnionRange(region, span.token.range)
        }
        let local = NSMutableString(string: source.substring(with: region))
        local.replaceCharacters(in: NSRange(location: first.replacementRange.location - region.location,
                                           length: first.replacementRange.length), with: first.replacement)
        let nextProjection = MarkdownEmphasisProjection(source: local as String, scope: projection.scope, includesDecorations: projection.includesDecorations)
        guard let second = insertion(text: whitespace, atSourceOffset: first.selectionAfter.location - region.location,
                                     traits: traits, projection: nextProjection) else { return nil }
        local.replaceCharacters(in: second.replacementRange, with: second.replacement)
        return boundedPlan(original: source, region: region, replacement: local as String,
                           caret: region.location + second.selectionAfter.location)
    }

    static func deletion(visibleRange: NSRange, projection: MarkdownEmphasisProjection) -> MarkdownEmphasisEditPlan? {
        replacement(text: "", visibleRange: visibleRange, traits: [], projection: projection)
    }

    /// Replaces a visible selection while retaining surviving canonical syntax. Nil
    /// traits inherits the first selected character, as ordinary native replacement does.
    static func replacement(text: String, visibleRange: NSRange, traits: MarkdownEmphasisTraits? = nil,
                            projection: MarkdownEmphasisProjection) -> MarkdownEmphasisEditPlan? {
        let ns = projection.source as NSString
        let visibleNS = projection.visibleText as NSString
        guard visibleRange.location >= 0, visibleRange.length > 0,
              visibleRange.location <= visibleNS.length,
              visibleRange.length <= visibleNS.length - visibleRange.location else { return nil }
        // Native adapters normally pass composed ranges. Expanding here also protects
        // callers such as search replacement from cutting a UTF-16 surrogate or joiner.
        let range = visibleNS.rangeOfComposedCharacterSequences(for: visibleRange)
        let segments = projection.sourceSegments(forVisibleRange: range)
        guard let first = segments.first, let last = segments.last else { return nil }
        let insertion = first.location
        let inherited = projection.traits(atSourceOffset: insertion)
        let desired = traits ?? inherited
        var patches = segments.map { Patch(range: $0, text: "") }
        patches[0] = Patch(range: first, text: text)
        var region = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        for span in projection.styleSpans where NSIntersectionRange(span.visibleRange, range).length > 0 {
            region = NSUnionRange(region, span.token.range)
            let fullyRemoved = NSIntersectionRange(span.visibleRange, range).length == span.visibleRange.length
            let retainsInsertion = !text.isEmpty && desired.isSuperset(of: span.traits)
                && insertion >= span.token.contentRange.location && insertion <= NSMaxRange(span.token.contentRange)
            if fullyRemoved && !retainsInsertion {
                patches += span.token.markerRanges.map { Patch(range: $0, text: "") }
            }
        }
        return materialize(source: ns, region: region, patches: patches, insertedAt: insertion,
                           insertedLength: text.utf16.count, inherited: text.isEmpty ? [] : inherited, desired: desired,
                           admittedTokens: projection.styleSpans.map(\.token), scope: projection.scope)
    }

    /// Plans a complete Find snapshot together so adjacent matches can retire one
    /// enclosing wrapper without duplicate or overlapping source replacements.
    static func replacement(text: String, visibleRanges: [NSRange],
                            projection: MarkdownEmphasisProjection) -> MarkdownEmphasisEditPlan? {
        guard !visibleRanges.isEmpty else { return nil }
        if visibleRanges.count == 1 {
            return replacement(text: text, visibleRange: visibleRanges[0], projection: projection)
        }
        let visible = projection.visibleText as NSString
        var previousEnd = 0
        var ranges: [NSRange] = []
        var insertions: [Int] = []
        var patches: [Patch] = []
        var region: NSRange?
        for original in visibleRanges {
            guard original.location >= 0, original.length > 0,
                  original.location <= visible.length, original.length <= visible.length - original.location else { return nil }
            let range = visible.rangeOfComposedCharacterSequences(for: original)
            guard range.location >= previousEnd else { return nil }
            previousEnd = NSMaxRange(range)
            let segments = projection.sourceSegments(forVisibleRange: range)
            guard let first = segments.first, let last = segments.last else { return nil }
            insertions.append(first.location)
            ranges.append(range)
            patches.append(Patch(range: first, text: text))
            patches += segments.dropFirst().map { Patch(range: $0, text: "") }
            let envelope = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
            region = region.map { NSUnionRange($0, envelope) } ?? envelope
        }
        guard var region, let firstInsertion = insertions.first else { return nil }
        var totalSelected = 0
        let selectedPrefixes = ranges.map { range in totalSelected += range.length; return totalSelected }
        func selectedLength(before offset: Int) -> Int {
            var low = 0, high = ranges.count
            while low < high {
                let middle = (low + high) / 2
                if ranges[middle].location < offset { low = middle + 1 } else { high = middle }
            }
            guard low > 0 else { return 0 }
            let index = low - 1
            let prefix = index > 0 ? selectedPrefixes[index - 1] : 0
            return prefix + min(ranges[index].length, offset - ranges[index].location)
        }
        for span in projection.styleSpans {
            let removedLength = selectedLength(before: NSMaxRange(span.visibleRange))
                - selectedLength(before: span.visibleRange.location)
            guard removedLength > 0 else { continue }
            region = NSUnionRange(region, span.token.range)
            var low = 0, high = insertions.count
            while low < high {
                let middle = (low + high) / 2
                if insertions[middle] < span.token.contentRange.location { low = middle + 1 } else { high = middle }
            }
            let retainsInsertion = !text.isEmpty && low < insertions.count
                && insertions[low] < NSMaxRange(span.token.contentRange)
            if removedLength == span.visibleRange.length && !retainsInsertion {
                patches += span.token.markerRanges.map { Patch(range: $0, text: "") }
            }
        }
        let inherited = projection.traits(atSourceOffset: firstInsertion)
        return materialize(source: projection.source as NSString, region: region, patches: patches,
                           insertedAt: firstInsertion, insertedLength: text.utf16.count,
                           inherited: inherited, desired: inherited,
                           admittedTokens: projection.styleSpans.map(\.token), scope: projection.scope)
    }

    /// Repositions only admitted markers after a replacement exposes edge whitespace.
    /// This runs before reparsing: CommonMark would otherwise reject those wrappers.
    private static func normalizeMarkers(text: NSMutableString, tokens: [MarkdownToken],
                                         selection: NSRange) -> NSRange {
        let projection = MarkdownEmphasisProjection(source: text as String, tokens: tokens)
        var patches: [Patch] = []
        let visible = projection.visibleText as NSString
        for span in projection.styleSpans {
            let core = MarkdownInlineFormatter.trimmedRange(span.visibleRange, in: visible)
            guard let opening = span.token.markerRanges.first, let closing = span.token.markerRanges.last else { continue }
            if core.length == 0 {
                patches += span.token.markerRanges.map { Patch(range: $0, text: "") }
                continue
            }
            if core.location > span.visibleRange.location {
                let destination = projection.sourceOffset(forVisibleOffset: core.location, affinity: .upstream)
                patches += [Patch(range: opening, text: ""),
                            Patch(range: NSRange(location: destination, length: 0), text: text.substring(with: opening), order: opening.location)]
            }
            if NSMaxRange(core) < NSMaxRange(span.visibleRange) {
                let destination = projection.sourceOffset(forVisibleOffset: NSMaxRange(core), affinity: .downstream)
                patches += [Patch(range: closing, text: ""),
                            Patch(range: NSRange(location: destination, length: 0), text: text.substring(with: closing), order: closing.location)]
            }
        }
        let sorted = sortedPatches(patches)
        for patch in sorted.reversed() { text.replaceCharacters(in: patch.range, with: patch.text) }
        let start = shiftedOffset(selection.location, by: sorted, affinity: .downstream)
        let end = shiftedOffset(NSMaxRange(selection), by: sorted, affinity: .upstream)
        return NSRange(location: min(start, end), length: max(0, end - start))
    }

    private static func sortedPatches(_ patches: [Patch]) -> [Patch] {
        patches.sorted {
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            if $0.range.length != $1.range.length { return $0.range.length < $1.range.length }
            return $0.order < $1.order
        }
    }

    private static func shiftedOffset(_ offset: Int, by patches: [Patch], affinity: MarkdownEmphasisAffinity) -> Int {
        var delta = 0
        for patch in patches {
            if offset < patch.range.location { break }
            if offset >= NSMaxRange(patch.range), patch.range.length > 0 {
                delta += patch.text.utf16.count - patch.range.length
            } else if patch.range.length == 0, offset == patch.range.location {
                if affinity == .downstream { delta += patch.text.utf16.count }
            } else if offset > NSMaxRange(patch.range) {
                delta += patch.text.utf16.count - patch.range.length
            } else {
                return patch.range.location + delta + (affinity == .downstream ? patch.text.utf16.count : 0)
            }
        }
        return offset + delta
    }

    private static func materialize(source: NSString, region: NSRange, patches: [Patch], insertedAt: Int,
                                    insertedLength: Int, inherited: MarkdownEmphasisTraits,
                                    desired: MarkdownEmphasisTraits, admittedTokens: [MarkdownToken] = [],
                                    scope: MarkdownEmphasisProjection.ParsingScope = .document) -> MarkdownEmphasisEditPlan? {
        let local = NSMutableString(string: source.substring(with: region))
        // Token marker ranges are disjoint even for nested emphasis. Reject overlapping
        // input rather than making ordering-dependent mutations to canonical source.
        let sorted = sortedPatches(patches)
        for pair in zip(sorted, sorted.dropFirst()) where NSMaxRange(pair.0.range) > pair.1.range.location { return nil }
        for patch in sorted.reversed() {
            local.replaceCharacters(in: NSRange(location: patch.range.location - region.location, length: patch.range.length), with: patch.text)
        }
        let removedBefore = sorted.filter { NSMaxRange($0.range) <= insertedAt && $0.range.location < insertedAt }
            .reduce(0) { $0 + $1.range.length - $1.text.utf16.count }
        var selected = NSRange(location: insertedAt - region.location - removedBefore, length: insertedLength)
        if !admittedTokens.isEmpty {
            // Batch Find may have thousands of patches. Prefix shifts and binary
            // lookup keep admitted-token mapping independent of match count.
            var delta = 0
            let prefixDeltas = sorted.map { patch in
                delta += patch.text.utf16.count - patch.range.length
                return delta
            }
            let hasInsertions = sorted.contains { $0.range.length == 0 }
            func mappedOffset(_ offset: Int, affinity: MarkdownEmphasisAffinity) -> Int {
                if hasInsertions { return shiftedOffset(offset, by: sorted, affinity: affinity) }
                var low = 0, high = sorted.count
                while low < high {
                    let middle = (low + high) / 2
                    if NSMaxRange(sorted[middle].range) <= offset { low = middle + 1 } else { high = middle }
                }
                let shift = low > 0 ? prefixDeltas[low - 1] : 0
                if low < sorted.count, sorted[low].range.location <= offset {
                    return sorted[low].range.location + shift + (affinity == .downstream ? sorted[low].text.utf16.count : 0)
                }
                return offset + shift
            }
            func intersectsPatch(_ range: NSRange) -> Bool {
                var low = 0, high = sorted.count
                while low < high {
                    let middle = (low + high) / 2
                    if NSMaxRange(sorted[middle].range) <= range.location { low = middle + 1 } else { high = middle }
                }
                while low < sorted.count, sorted[low].range.location < NSMaxRange(range) {
                    if sorted[low].range.length > 0 { return true }
                    low += 1
                }
                return false
            }
            let survivingTokens: [MarkdownToken] = admittedTokens.compactMap { token in
                guard token.range.location >= region.location, NSMaxRange(token.range) <= NSMaxRange(region),
                      !token.markerRanges.contains(where: intersectsPatch) else { return nil }
                let markers = token.markerRanges.map { marker in
                    NSRange(location: mappedOffset(marker.location, affinity: .upstream) - region.location, length: marker.length)
                }
                guard let first = markers.first, let last = markers.last else { return nil }
                return MarkdownToken(kind: token.kind, range: NSRange(location: first.location, length: NSMaxRange(last) - first.location),
                                     contentRange: NSRange(location: NSMaxRange(first), length: last.location - NSMaxRange(first)), markerRanges: markers)
            }
            selected = normalizeMarkers(text: local, tokens: survivingTokens, selection: selected)
        }
        if insertedLength > 0 {
            // Existing formatter owns marker ambiguity, partial demotion and preserving
            // the orthogonal trait; the planner does not maintain a second regex parser.
            for (trait, style) in [(MarkdownEmphasisTraits.bold, MarkdownInlineStyle.bold), (.italic, .italic), (.underline, .underline),
                                   (.highlight, .highlight), (.strikethrough, .strikethrough)] {
                guard inherited.contains(trait) != desired.contains(trait) else { continue }
                let tokens = scope.tokens(in: local as String)
                let index = EnclosingTokenIndex(tokens: tokens, style: style)
                if !desired.contains(trait), index.smallestEnclosing(selected) == nil { continue }
                let plans = MarkdownInlineFormatter.plans(text: local, targetRanges: [selected], style: style, index: index)
                guard let plan = plans.first else { continue }
                local.replaceCharacters(in: plan.replacementRange, with: plan.replacement)
                selected = plan.selectionAfter
            }
        }
        // Narrow the transaction to the changed region while preserving the caller's
        // source selection. Prefix/suffix comparison uses composed boundaries.
        return boundedPlan(original: source, region: region, replacement: local as String,
                           caret: region.location + NSMaxRange(selected))
    }

    private static func boundedPlan(original: NSString, region: NSRange, replacement: String,
                                    caret: Int) -> MarkdownEmphasisEditPlan {
        let before = original.substring(with: region)
        var prefix = 0
        for (left, right) in zip(before, replacement) {
            guard String(left).utf16.elementsEqual(String(right).utf16) else { break }
            prefix += String(left).utf16.count
        }
        let beforeNS = before as NSString, afterNS = replacement as NSString
        var suffix = 0
        for (left, right) in zip(before.reversed(), replacement.reversed()) {
            let length = String(left).utf16.count
            guard String(left).utf16.elementsEqual(String(right).utf16),
                  prefix + suffix + length <= min(beforeNS.length, afterNS.length) else { break }
            suffix += length
        }
        return MarkdownEmphasisEditPlan(
            replacementRange: NSRange(location: region.location + prefix, length: beforeNS.length - prefix - suffix),
            replacement: afterNS.substring(with: NSRange(location: prefix, length: afterNS.length - prefix - suffix)),
            selectionAfter: NSRange(location: caret, length: 0))
    }
}
