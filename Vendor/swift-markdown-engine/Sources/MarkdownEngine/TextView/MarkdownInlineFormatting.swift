//
//  MarkdownInlineFormatting.swift
//  MarkdownEngine
//
//  Source-level inline formatting transforms for editor commands.
//

import Foundation

enum MarkdownInlineStyle: Equatable {
    case bold
    case italic
    case underline
    case strikethrough
    case highlight

    var openingMarker: String {
        switch self {
        case .bold: return "**"
        case .italic: return "*"
        case .underline: return "<u>"
        case .strikethrough: return "~~"
        case .highlight: return "=="
        }
    }

    var closingMarker: String {
        switch self {
        case .bold: return "**"
        case .italic: return "*"
        case .underline: return "</u>"
        case .strikethrough: return "~~"
        case .highlight: return "=="
        }
    }

    var actionName: String {
        switch self {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .underline: return "Underline"
        case .strikethrough: return "Strikethrough"
        case .highlight: return "Highlight"
        }
    }
}

struct MarkdownInlineFormatPlan: Equatable {
    let replacementRange: NSRange
    let replacement: String
    let selectionAfter: NSRange
    let actionName: String
}

enum MarkdownInlineFormatter {
    static func plan(
        text nsText: NSString,
        targetRange: NSRange,
        style: MarkdownInlineStyle,
        tokens: [MarkdownToken]
    ) -> MarkdownInlineFormatPlan? {
        plan(text: nsText, targetRange: targetRange, style: style,
             index: EnclosingTokenIndex(tokens: tokens, style: style))
    }

    /// As above but reuses a prebuilt `EnclosingTokenIndex`. A caller formatting many
    /// runs (e.g. ⌘A) builds the index ONCE and pays O(log tokens) per run, instead of
    /// the old O(tokens) filter+min per run (the O(runs × tokens) freeze).
    static func plan(
        text nsText: NSString,
        targetRange: NSRange,
        style: MarkdownInlineStyle,
        index: EnclosingTokenIndex
    ) -> MarkdownInlineFormatPlan? {
        plans(text: nsText, targetRanges: [targetRange], style: style, index: index).first
    }

    /// One toggle over many runs (the ⌘A case), with the rule every native editor
    /// uses for a mixed selection: if EVERY run already carries `style`, the command
    /// removes it from all of them; otherwise it applies it to the runs that lack it
    /// and leaves the already-styled ones alone. Deciding per run instead inverted
    /// each run independently, so a document with one bold line never reached
    /// "all bold" or "all plain" — every press flipped the bold line the other way.
    /// Runs must be disjoint; the plans come back in the runs' order, at most one
    /// per run. Empty runs and unchanged rewrites yield no plan; selected
    /// whitespace participates in the same formatting decision.
    static func plans(
        text nsText: NSString,
        targetRanges: [NSRange],
        style: MarkdownInlineStyle,
        index: EnclosingTokenIndex
    ) -> [MarkdownInlineFormatPlan] {
        // Empty carets have no selection to format. Explicitly selected spaces
        // remain content: native formatting must retain their styles and selection.
        let runs: [Run] = targetRanges.compactMap { target in
            guard target.location != NSNotFound, target.location >= 0,
                  NSMaxRange(target) <= nsText.length else { return nil }
            guard target.length > 0 else { return nil }
            let trimmed = trimmedRange(target, in: nsText)
            let core = trimmed.length > 0 ? trimmed : target
            return Run(target: target, core: core, enclosing: index.smallestEnclosing(core))
        }
        let removeAll = !runs.isEmpty && runs.allSatisfy { index.coversStyle(in: $0.target) }

        // Disjoint by construction except when one token straddles two runs (a span
        // crossing a table cell's pipe): both would replace the same token range, so
        // the second is dropped rather than double-applied.
        var claimedEnd = 0
        return runs.compactMap { run -> MarkdownInlineFormatPlan? in
            guard let plan = plan(for: run, style: style, removeAll: removeAll, index: index, text: nsText),
                  plan.replacementRange.location >= claimedEnd,
                  nsText.substring(with: plan.replacementRange) != plan.replacement else { return nil }
            claimedEnd = NSMaxRange(plan.replacementRange)
            return completingBoundaryMarkers(in: plan)
        }
    }

