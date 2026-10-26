//
//  NativeTextViewCoordinator+PlainTextFastPath.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  The typing-hot-path fast lanes lifted out of `+TextDelegate.swift`: the
//  plain-text insertion fast path (ordinary prose typing that skips the full
//  `tv.string` bridge and the Markdown reparse) and the inline-formatting edit
//  fast path (a locally re-tokenized band merged into the cached parse). Both
//  fall back to the scoped restyle path in `+TextDelegate.swift` the moment an
//  edit could affect Markdown syntax or block structure.
//

import AppKit

extension NativeTextViewCoordinator {

    /// Cheap path for ordinary prose insertion. It avoids both the full-string
    /// `tv.string` bridge and Markdown parsing; syntax-affecting edits fall
    /// back to the normal scoped restyle path, which reparses the current text.
    func tryPlainTextEditFastPath(
        textView tv: NSTextView,
        text: NSString,
        selectionRange: NSRange,
        editedRange: NSRange
    ) -> Bool {
        guard !isWritingToolsActive,
              let change = pendingTextChange,
              let parsed = cachedParsedDocument
        else {
            return false
        }

        let isPlainInsertion = isFastPlainInsertion(change, in: text)
        let plainNewlineFastPath = isPlainNewlineInsertion(change, in: text, parsed: parsed)
        let preEditActiveTokenIndices = pendingPreEditActiveTokenIndices ?? previousActiveTokenIndices
        let activePlainInsertion = isPlainInsertion && canFastTrackActivePlainInsertion(
            change,
            activeTokenIndices: preEditActiveTokenIndices,
            parsed: parsed
        )
        guard (isPlainInsertion || plainNewlineFastPath),
              (!pendingEditMayChangeBlockStructure || plainNewlineFastPath),
              !pendingEditRequiresFullDocumentRestyle,
              (preEditActiveTokenIndices.isEmpty || activePlainInsertion)
        else {
            return false
        }

        if activePlainInsertion {
            advancePlainFastPathExpansion(
                insertionLocation: change.oldRange.location,
                delta: change.delta,
                activeTokenIndices: preEditActiveTokenIndices
            )
        }
        recordPlainInsertion(change)

        activeTokenIndices = activePlainInsertion ? preEditActiveTokenIndices : []
        isImageEmbedActive = false
        updateAutocorrectSettingsForPlainFastPath(
            tv,
            activePlainInsertion: activePlainInsertion,
            activeTokenIndices: activeTokenIndices,
            tokens: parsed.tokens
        )
        if activePlainInsertion {
            applyFastInsertedTextAttributes(
                textView: tv,
                insertedRange: NSRange(location: change.oldRange.location, length: change.replacementLength),
                tokens: parsed.tokens,
                activeTokenIndices: activeTokenIndices
            )
        }

        if let bottomTextView = tv as? NativeTextView,
           let scrollView = tv.enclosingScrollView {
            codeBlockSelectionGeneration &+= 1
            bottomTextView.refreshOverscrollAfterTextEdit(for: scrollView, scheduleExactMeasure: false)
            (scrollView as? ClampedScrollView)?.clampToInsets()
        }

        previousActiveTokenIndices = activeTokenIndices
        previousCaretLocation = selectionRange.location
        skipNextSelectionChangeAfterPlainEdit = true
        return true
    }

