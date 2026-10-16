//
//  TextStylingService.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Applies base text styling and refreshes only changed sections so editing
// stays smooth while Markdown formatting updates.
import AppKit
import Foundation

struct TextStylingService {
    static func makeBaseTypingAttributes(
        font: NSFont,
        paragraphStyle: NSParagraphStyle,
        theme: MarkdownEditorTheme = .default
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: theme.bodyText,
            .paragraphStyle: paragraphStyle
        ]
    }

    static func makeBaseFontAndStyle(
        fontName: String,
        fontSize: CGFloat,
        layoutBridge: LayoutBridge? = nil,
        configuration: MarkdownEditorConfiguration = .default
    ) -> (font: NSFont, style: NSMutableParagraphStyle) {
        let baseFont = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        let defaultLineHeight = layoutBridgeDefaultLineHeight(for: baseFont, using: layoutBridge)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = ceil(defaultLineHeight) + configuration.paragraph.lineHeightExtraSpacing
        paragraph.lineSpacing = 0
        let baseParagraphSpacing = ceil(defaultLineHeight * configuration.paragraph.spacingFactor)
        paragraph.paragraphSpacing = baseParagraphSpacing
        paragraph.paragraphSpacingBefore = 0
        paragraph.lineBreakMode = .byWordWrapping
        // 24 explicit tab stops at indentPerLevel intervals, then natural wrap.
        let perLevel = configuration.lists.indentPerLevel
        paragraph.tabStops = (1...24).map { NSTextTab(textAlignment: .left, location: CGFloat($0) * perLevel) }
        paragraph.defaultTabInterval = 0
        return (baseFont, paragraph)
    }

    static func restyle(
        textView: NSTextView,
        layoutBridge: LayoutBridge?,
        paragraphCandidates: [NSRange],
        baseFont: NSFont,
        paragraphStyle: NSMutableParagraphStyle,
        caretLocation: Int,
        activeTokenIndices: Set<Int>,
        wikiLinkIDProvider: @escaping (NSRange) -> String?,
        precomputedTokens: [MarkdownToken]? = nil,
        text: String? = nil,
        configuration: MarkdownEditorConfiguration = .default
    ) {
        var paragraphs: [NSRange] = []
        PerfTrace.time("svc.normalize") { paragraphs = normalize(paragraphCandidates) }

        PerfTrace.time("svc.typingAttrs") {
        textView.typingAttributes = makeBaseTypingAttributes(
            font: baseFont,
            paragraphStyle: paragraphStyle,
            theme: configuration.theme
        )
        }

        guard !paragraphs.isEmpty else {
            textView.setNeedsDisplay(textView.visibleRect)
            return
        }

        let text = text ?? textView.string
        var styledRanges: [StyledRange] = []
        PerfTrace.time("svc.compute") {
        styledRanges = MarkdownStyler.styleAttributes(
            text: text,
            fontName: baseFont.fontName,
            fontSize: baseFont.pointSize,
            layoutBridge: layoutBridge,
            caretLocation: caretLocation,
            activeTokenIndices: activeTokenIndices,
            wikiLinkIDProvider: wikiLinkIDProvider,
            precomputedTokens: precomputedTokens,
            scopedRanges: paragraphs,
            configuration: configuration
        )
        }

        var spellingDisabledRanges: [NSRange] = []
        PerfTrace.time("svc.collectSpelling") {
        spellingDisabledRanges = styledRanges.compactMap { (range, attrs) -> NSRange? in
            attrs[.spellingState] as? Int == 0 ? range : nil
        }
        }

        // Remove existing spelling markers before reapplying disabled ranges.
        PerfTrace.time("svc.spellingTemp") {
        for disabledRange in spellingDisabledRanges {
            layoutBridge?.removeTemporaryAttribute(.spellingState, forCharacterRange: disabledRange)
        }
        }

        // A restyle can land while an IME composition is active (async
        // callbacks, font/theme changes). `setAttributes` over the marked
        // range would destroy the composition's underline/clause attributes
        // and desync the input context — carve it out; the commit reconciles
        // its final attributes.
        let markedRange: NSRange = textView.hasMarkedText()
            ? textView.markedRange()
            : NSRange(location: NSNotFound, length: 0)

        // One beginEditing/endEditing batch per CONTIGUOUS cluster of paragraphs.
        // NSTextStorage reports a single edited range per batch — the hull of
        // every write in it — and TextKit 2 invalidates layout for that hull:
        // a caret move between two blocks 6 000 characters apart, batched
        // together, threw every paragraph between them back to estimates (68
        // fragments on a 71 KB note, the rest of the document on a 490 KB one
        // whose caret sat at the end after opening), and their re-estimated
        // heights moved the content under the viewport on the next pass.
        let clusters = contiguousClusters(of: paragraphs)
        PerfTrace.time("svc.write") {
        for cluster in clusters {
            let hull = cluster.dropFirst().reduce(cluster[0]) { NSUnionRange($0, $1) }
            textView.textStorage?.beginEditing()
            for disabledRange in spellingDisabledRanges where NSIntersectionRange(disabledRange, hull).length > 0 {
                textView.textStorage?.addAttribute(.spellingState, value: 0, range: NSIntersectionRange(disabledRange, hull))
            }
            for paragraph in cluster {
                for wipe in subtract(markedRange, from: paragraph) {
                    textView.textStorage?.setAttributes([
                        .font: baseFont,
                        .foregroundColor: configuration.theme.bodyText,
                        .paragraphStyle: paragraphStyle
                    ], range: wipe)
                    textView.textStorage?.removeAttribute(.link, range: wipe)
                }
                for (range, attrs) in styledRanges where NSIntersectionRange(range, paragraph).length > 0 {
                    let clippedRange = NSIntersectionRange(range, paragraph)
                    for (key, value) in attrs {
                        textView.textStorage?.addAttribute(key, value: value, range: clippedRange)
                    }
                }
            }
            PerfTrace.time("svc.endEditing") { textView.textStorage?.endEditing() }
        }
        }
        // No ensureLayout here:
        PerfTrace.time("svc.display") { textView.setNeedsDisplay(textView.visibleRect) }
        PerfTrace.time("svc.ensureVisible") { (textView as? NativeTextView)?.ensureVisibleLayout() }
    }

    /// The styled ranges flattened into non-overlapping runs in document order,
    /// each carrying `base` plus every styled attribute that covers it (a later
    /// range wins for the same key, exactly as applying the ranges in order with
    /// `addAttribute` would). Applying these with one `setAttributes` per run is
    /// what a whole-note rebuild needs: the per-key `addAttribute` loop over
    /// tens of thousands of ranges in arbitrary order cost 2.5 s of a 4.7 s open
    /// on a 490 KB note.
    static func flattenedRuns(
        _ ranges: [StyledRange],
        base: [NSAttributedString.Key: Any],
        length: Int
    ) -> [(range: NSRange, attributes: [NSAttributedString.Key: Any])] {
        struct Event { let position: Int; let index: Int; let starts: Bool }
        var events: [Event] = []
        events.reserveCapacity(ranges.count * 2)
        for (index, styled) in ranges.enumerated() {
            let start = max(0, styled.range.location)
            let end = min(length, NSMaxRange(styled.range))
            guard start < end else { continue }
            events.append(Event(position: start, index: index, starts: true))
            events.append(Event(position: end, index: index, starts: false))
        }
        guard !events.isEmpty else { return [] }
        // Ends before starts at the same position so a zero-width gap never
        // carries a range that ended there.
        events.sort { $0.position != $1.position ? $0.position < $1.position : (!$0.starts && $1.starts) }

        var runs: [(range: NSRange, attributes: [NSAttributedString.Key: Any])] = []
        var active: [Int] = []          // styled-range indices, ascending
        var cursor = events[0].position
        var eventIndex = 0
        while eventIndex < events.count {
            let position = events[eventIndex].position
            if position > cursor, !active.isEmpty {
                var merged = base
                for index in active {
                    for (key, value) in ranges[index].attributes { merged[key] = value }
                }
                runs.append((NSRange(location: cursor, length: position - cursor), merged))
            }
            while eventIndex < events.count, events[eventIndex].position == position {
                let event = events[eventIndex]
                if event.starts {
                    let insertAt = active.firstIndex { $0 > event.index } ?? active.count
                    active.insert(event.index, at: insertAt)
                } else if let at = active.firstIndex(of: event.index) {
                    active.remove(at: at)
                }
                eventIndex += 1
            }
            cursor = position
        }
        return runs
    }

    /// Paragraph ranges grouped into runs that touch or overlap, in document order.
    static func contiguousClusters(of paragraphs: [NSRange]) -> [[NSRange]] {
        var clusters: [[NSRange]] = []
        for paragraph in paragraphs.sorted(by: { $0.location < $1.location }) {
            if let last = clusters.last?.last, paragraph.location <= NSMaxRange(last) {
                clusters[clusters.count - 1].append(paragraph)
            } else {
                clusters.append([paragraph])
            }
        }
        return clusters
    }

    /// `range` minus `hole` (0–2 pieces). Keeps destructive attribute wipes
    /// off the live IME composition.
    private static func subtract(_ hole: NSRange, from range: NSRange) -> [NSRange] {
        guard hole.location != NSNotFound else { return [range] }
        let intersection = NSIntersectionRange(range, hole)
        guard intersection.length > 0 else { return [range] }
        var parts: [NSRange] = []
        if intersection.location > range.location {
            parts.append(NSRange(location: range.location, length: intersection.location - range.location))
        }
        if NSMaxRange(range) > NSMaxRange(intersection) {
            parts.append(NSRange(
                location: NSMaxRange(intersection),
                length: NSMaxRange(range) - NSMaxRange(intersection)
            ))
        }
        return parts
    }

    private static func normalize(_ candidates: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for candidate in candidates where candidate.location != NSNotFound && candidate.length > 0 {
            if result.contains(where: { $0.location == candidate.location && $0.length == candidate.length }) {
                continue
            }
            result.append(candidate)
        }
        return result
    }

    /// Convert an NSRange into an NSTextRange for use with NSTextLayoutManager.
    static func textRange(from range: NSRange, in contentStorage: NSTextContentStorage) -> NSTextRange? {
        let docStart = contentStorage.documentRange.location
        guard let start = contentStorage.location(docStart, offsetBy: range.location),
              let end = contentStorage.location(start, offsetBy: range.length) else {
            return nil
        }
        return NSTextRange(location: start, end: end)
    }
}