    private static func completingBoundaryMarkers(in plan: MarkdownInlineFormatPlan) -> MarkdownInlineFormatPlan {
        let text = plan.replacement as NSString
        var start = plan.selectionAfter.location - plan.replacementRange.location
        var end = start + plan.selectionAfter.length
        guard start >= 0, end <= text.length, start < end else { return plan }
        let punctuation = "*_~=<>/".utf16
        guard punctuation.contains(text.character(at: start)) || punctuation.contains(text.character(at: end - 1)) else { return plan }
        let kinds: Set<MarkdownTokenKind> = [.bold, .italic, .boldItalic, .underline, .highlight, .strikethrough]
        let tokens = InlineASTAdapter.tokens(from: InlineParser.parse(plan.replacement))
        for marker in tokens.filter({ kinds.contains($0.kind) }).flatMap(\.markerRanges) {
            if marker.location < start && start < NSMaxRange(marker) { start = marker.location }
            if marker.location < end && end < NSMaxRange(marker) { end = NSMaxRange(marker) }
        }
        return MarkdownInlineFormatPlan(replacementRange: plan.replacementRange, replacement: plan.replacement,
            selectionAfter: NSRange(location: plan.replacementRange.location + start, length: end - start),
            actionName: plan.actionName)
    }

    private static func selectingVisibleContent(in plan: MarkdownInlineFormatPlan, style: MarkdownInlineStyle) -> MarkdownInlineFormatPlan {
        guard plan.replacement.contains("==") || plan.replacement.contains("~~") || plan.replacement.contains("<u>") else { return plan }
        let tokens = InlineASTAdapter.tokens(from: InlineParser.parse(plan.replacement))
        let markers = EnclosingTokenIndex(tokens: tokens, style: style)
        var start = plan.selectionAfter.location - plan.replacementRange.location
        var end = start + plan.selectionAfter.length
        guard start >= 0, end <= plan.replacement.utf16.count else { return plan }
        while start < end, markers.isMarker(at: start) { start += 1 }
        while end > start, markers.isMarker(at: end - 1) { end -= 1 }
        return MarkdownInlineFormatPlan(replacementRange: plan.replacementRange, replacement: plan.replacement,
            selectionAfter: NSRange(location: plan.replacementRange.location + start, length: end - start),
            actionName: plan.actionName)
    }

    /// One formatting run: the selected range, its whitespace-trimmed core, and the
    /// same-style span that already covers the core, if any.
    private struct Run {
        let target: NSRange
        let core: NSRange
        let enclosing: MarkdownToken?
    }

    private static func plan(
        for run: Run,
        style: MarkdownInlineStyle,
        removeAll: Bool,
        index: EnclosingTokenIndex,
        text nsText: NSString
    ) -> MarkdownInlineFormatPlan? {
        if let canonical = MarkdownInlineSelectionFormatting.plan(text: nsText, selection: run.target,
                style: style, tokens: index.styleTokens, removeStyle: removeAll,
                normalizeFragments: removeAll && run.enclosing == nil) { return canonical }
        guard let compact = compactPlan(for: run, style: style, removeAll: removeAll, index: index, text: nsText) else {
            return nil
        }
        return MarkdownInlineSelectionFormatting.validating(compact, text: nsText, selection: run.target,
            style: style, tokens: index.styleTokens, removeStyle: removeAll)
    }