    /// Keeps the parse key current through plain typing: the typed text goes
    /// into the cached source and the insertion is remembered, so the next
    /// caller that needs tokens (a click, Find, a deferred chunk) rebases them
    /// rather than re-parsing the whole note (half a second at 5 MB, D12).
    ///
    /// Typing beside a syntax character drops the cache instead: emphasis and
    /// the like depend on the characters beside their delimiters, so the
    /// insertion can make or break a span no cached token marks.
    private func recordPlainInsertion(_ change: TextChange) {
        guard let source = cachedParsedChars else { return }
        let count = source.count
        let location = change.oldRange.location
        guard location <= count,
              location == 0 || !Self.isInlineSyntax(source[location - 1]),
              location == count || !Self.isInlineSyntax(source[location]) else {
            cachedParsedChars = nil
            return
        }
        let typed = Array(change.replacement.utf16)
        // In place, with one memmove: `replaceSubrange` moved the tail unit by
        // unit in a debug build (about 100 ms a keystroke on a 2 MB note).
        cachedParsedChars?.append(contentsOf: typed)
        cachedParsedChars?.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            memmove(base + location + typed.count, base + location, (count - location) * MemoryLayout<UInt16>.stride)
            typed.withUnsafeBufferPointer { memcpy(base + location, $0.baseAddress!, typed.count * MemoryLayout<UInt16>.stride) }
        }
        if let last = plainInsertionsSinceParse.last, NSMaxRange(last) == location {
            plainInsertionsSinceParse[plainInsertionsSinceParse.count - 1].length += change.replacementLength
        } else {
            plainInsertionsSinceParse.append(NSRange(location: location, length: change.replacementLength))
        }
    }

    /// `parsed` moved past the plain insertions typed since it was made, or
    /// nil when one touches a token's edge or markers: typing against inline
    /// syntax can change it (an autolink grows, intraword `_` stops being
    /// emphasis), and only a real parse knows. A heading or quote line only
    /// grows at its end.
    func parsedDocumentRebasedForPlainInsertions(_ parsed: ParsedDocument) -> ParsedDocument? {
        // One pass, every insertion applied to each token in typing order:
        // a pass per insertion re-allocated every token each time.
        var rebased: [MarkdownToken] = []
        rebased.reserveCapacity(parsed.tokens.count)
        for token in parsed.tokens {
            var range = token.range
            var content = token.contentRange
            var markers = token.markerRanges
            for insertion in plainInsertionsSinceParse {
                let location = insertion.location
                let touchesSyntax = range.location == location
                    || (NSMaxRange(range) == location && token.kind != .heading && token.kind != .blockquote)
                    || markers.contains { location > $0.location && location < NSMaxRange($0) }
                if touchesSyntax { return nil }
                range = rangeAfterPlainInsertion(range, at: location, delta: insertion.length, expandAtStart: false)
                content = rangeAfterPlainInsertion(content, at: location, delta: insertion.length, expandAtStart: true)
                for index in markers.indices where markers[index].location >= location {
                    markers[index].location += insertion.length
                }
            }
            rebased.append(MarkdownToken(kind: token.kind, range: range, contentRange: content, markerRanges: markers))
        }
        return parsedDocument(from: rebased)
    }

    private func isFastPlainInsertion(_ change: TextChange, in text: NSString) -> Bool {
        guard change.oldRange.length == 0,
              change.delta > 0,
              !change.replacement.isEmpty,
              change.replacement.utf16.count <= 64,
              !replacementContainsMarkdownSyntax(change.replacement)
        else {
            return false
        }
        if change.replacement.contains(" "),
           spaceCouldCompleteBlockSyntax(at: change.oldRange.location, in: text) {
            return false
        }
        return true
    }

    private func replacementContainsMarkdownSyntax(_ replacement: String) -> Bool {
        for scalar in replacement.unicodeScalars {
            switch scalar {
            case "\n", "\r", "\t":
                return true
            default:
                if scalar.isASCII, Self.isInlineSyntax(UInt16(scalar.value)) { return true }
            }
        }
        return false
    }

    /// The characters Markdown syntax is made of (`# * _ ` [ ] ( ) ! $ ~ | > \ <`).
    static func isInlineSyntax(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x23, 0x2A, 0x5F, 0x60, 0x5B, 0x5D, 0x28, 0x29, 0x21, 0x24, 0x7E, 0x7C, 0x3E, 0x5C, 0x3C:
            return true
        default:
            return false
        }
    }

    private func canFastTrackActivePlainInsertion(
        _ change: TextChange,
        activeTokenIndices: Set<Int>,
        parsed: ParsedDocument
    ) -> Bool {
        guard !activeTokenIndices.isEmpty,
              change.oldRange.length == 0,
              change.delta > 0
        else {
            return false
        }

        let location = change.oldRange.location
        var insertsIntoStyledContent = false
        for index in activeTokenIndices {
            guard index >= 0, index < parsed.tokens.count else { return false }
            let token = tokenAdjustedForPlainFastPath(parsed.tokens[index], index: index)
            guard canFastExtendPlainText(in: token.kind) else { return false }
            if token.markerRanges.contains(where: { NSLocationInRange(location, $0) }) {
                return false
            }
            if location >= token.contentRange.location,
               location <= NSMaxRange(token.contentRange) {
                insertsIntoStyledContent = true
            }
        }
        return insertsIntoStyledContent
    }

    private func canFastExtendPlainText(in kind: MarkdownTokenKind) -> Bool {
        switch kind {
        case .bold, .italic, .boldItalic, .underline, .strikethrough, .highlight, .heading, .inlineCode:
            return true
        default:
            return false
        }
    }

    private func advancePlainFastPathExpansion(
        insertionLocation: Int,
        delta: Int,
        activeTokenIndices: Set<Int>
    ) {
        if let pending = pendingPlainFastPathExpansion,
           pending.activeTokenIndices == activeTokenIndices,
           insertionLocation >= pending.insertionLocation {
            pendingPlainFastPathExpansion = PlainFastPathExpansion(
                insertionLocation: pending.insertionLocation,
                delta: pending.delta + delta,
                activeTokenIndices: activeTokenIndices
            )
        } else {
            pendingPlainFastPathExpansion = PlainFastPathExpansion(
                insertionLocation: insertionLocation,
                delta: delta,
                activeTokenIndices: activeTokenIndices
            )
        }
    }

    private func tokenAdjustedForPlainFastPath(_ token: MarkdownToken, index: Int) -> MarkdownToken {
        guard let pending = pendingPlainFastPathExpansion,
              pending.activeTokenIndices.contains(index) else {
            return token
        }
        return tokenAfterPlainInsertion(
            token,
            at: pending.insertionLocation,
            delta: pending.delta
        )
    }

    private func tokenAfterPlainInsertion(
        _ token: MarkdownToken,
        at location: Int,
        delta: Int
    ) -> MarkdownToken {
        MarkdownToken(
            kind: token.kind,
            range: rangeAfterPlainInsertion(token.range, at: location, delta: delta, expandAtStart: false),
            contentRange: rangeAfterPlainInsertion(token.contentRange, at: location, delta: delta, expandAtStart: true),
            markerRanges: token.markerRanges.map {
                $0.location >= location ? NSRange(location: $0.location + delta, length: $0.length) : $0
            }
        )
    }

    private func fastStyleActiveTokens(
        activeTokenIndices: Set<Int>,
        tokens: [MarkdownToken]
    ) -> [MarkdownToken] {
        var activeTokens: [MarkdownToken] = []
        activeTokens.reserveCapacity(activeTokenIndices.count)
        for index in activeTokenIndices {
            guard index >= 0, index < tokens.count else { continue }
            let token = tokenAdjustedForPlainFastPath(tokens[index], index: index)
            guard canFastExtendPlainText(in: token.kind) else { continue }
            activeTokens.append(token)
        }
        return activeTokens
    }

    private func updateAutocorrectSettingsForPlainFastPath(
        _ textView: NSTextView,
        activePlainInsertion: Bool,
        activeTokenIndices: Set<Int>,
        tokens: [MarkdownToken]
    ) {
        guard activePlainInsertion else {
            if cachedSpellingDisabled != false {
                applyAutocorrectSettings(textView, shouldDisableSpelling: false)
            }
            return
        }

        let shouldDisableSpelling = activeTokenIndices.contains { index in
            guard index >= 0, index < tokens.count else { return false }
            return tokens[index].kind == .inlineCode
        }
        applyAutocorrectSettings(textView, shouldDisableSpelling: shouldDisableSpelling)
    }

    func prepareTypingAttributesForPlainFastPath(
        textView: NSTextView,
        text: NSString,
        affectedCharRange: NSRange,
        replacement: String,
        parsed: ParsedDocument?
    ) {
        guard let parsed,
              affectedCharRange.length == 0,
              let textStorage = textView.textStorage
        else {
            return
        }
        let change = TextChange(oldRange: affectedCharRange, replacement: replacement)
        let activeIndices = pendingPreEditActiveTokenIndices ?? previousActiveTokenIndices
        guard isFastPlainInsertion(change, in: text),
              canFastTrackActivePlainInsertion(
                change,
                activeTokenIndices: activeIndices,
                parsed: parsed
              ),
              let sampleLocation = fastStyleSampleLocation(
                for: NSRange(location: affectedCharRange.location, length: 0),
                tokens: parsed.tokens,
                activeTokenIndices: activeIndices,
                textLength: textStorage.length
              )
        else {
            return
        }
        textView.typingAttributes = textStorage.attributes(at: sampleLocation, effectiveRange: nil)
    }

    private func isPlainNewlineInsertion(_ change: TextChange, in text: NSString, parsed: ParsedDocument) -> Bool {
        guard change.oldRange.length == 0,
              change.delta > 0,
              change.replacementLength <= 2,
              change.replacement.unicodeScalars.allSatisfy({ $0 == "\n" || $0 == "\r" }),
              change.oldRange.location >= 0,
              change.oldRange.location <= text.length
        else {
            return false
        }

        let localWindow = newlineLocalWindow(
            in: text,
            insertedAt: change.oldRange.location,
            insertedLength: change.replacementLength
        )
        guard localWindow.location != NSNotFound,
              localWindow.length > 0,
              newlineLocalWindowLooksPlain(in: text, range: localWindow)
        else {
            return false
        }

        for token in parsed.tokens {
            guard let shiftedRange = rangeAfterInsertionIfUntouched(
                token.range,
                insertionLocation: change.oldRange.location,
                delta: change.delta
            ) else {
                return false
            }
            if NSIntersectionRange(shiftedRange, localWindow).length > 0 {
                return false
            }
        }
        return true
    }

    private func newlineLocalWindow(in text: NSString, insertedAt location: Int, insertedLength: Int) -> NSRange {
        guard text.length > 0 else { return NSRange(location: NSNotFound, length: 0) }

        let beforeProbe = min(max(location > 0 ? location - 1 : location, 0), max(text.length - 1, 0))
        let beforeParagraph = text.paragraphRange(for: NSRange(location: beforeProbe, length: 0))

        let afterProbe = min(max(location + insertedLength, 0), text.length)
        let afterParagraph: NSRange
        if afterProbe < text.length {
            afterParagraph = text.paragraphRange(for: NSRange(location: afterProbe, length: 0))
        } else {
            afterParagraph = NSRange(location: afterProbe, length: 0)
        }

        let start = min(beforeParagraph.location, afterParagraph.location)
        let end = max(NSMaxRange(beforeParagraph), NSMaxRange(afterParagraph))
        guard start >= 0, end >= start, end <= text.length else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: start, length: end - start)
    }

    private func newlineLocalWindowLooksPlain(in text: NSString, range: NSRange) -> Bool {
        guard range.location != NSNotFound,
              NSMaxRange(range) <= text.length
        else {
            return false
        }

        let fragment = text.substring(with: range)
        return fragment.split(whereSeparator: \.isNewline).allSatisfy { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return true }
            if line.unicodeScalars.contains(where: isMarkdownSyntaxScalarForPlainNewline) {
                return false
            }
            return !startsWithOrderedListMarker(line)
        }
    }

    private func isMarkdownSyntaxScalarForPlainNewline(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "#", "*", "_", "`", "[", "]", "(", ")", "!", "$", "~", "|", ">", "\\", "<", "-", "+":
            return true
        default:
            return false
        }
    }

    private func startsWithOrderedListMarker(_ line: String) -> Bool {
        let scalars = Array(line.unicodeScalars)
        guard let first = scalars.first,
              CharacterSet.decimalDigits.contains(first)
        else {
            return false
        }

        var index = 0
        while index < scalars.count,
              CharacterSet.decimalDigits.contains(scalars[index]) {
            index += 1
        }
        guard index < scalars.count,
              scalars[index] == "." || scalars[index] == ")"
        else {
            return false
        }
        index += 1
        return index == scalars.count || CharacterSet.whitespaces.contains(scalars[index])
    }

    private func rangeAfterInsertionIfUntouched(_ range: NSRange, insertionLocation: Int, delta: Int) -> NSRange? {
        if NSMaxRange(range) <= insertionLocation {
            return range
        }
        if range.location >= insertionLocation {
            return NSRange(location: range.location + delta, length: range.length)
        }
        return nil
    }

    func tryInlineFormattingEditFastPath(
        textView tv: NSTextView,
        text: NSString,
        selectionRange: NSRange,
        editedRange: NSRange
    ) -> Bool {
        guard !isWritingToolsActive,
              let change = pendingTextChange,
              let parsed = cachedParsedDocument,
              pendingPlainFastPathExpansion == nil,
              !change.replacement.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" })
        else {
            return false
        }

        let paragraphs = paragraphRanges(in: text, intersecting: editedRange)
        guard let region = union(paragraphs),
              region.location != NSNotFound,
              region.length > 0 else {
            return false
        }

        let oldRegion = NSRange(location: region.location, length: region.length - change.delta)
        guard oldRegion.length >= 0 else { return false }
        let oldRegionEnd = NSMaxRange(oldRegion)
        for token in parsed.tokens {
            if tokenStraddlesCut(token.range, cut: oldRegion.location)
                || tokenStraddlesCut(token.range, cut: oldRegionEnd) {
                return false
            }
        }

        let localTokens = localMarkdownTokens(in: text, range: region)
        var merged: [MarkdownToken] = []
        merged.reserveCapacity(parsed.tokens.count + localTokens.count)
        for token in parsed.tokens where NSMaxRange(token.range) <= oldRegion.location {
            merged.append(token)
        }
        merged.append(contentsOf: localTokens)
        for token in parsed.tokens where token.range.location >= oldRegionEnd {
            merged.append(shift(token, by: change.delta))
        }

        let nextParsed = parsedDocument(from: merged)
        cachedParsedDocument = nextParsed
        cachedParsedChars = nil
        cachedCodeBlockTokens = merged.enumerated()
            .filter { $0.element.kind == .codeBlock }
            .map { (index: $0.offset, token: $0.element) }

        let preEditActiveTokenIndices = pendingPreEditActiveTokenIndices ?? previousActiveTokenIndices
        activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: selectionRange,
            tokens: merged,
            in: text,
            suppressed: !tv.isEditable
        )
        filterImageEmbedActiveTokens(parsed: nextParsed, text: text, selectionLocation: selectionRange.location)
        updateAutocorrectSettings(
            tv,
            caretLocation: selectionRange.location,
            codeTokens: nextParsed.codeTokens,
            latexTokens: nextParsed.latexTokens,
            allTokens: merged
        )

        var effectiveParagraphs = paragraphs
        effectiveParagraphs.append(contentsOf: tokenRestyleParagraphs(
            in: text,
            tokens: merged,
            currentActiveTokenIndices: activeTokenIndices,
            previousActiveTokenIndices: preEditActiveTokenIndices
        ))
        let documentText = text as String
        // A format toggle near a banded block (wide table, block LaTeX,
        // image embed, rendered diagram) can re-band it and shift layout
        // height — anchor the viewport.
        let anchorViewport = merged.contains {
            MarkdownTokenKind.isHeightBanded($0, in: documentText, diagramLanguages: configuration.diagramLanguages)
        }
        restyle(tv, paragraphCandidates: effectiveParagraphs, tokens: merged, text: documentText, anchoringViewport: anchorViewport)
        scheduleCodeBlockSelectionUpdate(textView: tv, tokens: merged)

        if let bottomTextView = tv as? NativeTextView,
           let scrollView = tv.enclosingScrollView {
            bottomTextView.refreshOverscrollAfterTextEdit(for: scrollView, scheduleExactMeasure: false)
            (scrollView as? ClampedScrollView)?.clampToInsets()
        }

        previousActiveTokenIndices = activeTokenIndices
        previousCaretLocation = selectionRange.location
        return true
    }

    private func union(_ ranges: [NSRange]) -> NSRange? {
        var result: NSRange?
        for range in ranges where range.location != NSNotFound {
            result = result.map { NSUnionRange($0, range) } ?? range
        }
        return result
    }

    private func tokenStraddlesCut(_ range: NSRange, cut: Int) -> Bool {
        range.location < cut && NSMaxRange(range) > cut
    }

    private func localMarkdownTokens(in text: NSString, range: NSRange) -> [MarkdownToken] {
        let substring = text.substring(with: range)
        let nsSubstring = substring as NSString
        let blocks = BlockParser.parse(substring, memoizing: false)
        var tokens: [MarkdownToken] = []
        for block in blocks {
            let blockText = nsSubstring.substring(with: block.range)
            let localBlockTokens = BlockLevelTokenizer.tokens(for: block.kind, in: blockText as NSString)
            let localInlineTokens = block.kind == .fencedCode
                ? []
                : InlineASTAdapter.tokens(from: InlineParser.parse(blockText))
            let delta = range.location + block.range.location
            tokens.append(contentsOf: (localBlockTokens + localInlineTokens).map { shift($0, by: delta) })
        }
        return tokens
    }

    private func shift(_ token: MarkdownToken, by delta: Int) -> MarkdownToken {
        func move(_ range: NSRange) -> NSRange {
            NSRange(location: range.location + delta, length: range.length)
        }
        return MarkdownToken(
            kind: token.kind,
            range: move(token.range),
            contentRange: move(token.contentRange),
            markerRanges: token.markerRanges.map(move)
        )
    }

    private func rangeAfterPlainInsertion(
        _ range: NSRange,
        at location: Int,
        delta: Int,
        expandAtStart: Bool
    ) -> NSRange {
        if range.location > location || (!expandAtStart && range.location == location) {
            return NSRange(location: range.location + delta, length: range.length)
        }
        let end = NSMaxRange(range)
        if location > range.location && location < end
            || (expandAtStart && location == range.location)
            || location == end {
            return NSRange(location: range.location, length: range.length + delta)
        }
        return range
    }

    private func applyFastInsertedTextAttributes(
        textView: NSTextView,
        insertedRange: NSRange,
        tokens: [MarkdownToken],
        activeTokenIndices: Set<Int>
    ) {
        guard insertedRange.length > 0,
              let textStorage = textView.textStorage,
              NSMaxRange(insertedRange) <= textStorage.length,
              let sampleLocation = fastStyleSampleLocation(
                for: insertedRange,
                tokens: tokens,
                activeTokenIndices: activeTokenIndices,
                textLength: textStorage.length
              )
        else {
            return
        }

        let attributes = textStorage.attributes(at: sampleLocation, effectiveRange: nil)
        let currentAttributes = textStorage.attributes(at: insertedRange.location, effectiveRange: nil)
        if NSDictionary(dictionary: currentAttributes).isEqual(to: attributes) {
            return
        }
        textStorage.beginEditing()
        textStorage.setAttributes(attributes, range: insertedRange)
        textStorage.endEditing()
        textView.setNeedsDisplay(textView.visibleRect)
    }

    private func fastStyleSampleLocation(
        for insertedRange: NSRange,
        tokens: [MarkdownToken],
        activeTokenIndices: Set<Int>,
        textLength: Int
    ) -> Int? {
        let activeTokens = fastStyleActiveTokens(activeTokenIndices: activeTokenIndices, tokens: tokens)
        guard !activeTokens.isEmpty else { return nil }
        let insertedEnd = NSMaxRange(insertedRange)

        func candidateIsInsideActiveContent(_ location: Int) -> Bool {
            guard location >= 0, location < textLength else { return false }
            for token in activeTokens {
                guard location >= token.contentRange.location,
                      location < NSMaxRange(token.contentRange) else {
                    return false
                }
            }
            return true
        }

        let before = insertedRange.location - 1
        if candidateIsInsideActiveContent(before) {
            return before
        }
        if candidateIsInsideActiveContent(insertedEnd) {
            return insertedEnd
        }
        return nil
    }
}