    private static func compactPlan(for run: Run, style: MarkdownInlineStyle, removeAll: Bool,
                                    index: EnclosingTokenIndex, text nsText: NSString) -> MarkdownInlineFormatPlan? {
        if let token = run.enclosing {
            // Already styled. In remove mode `core` either sits INSIDE the token's
            // content (partial toggle: unbold the selected slice) or IS the whole
            // token incl. its markers (re-toggle of an already-styled run, e.g. ⌘A
            // then ⌘B again → run is `**X**`). Both collapse to the content slice
            // `core` covers — inside-content → `core`, whole-token → the whole
            // `contentRange` (so the markers get stripped → `X`) — i.e. their overlap.
            guard removeAll else { return nil }
            let removeCore = NSIntersectionRange(run.core, token.contentRange)
            return remove(style: style, from: removeCore, in: token,
                          innerToClean: index.matchingTokensInside(removeCore), index: index, text: nsText)
        }

        // No single same-style span encloses `core`. If `core` nonetheless CONTAINS
        // same-style spans (a mixed/partial selection — e.g. a ⌘A'd paragraph holding a
        // lone `**bold**` word, or `***both***`), wrapping it verbatim would NEST markers
        // (`**…**bold**…**`) and accumulate on every repeat — the runaway `****` / nested
        // `<u>***…` corruption. Strip those inner same-style markers first, then wrap the
        // cleaned run ONCE, so the next press finds the now-single enclosing span and
        // toggles it back off (idempotent + reversible).
        let inner = index.matchingTokensInside(run.core)
        return wrap(core: run.core, originalSelection: run.target, style: style,
                    innerToClean: inner, verifyMarkers: index.hasStrayDelimiter(in: run.core, text: nsText),
                    text: nsText)
    }

    static func trimmedRange(_ range: NSRange, in nsText: NSString) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        while start < end, isWhitespace(nsText.character(at: start)) {
            start += 1
        }
        while end > start, isWhitespace(nsText.character(at: end - 1)) {
            end -= 1
        }
        return NSRange(location: start, length: end - start)
    }

    /// `verifyMarkers`: the core holds a delimiter no span accounts for, so the
    /// wrapped form is parsed before it is used (see `resolvedMarkers`).
    private static func wrap(
        core: NSRange,
        originalSelection: NSRange,
        style: MarkdownInlineStyle,
        innerToClean: [MarkdownToken] = [],
        verifyMarkers: Bool = true,
        text nsText: NSString
    ) -> MarkdownInlineFormatPlan {
        let leading = NSRange(location: originalSelection.location, length: core.location - originalSelection.location)
        let trailing = NSRange(location: NSMaxRange(core), length: NSMaxRange(originalSelection) - NSMaxRange(core))
        let coreText = cleanedCoreText(core: core, style: style, innerToClean: innerToClean, text: nsText)
        let markers = verifyMarkers
            ? resolvedMarkers(for: style, around: coreText)
            : (open: style.openingMarker, close: style.closingMarker)
        let replacement = nsText.substring(with: leading)
            + markers.open
            + coreText
            + markers.close
            + nsText.substring(with: trailing)
        let ordered = orderedBoundaryWrappers(replacement)
        let plan = MarkdownInlineFormatPlan(
            replacementRange: originalSelection,
            replacement: ordered,
            selectionAfter: NSRange(
                location: core.location + markers.open.utf16.count,
                length: (coreText as NSString).length
            ),
            actionName: style.actionName
        )
        return ordered == replacement ? plan : selectingVisibleContent(in: plan, style: style)
    }

    /// The marker pair that makes `coreText` ONE `style` span to the parser. `**`/`*`
    /// unless the core holds a delimiter character the new markers would pair with
    /// instead of each other — a `**` the note never closed on this line (prose
    /// hard-wrapped through a bold span), a `*` closing an inner span right at the
    /// edge — so the parser reads `**listed**, the app was off.**` as a short bold
    /// plus a literal `**`. The candidate is checked by parsing it; when the star form
    /// does not cover the core, the underscore form (`__`/`_`, a different delimiter,
    /// so nothing pairs across) is tried. Without this the next press found no
    /// enclosing span and wrapped again, and that line could never be toggled off.
    /// Only a run with a STRAY delimiter (one no span's marker owns) is checked:
    /// matched spans at the edges (`x *both*` → `**x *both***`) pair correctly,
    /// and parsing every run of a ⌘A cost more than the whole rest of the plan.
    private static func resolvedMarkers(for style: MarkdownInlineStyle, around coreText: String) -> (open: String, close: String) {
        let star = (open: style.openingMarker, close: style.closingMarker)
        guard style == .bold || style == .italic,
              coreText.unicodeScalars.contains(where: { $0 == "*" || $0 == "_" }) else { return star }
        if parsesAsOneSpan(star.open + coreText + star.close, style: style) { return star }
        let underscore = style == .bold ? (open: "__", close: "__") : (open: "_", close: "_")
        if parsesAsOneSpan(underscore.open + coreText + underscore.close, style: style) { return underscore }
        return star
    }

    private static func parsesAsOneSpan(_ text: String, style: MarkdownInlineStyle) -> Bool {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        return InlineASTAdapter.tokens(from: InlineParser.parse(text)).contains {
            tokenMatches($0.kind, style: style) && NSEqualRanges($0.range, whole)
        }
    }

    /// `core`'s text with any inner SAME-STYLE markers stripped so the wrap can't nest:
    /// a bold strip on an inner `**x**` → `x`, on an inner `***x***` (bold-italic) → `*x*`
    /// (keeps the orthogonal italic); an orthogonal span (e.g. `*italic*` under a bold op)
    /// is left untouched. With no inner spans this is just the core substring (the plain
    /// wrap path). `innerToClean` is non-overlapping and ascending.
    private static func cleanedCoreText(
        core: NSRange,
        style: MarkdownInlineStyle,
        innerToClean: [MarkdownToken],
        text nsText: NSString
    ) -> String {
        guard !innerToClean.isEmpty else { return nsText.substring(with: core) }
        var result = ""
        var cursor = core.location
        for token in innerToClean where token.range.location >= cursor {
            result += nsText.substring(with: NSRange(location: cursor, length: token.range.location - cursor))
            result += demoted(nsText.substring(with: token.contentRange), removing: style, from: token.kind)
            cursor = NSMaxRange(token.range)
        }
        result += nsText.substring(with: NSRange(location: cursor, length: NSMaxRange(core) - cursor))
        return result
    }

    /// `innerToClean`: same-style spans nested inside `core` (`*a *b* c*` minus italic
    /// must leave nothing italic, as every native editor's toggle-off does), demoted
    /// along with the enclosing span.
    private static func remove(
        style: MarkdownInlineStyle,
        from core: NSRange,
        in token: MarkdownToken,
        innerToClean: [MarkdownToken] = [],
        index: EnclosingTokenIndex,
        text nsText: NSString
    ) -> MarkdownInlineFormatPlan {
        // `core` is `NSIntersectionRange(selection, token.contentRange)` from `plan`, so it
        // is always ⊆ `contentRange` — `before`/`after` below can't underflow.
        assert(rangeContains(token.contentRange, core))

        let contentStart = token.contentRange.location

        // A side remainder with no VISIBLE content — only nested emphasis
        // markers and whitespace — must be swallowed into the removal core,
        // never preserved as its own wrapped span. Preserving it re-wraps the
        // bare markers and orphans them from their content: toggling ⌘U off
        // on `<u>***18***</u>` with the core (`18`) selected — exactly the
        // selection each format apply leaves behind — produced
        // `<u>***</u>18<u>***</u>`, and every further ⌘U/⌘B/⌘I press
        // compounded the soup instead of toggling (field report 2026-07-03).
        var core = core
        let beforeCandidate = NSRange(location: contentStart, length: core.location - contentStart)
        if beforeCandidate.length > 0, index.containsOnlyMarkersAndWhitespace(in: beforeCandidate, text: nsText) {
            core = NSRange(location: contentStart, length: NSMaxRange(core) - contentStart)
        }
        let afterCandidate = NSRange(
            location: NSMaxRange(core),
            length: NSMaxRange(token.contentRange) - NSMaxRange(core)
        )
        if afterCandidate.length > 0, index.containsOnlyMarkersAndWhitespace(in: afterCandidate, text: nsText) {
            core = NSRange(location: core.location, length: NSMaxRange(token.contentRange) - core.location)
        }

        let before = NSRange(location: contentStart, length: core.location - contentStart)
        let after = NSRange(
            location: NSMaxRange(core),
            length: NSMaxRange(token.contentRange) - NSMaxRange(core)
        )

        let beforeText = nsText.substring(with: before)
        let coreText = cleanedCoreText(core: core, style: style, innerToClean: innerToClean, text: nsText)
        let afterText = nsText.substring(with: after)

        let splitBoldItalic = token.kind == .boldItalic && (before.length > 0 || after.length > 0)
        let sidePreferUnderscoreMarkers = splitBoldItalic && style == .italic
        let corePreferUnderscoreMarkers = splitBoldItalic && style == .bold
        let beforeReplacement = wrappedSegment(
            beforeText,
            preserving: token.kind,
            preferUnderscoreMarkers: sidePreferUnderscoreMarkers
        )
        let corePreservingStyle = stylePreservedOnRemovedCore(style: style, tokenKind: token.kind)
        let originalCoreReplacement = demoted(coreText, removing: style, from: token.kind,
                                      preferUnderscore: corePreferUnderscoreMarkers)
        let coreReplacement = orderedBoundaryWrappers(originalCoreReplacement)
        let afterReplacement = wrappedSegment(
            afterText,
            preserving: token.kind,
            preferUnderscoreMarkers: sidePreferUnderscoreMarkers
        )

        let replacement = beforeReplacement + coreReplacement + afterReplacement
        let selectionLocation = token.range.location
            + beforeReplacement.utf16.count
            + markerPrefixLength(for: corePreservingStyle)

        let plan = MarkdownInlineFormatPlan(
            replacementRange: token.range,
            replacement: replacement,
            selectionAfter: NSRange(location: selectionLocation, length: (coreText as NSString).length),
            actionName: style.actionName
        )
        return coreReplacement == originalCoreReplacement ? plan : selectingVisibleContent(in: plan, style: style)
    }

    /// Put punctuation-based containers outside emphasis so a preceding letter cannot
    /// turn `*==text==*` into literal stars. Only complete nested wrappers move;
    /// their combined width and every content offset remain unchanged.
    private static func orderedBoundaryWrappers(_ source: String) -> String {
        let text = source as NSString
        let core = trimmedRange(NSRange(location: 0, length: text.length), in: text)
        guard core.length > 0, [0x2A, 0x5F].contains(text.character(at: core.location)),
              source.contains("==") || source.contains("~~") || source.contains("<u>") else { return source }
        let tokens = InlineASTAdapter.tokens(from: InlineParser.parse(source))
        var range = core
        var wrappers: [(open: String, close: String, emphasis: Bool)] = []
        while let token = tokens.first(where: {
            $0.range == range && $0.markerRanges.count == 2
                && [.bold, .italic, .boldItalic, .underline, .highlight, .strikethrough].contains($0.kind)
        }), token.contentRange.length < range.length {
            wrappers.append((text.substring(with: token.markerRanges[0]),
                             text.substring(with: token.markerRanges[1]),
                             [.bold, .italic, .boldItalic].contains(token.kind)))
            range = token.contentRange
        }
        guard wrappers.contains(where: { $0.emphasis }), wrappers.contains(where: { !$0.emphasis }) else { return source }
        let ordered = wrappers.filter { !$0.emphasis } + wrappers.filter { $0.emphasis }
        return text.substring(to: core.location) + ordered.map(\.open).joined()
            + text.substring(with: range) + ordered.reversed().map(\.close).joined()
            + text.substring(from: NSMaxRange(core))
    }

    static func tokenMatches(_ kind: MarkdownTokenKind, style: MarkdownInlineStyle) -> Bool {
        switch style {
        case .bold:
            return kind == .bold || kind == .boldItalic
        case .italic:
            return kind == .italic || kind == .boldItalic
        case .underline:
            return kind == .underline
        case .strikethrough:
            return kind == .strikethrough
        case .highlight:
            return kind == .highlight
        }
    }

    private static func stylePreservedOnRemovedCore(
        style: MarkdownInlineStyle,
        tokenKind: MarkdownTokenKind
    ) -> MarkdownTokenKind? {
        switch (style, tokenKind) {
        case (.bold, .boldItalic):
            return .italic
        case (.italic, .boldItalic):
            return .bold
        default:
            return nil
        }
    }

    /// `content` with `style` removed from a span of `kind` — i.e. the survivor markup: the
    /// plain content when `kind` was exactly `style`, or the orthogonal emphasis when it was
    /// bold-italic (`***x***` minus bold → `*x*`). The single demotion primitive shared by the
    /// toggle-off path (`remove`) and the wrap-cleaning path (`cleanedCoreText`).
    private static func demoted(
        _ content: String,
        removing style: MarkdownInlineStyle,
        from kind: MarkdownTokenKind,
        preferUnderscore: Bool = false
    ) -> String {
        wrappedSegment(
            content,
            preserving: stylePreservedOnRemovedCore(style: style, tokenKind: kind),
            preferUnderscoreMarkers: preferUnderscore
        )
    }

    private static func wrappedSegment(
        _ text: String,
        preserving tokenKind: MarkdownTokenKind?,
        preferUnderscoreMarkers: Bool = false
    ) -> String {
        guard !text.isEmpty, let tokenKind else { return text }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let core = trimmedRange(fullRange, in: nsText)
        guard core.length > 0 else { return text }

        let leading = nsText.substring(with: NSRange(location: 0, length: core.location))
        let body = nsText.substring(with: core)
        let trailing = nsText.substring(with: NSRange(location: NSMaxRange(core), length: nsText.length - NSMaxRange(core)))

        switch tokenKind {
        case .bold:
            let marker = preferUnderscoreMarkers ? "__" : "**"
            return leading + marker + body + marker + trailing
        case .italic:
            let marker = preferUnderscoreMarkers ? "_" : "*"
            return leading + marker + body + marker + trailing
        case .boldItalic:
            let marker = preferUnderscoreMarkers ? "___" : "***"
            return leading + marker + body + marker + trailing
        case .underline:
            return leading + "<u>" + body + "</u>" + trailing
        case .strikethrough:
            return leading + "~~" + body + "~~" + trailing
        case .highlight:
            return leading + "==" + body + "==" + trailing
        default:
            return text
        }
    }

    private static func markerPrefixLength(for tokenKind: MarkdownTokenKind?) -> Int {
        guard let tokenKind else { return 0 }
        switch tokenKind {
        case .bold:
            return 2
        case .italic:
            return 1
        case .boldItalic:
            return 3
        case .underline:
            return 3
        case .strikethrough, .highlight:
            return 2
        default:
            return 0
        }
    }

    static func rangeContains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    private static func isWhitespace(_ value: unichar) -> Bool {
        guard let scalar = UnicodeScalar(Int(value)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }


}

/// Pre-built lookup for "the smallest emphasis token of a given style that encloses a
/// range". Built ONCE per formatting operation; each lookup is O(log tokens) via a
/// per-kind binary search. Same-kind emphasis spans are non-overlapping in CommonMark,
/// so within a kind the unique container of a point is the rightmost span starting
/// at/before it. (Replaces the old per-call `tokens.filter{…}.min{…}`, which was
/// O(tokens) per run → O(runs × tokens) on ⌘A.)
struct EnclosingTokenIndex {
    let styleTokens: [MarkdownToken]
    private let byKind: [MarkdownTokenKind: [MarkdownToken]]
    /// Every character position that is an emphasis marker of ANY style, so a
    /// `*`/`_` outside them is known to be literal.
    private let markerPositions: IndexSet
    private let styledPositions: IndexSet

    init(tokens: [MarkdownToken], style: MarkdownInlineStyle) {
        styleTokens = tokens.filter { [.bold, .italic, .boldItalic, .underline, .highlight, .strikethrough, .backslashEscape].contains($0.kind) }
        var groups: [MarkdownTokenKind: [MarkdownToken]] = [:]
        var markers = IndexSet()
        for token in tokens {
            if [.bold, .italic, .boldItalic, .underline, .highlight, .strikethrough, .backslashEscape].contains(token.kind) {
                for marker in token.markerRanges where marker.length > 0 {
                    markers.insert(integersIn: marker.location..<NSMaxRange(marker))
                }
            }
            if MarkdownInlineFormatter.tokenMatches(token.kind, style: style) {
                groups[token.kind, default: []].append(token)
            }
        }
        for kind in groups.keys {
            groups[kind]?.sort { $0.range.location < $1.range.location }
        }
        byKind = groups
        markerPositions = markers
        var styled = markers
        for token in groups.values.flatMap({ $0 }) {
            styled.insert(integersIn: token.contentRange.location..<NSMaxRange(token.contentRange))
        }
        styledPositions = styled
    }

    func coversStyle(in range: NSRange) -> Bool {
        let bounds = range.location..<NSMaxRange(range)
        return styledPositions.contains(integersIn: bounds) && !markerPositions.contains(integersIn: bounds)
    }

    /// Literal punctuation remains content even when it resembles a delimiter.
    func isMarker(at offset: Int) -> Bool { markerPositions.contains(offset) }

    func containsOnlyMarkersAndWhitespace(in range: NSRange, text: NSString) -> Bool {
        (range.location..<NSMaxRange(range)).allSatisfy { offset in
            markerPositions.contains(offset)
                || UnicodeScalar(Int(text.character(at: offset))).map {
                    CharacterSet.whitespacesAndNewlines.contains($0)
                } == true
        }
    }

    /// True when `range` holds a `*` or `_` that no emphasis span's marker owns —
    /// a literal delimiter the new markers could pair with.
    func hasStrayDelimiter(in range: NSRange, text: NSString) -> Bool {
        var i = range.location
        let end = NSMaxRange(range)
        while i < end {
            let c = text.character(at: i)
            if (c == 0x2A || c == 0x5F), !markerPositions.contains(i) { return true }
            i += 1
        }
        return false
    }

    /// The token that makes `range` already-styled, or nil. Across the ≤2 matching kinds,
    /// prefer the shortest span, then the rightmost — so toggle-off targets the inner span
    /// of nested emphasis.
    func smallestEnclosing(_ range: NSRange) -> MarkdownToken? {
        var best: MarkdownToken?
        for sorted in byKind.values {
            guard let candidate = Self.containing(range, in: sorted) else { continue }
            guard let current = best else { best = candidate; continue }
            if candidate.range.length < current.range.length
                || (candidate.range.length == current.range.length && candidate.range.location > current.range.location) {
                best = candidate
            }
        }
        return best
    }

    /// Same-style spans fully inside `range`, ascending by location. Used to strip inner
    /// markers before a wrap so ⌘A-ing a paragraph with existing emphasis can't nest or
    /// accumulate markers. Per-kind arrays are sorted, so each kind is O(log n + hits) via
    /// a lower-bound search — keeping ⌘A linear overall, not O(blocks × tokens).
    func matchingTokensInside(_ range: NSRange) -> [MarkdownToken] {
        let end = NSMaxRange(range)
        var hits: [MarkdownToken] = []
        for sorted in byKind.values {
            var lo = 0, hi = sorted.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if sorted[mid].range.location < range.location { lo = mid + 1 } else { hi = mid }
            }
            var i = lo
            while i < sorted.count, sorted[i].range.location < end {
                if NSMaxRange(sorted[i].range) <= end { hits.append(sorted[i]) }
                i += 1
            }
        }
        hits.sort { $0.range.location < $1.range.location }
        return hits
    }

    /// Within one non-overlapping, location-sorted kind, the token that makes `range`
    /// already-styled: either `range` sits inside its content (partial toggle) OR `range`
    /// IS the whole token incl. markers (`**X**` re-toggled). The only candidate is the
    /// rightmost token starting at/before `range`. A range that merely STARTS with a
    /// span and reaches past it (`**a:** *b c*` selected whole) is a mixed selection,
    /// not a styled one — treating it as styled made ⌘B strip that first span instead
    /// of bolding the line, and the toggle never converged.
    private static func containing(_ range: NSRange, in sorted: [MarkdownToken]) -> MarkdownToken? {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid].range.location <= range.location { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return nil }
        let candidate = sorted[lo - 1]
        if MarkdownInlineFormatter.rangeContains(candidate.contentRange, range) { return candidate }  // inside content
        if NSEqualRanges(candidate.range, range) { return candidate }                                  // the whole token
        return nil
    }
}
