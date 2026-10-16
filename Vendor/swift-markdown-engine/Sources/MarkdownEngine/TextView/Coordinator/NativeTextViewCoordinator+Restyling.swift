//
//  NativeTextViewCoordinator+Restyling.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Re-tokenization, paragraph-scoped restyling, and the inline-replacement
//  pipeline. The TextDelegate extension decides WHEN and on WHICH ranges to
//  restyle; this extension owns the tokenize cache and the actual call into
//  `TextStylingService`.
//

import AppKit

extension NativeTextViewCoordinator {
    /// Atomically rebuilds contents + base attrs + Markdown styling from storage-form `text`.
    /// `focusOffset` is where the reader will be after the rebuild (a pending
    /// reading position, the current one, the caret): on a long note only the
    /// screens around it are styled before the first paint, the rest follows
    /// in pinned deferred chunks.
    func rebuildTextStorageAndStyle(
        _ textView: NSTextView,
        from text: String,
        invalidateLayout: Bool = false,
        focusOffset: Int? = nil
    ) {
        guard !isComposing(in: textView), !isWritingToolsActive else {
            pendingPresentationRefresh = true
            return
        }
        if !(textView.string as NSString).isEqual(to: text) {
            isUpdatingSourceOrStyle = true
            textView.string = text
            isUpdatingSourceOrStyle = false
        }
        lastSyncedText = text
        restyleCurrentSource(in: textView, invalidateLayout: invalidateLayout, focusOffset: focusOffset)
    }

    /// Refresh presentation without replacing native text or its pending publication.
    func restyleCurrentSource(
        in textView: NSTextView,
        invalidateLayout: Bool = false,
        focusOffset: Int? = nil
    ) {
        guard !isComposing(in: textView), !isWritingToolsActive else {
            pendingPresentationRefresh = true
            return
        }
        isUpdatingSourceOrStyle = true
        defer { isUpdatingSourceOrStyle = false }
        let displayText = textView.string
        let nsDisplay = displayText as NSString
        let fullRange = NSRange(location: 0, length: nsDisplay.length)

        let (baseFont, paragraph) = baseFontAndStyle()
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: configuration.theme.bodyText,
            .paragraphStyle: paragraph
        ]
        textView.textStorage?.beginEditing()
        PerfTrace.time("rebuild.base") {
        textView.textStorage?.removeAttribute(.link, range: fullRange)
        textView.textStorage?.setAttributes(baseAttrs, range: fullRange)
        }

        // A very long note paints its text now and is styled when a background
        // parse lands (`+BackgroundParse.swift`).
        if shouldParseInBackground(nsDisplay, in: textView) {
            textView.textStorage?.endEditing()
            textView.typingAttributes = TextStylingService.makeBaseTypingAttributes(
                font: baseFont,
                paragraphStyle: paragraph,
                theme: configuration.theme
            )
            activeTokenIndices = []
            deferredRestyleRanges.removeAll()
            parseInBackground(displayText, for: textView)
            return
        }
        // This restyle covers the whole note (viewport now, the rest deferred).
        pendingBackgroundStyle = nil

        var tokens: [MarkdownToken] = []
        PerfTrace.time("rebuild.parse") { tokens = parsedDocument(for: displayText).tokens }
        PerfTrace.stamp("rebuild.parsed")
        // Hide caret from styling when read-only, else clicks reveal raw token syntax.
        let caretLocation = textView.isEditable ? textView.selectedRange().location : -1
        activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: textView.selectedRange(),
            tokens: tokens,
            in: nsDisplay,
            suppressed: !textView.isEditable
        )

        // Viewport-first on a long note: style the paragraphs around the focus
        // now, queue the rest (above first, then below) as pinned chunks.
        let length = nsDisplay.length
        var styleScope: [NSRange]? = nil
        var deferred: [NSRange] = []
        if length >= Self.viewportFirstRebuildThreshold {
            let focus = min(max(0, focusOffset ?? 0), max(0, length - 1))
            let start = nsDisplay.paragraphRange(for: NSRange(location: max(0, focus - Self.deferredRestyleMargin), length: 0)).location
            let end = NSMaxRange(nsDisplay.paragraphRange(for: NSRange(location: min(length - 1, focus + Self.deferredRestyleMargin), length: 0)))
            styleScope = [NSRange(location: start, length: max(0, end - start))]
            if start > 0 { deferred.append(NSRange(location: 0, length: start)) }
            if end < length { deferred.append(NSRange(location: end, length: length - end)) }
        }
        var ranges: [StyledRange] = []
        PerfTrace.time("rebuild.compute") {
        textView.effectiveAppearance.performAsCurrentDrawingAppearance {
        ranges = MarkdownStyler.styleAttributes(
            text: displayText,
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            caretLocation: caretLocation,
            activeTokenIndices: activeTokenIndices,
            precomputedTokens: tokens,
            scopedRanges: styleScope,
            configuration: configuration
        )
        }
        }
        PerfTrace.time("rebuild.write") {
        // One ordered `setAttributes` per flattened run (base + overrides),
        // the same final attributes as the per-key `addAttribute` loop.
        for run in TextStylingService.flattenedRuns(ranges, base: baseAttrs, length: nsDisplay.length) {
            textView.textStorage?.setAttributes(run.attributes, range: run.range)
        }
        }
        PerfTrace.time("rebuild.endEditing") { textView.textStorage?.endEditing() }
        PerfTrace.stamp("rebuild.written")

        textView.typingAttributes = TextStylingService.makeBaseTypingAttributes(
            font: baseFont,
            paragraphStyle: paragraph,
            theme: configuration.theme
        )

        if let tlm = textView.textLayoutManager {
            if invalidateLayout {
                tlm.invalidateLayout(for: tlm.documentRange)
            }
            // Before the view has a window and a width (a first mount), a
            // whole-note layout would run at width 0 and be discarded; the
            // exact height measure lays the note out once it is sized.
            if textView.window != nil, (textView.textContainer?.size.width ?? 0) > 1 {
                PerfTrace.time("rebuild.layout") { textView.ensureWholeNoteLayoutUnlessLong() }
            }
        }

        // A rebuild supersedes whatever chunks an earlier pass had queued.
        deferredRestyleRanges.removeAll()
        if !deferred.isEmpty { enqueueDeferredRestyle(deferred) }

        // Reconcile wide-table overlays after layout settles. SYNC realign
        // first: layout was just ensured, so visible overlays move in the SAME
        // turn as the text; the coalesced async pass then does the full
        // create/destroy reconcile.
        PerfTrace.time("rebuild.overlays") {
        if let nativeTextView = textView as? NativeTextView,
           shouldUpdateWideTableOverlays(in: nativeTextView, tokens: nil) {
            nativeTextView.realignWideTableOverlays()
            DispatchQueue.main.async { [weak nativeTextView] in
                nativeTextView?.updateWideTableOverlays()
            }
        }
        }
    }

    func restyleTextView(
        _ textView: NSTextView,
        paragraphCandidates: [NSRange],
        tokens: [MarkdownToken]? = nil,
        text: String? = nil
    ) {
        guard !isComposing(in: textView), !isWritingToolsActive else {
            pendingPresentationRefresh = true
            return
        }
        let (baseFont, paragraphStyle) = baseFontAndStyle()

        PerfTrace.time("rtv.service") {
        textView.effectiveAppearance.performAsCurrentDrawingAppearance {
        TextStylingService.restyle(
            textView: textView,
            layoutBridge: layoutBridge,
            paragraphCandidates: paragraphCandidates,
            baseFont: baseFont,
            paragraphStyle: paragraphStyle,
            caretLocation: textView.isEditable ? textView.selectedRange().location : -1,
            activeTokenIndices: activeTokenIndices,
            wikiLinkIDProvider: { _ in nil },
            precomputedTokens: tokens,
            text: text,
            configuration: configuration
        )
        }
        }
        // Reconcile wide-table overlays only when this document has table tokens
        // or existing overlays that may need removal/repositioning. Most
        // keystrokes in prose/code docs avoid the follow-up storage scan entirely.
        // SYNC realign first (cheap, O(#overlays)): an edit above a table moves
        // visible overlays in the SAME turn as the reflow, so a stale grid is
        // never painted over the moved prose while the async pass is queued.
        PerfTrace.time("rtv.overlays") {
        if let nativeTextView = textView as? NativeTextView,
           shouldUpdateWideTableOverlays(in: nativeTextView, tokens: tokens) {
            nativeTextView.realignWideTableOverlays()
            DispatchQueue.main.async { [weak nativeTextView] in
                nativeTextView?.updateWideTableOverlays()
            }
        }
        }
    }

    private func shouldUpdateWideTableOverlays(
        in textView: NativeTextView,
        tokens: [MarkdownToken]?
    ) -> Bool {
        if !textView.wideTableOverlays.isEmpty { return true }
        guard let tokens else { return true }
        return tokens.contains { $0.kind == .table }
    }

    func parsedDocument(for text: String) -> ParsedDocument {
        let source = text as NSString
        if let cachedParsedChars, let cachedParsedDocument, utf16(cachedParsedChars, equals: source) {
            if plainInsertionsSinceParse.isEmpty { return cachedParsedDocument }
            if let rebased = parsedDocumentRebasedForPlainInsertions(cachedParsedDocument) {
                self.cachedParsedDocument = rebased
                plainInsertionsSinceParse.removeAll()
                pendingPlainFastPathExpansion = nil
                return rebased
            }
        }

        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let parsed = parsedDocument(from: tokens)
        cacheParse(parsed, of: source)
        return parsed
    }

    /// Caches `parsed` as the parse of `source`, with headroom in the source
    /// copy for the typing that keeps it current (`recordPlainInsertion`), so
    /// the first keystroke does not reallocate a megabytes-long buffer.
    func cacheParse(_ parsed: ParsedDocument, of source: NSString) {
        let length = source.length
        cachedParsedChars = [UInt16](unsafeUninitializedCapacity: length + 4_096) { buffer, count in
            if let base = buffer.baseAddress { source.getCharacters(base, range: NSRange(location: 0, length: length)) }
            count = length
        }
        cachedParsedDocument = parsed
        plainInsertionsSinceParse.removeAll()
        pendingPlainFastPathExpansion = nil
    }

    func parsedDocument(from tokens: [MarkdownToken]) -> ParsedDocument {
        var codeTokens: [MarkdownToken] = []
        var latexTokens: [MarkdownToken] = []
        var blockLatexTokens: [MarkdownToken] = []
        var wikiLinkTokens: [MarkdownToken] = []
        var imageEmbedTokens: [MarkdownToken] = []

        codeTokens.reserveCapacity(tokens.count / 2)
        latexTokens.reserveCapacity(tokens.count / 4)
        blockLatexTokens.reserveCapacity(tokens.count / 4)
        wikiLinkTokens.reserveCapacity(tokens.count / 4)

        for token in tokens {
            switch token.kind {
            case .codeBlock, .inlineCode:
                codeTokens.append(token)
            case .inlineLatex:
                latexTokens.append(token)
            case .blockLatex:
                blockLatexTokens.append(token)
            case .wikiLink:
                wikiLinkTokens.append(token)
            case .imageEmbed:
                imageEmbedTokens.append(token)
            default:
                break
            }
        }

        return ParsedDocument(
            tokens: tokens,
            codeTokens: codeTokens,
            latexTokens: latexTokens,
            blockLatexTokens: blockLatexTokens,
            wikiLinkTokens: wikiLinkTokens,
            imageEmbedTokens: imageEmbedTokens
        )
    }

    func paragraphRanges(
        in text: NSString,
        intersecting editedRange: NSRange
    ) -> [NSRange] {
        guard text.length > 0 else { return [] }
        guard editedRange.location != NSNotFound else { return [] }

        var start = editedRange.location
        let end = min(NSMaxRange(editedRange), text.length)
        if start >= text.length {
            start = max(0, text.length - 1)
        }
        if end <= start {
            return [text.paragraphRange(for: NSRange(location: start, length: 0))]
        }

        var ranges: [NSRange] = []
        var cursor = start
        while cursor < end {
            let paragraph = text.paragraphRange(for: NSRange(location: cursor, length: 0))
            ranges.append(paragraph)
            let next = NSMaxRange(paragraph)
            if next <= cursor { break }
            cursor = next
        }
        return ranges
    }

    func tokenRestyleParagraphs(
        in text: NSString,
        tokens: [MarkdownToken],
        currentActiveTokenIndices: Set<Int>,
        previousActiveTokenIndices: Set<Int>
    ) -> [NSRange] {
        var paragraphs: [NSRange] = []
        let indicesToStyle = currentActiveTokenIndices.union(previousActiveTokenIndices)

        for idx in indicesToStyle where idx >= 0 && idx < tokens.count {
            let token = tokens[idx]
            paragraphs.append(text.paragraphRange(for: token.range))

            if token.kind == .codeBlock || token.kind == .blockLatex {
                for markerRange in token.markerRanges {
                    paragraphs.append(text.paragraphRange(for: markerRange))
                }
            }
        }

        return paragraphs
    }

    func restyleParagraphs(_ paragraphs: [NSRange], in textView: NSTextView) {
        guard !isComposing(in: textView), !isWritingToolsActive else {
            pendingPresentationRefresh = true
            return
        }
        let parsed = parsedDocument(for: textView.string)
        let tokens = parsed.tokens
        let nsText = textView.string as NSString
        activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: textView.selectedRange(),
            tokens: tokens,
            in: nsText,
            suppressed: !textView.isEditable
        )
        restyleTextView(textView, paragraphCandidates: paragraphs, tokens: tokens)
    }

    /// Style the live IME composition WITHOUT parsing: marked text should look
    /// like the run it's being typed into (heading size, bold face, code font),
    /// so sample the attributes adjacent to the composition and lay only the
    /// visual keys over the marked range. `addAttributes` — never
    /// `setAttributes` — because the IME's own marked-text attributes (clause
    /// underlines) must survive, and an allowlist so bookkeeping keys
    /// (`.link`, `.attachment`, wiki-link IDs) can't leak into composition
    /// text. Cost is O(marked length); the full restyle runs on commit.
    func applyCompositionAttributes(to markedRange: NSRange, in textView: NSTextView) {
        guard let textStorage = textView.textStorage,
              markedRange.length > 0,
              NSMaxRange(markedRange) <= textStorage.length else { return }

        let sampled: [NSAttributedString.Key: Any]
        if markedRange.location > 0 {
            sampled = textStorage.attributes(at: markedRange.location - 1, effectiveRange: nil)
        } else if NSMaxRange(markedRange) < textStorage.length {
            sampled = textStorage.attributes(at: NSMaxRange(markedRange), effectiveRange: nil)
        } else {
            sampled = textView.typingAttributes
        }

        var overlay: [NSAttributedString.Key: Any] = [:]
        for key: NSAttributedString.Key in [.font, .foregroundColor, .paragraphStyle, .backgroundColor] {
            if let value = sampled[key] { overlay[key] = value }
        }
        guard !overlay.isEmpty else { return }
        textStorage.beginEditing()
        textStorage.addAttributes(overlay, range: markedRange)
        textStorage.endEditing()
    }

    /// Runs `body` (a restyle that can change layout HEIGHT — banded-block
    /// reveal/collapse, full-document restyles) while keeping what the user is
    /// looking at stationary. Thin wrapper over the shared
    /// `NativeTextView.preservingViewportAnchor` (the one home for the
    /// scroll-correction math), supplying the structural-restyle SETTLE step:
    /// after `body`, a viewport pass first — it can revise fragment positions
    /// ensureLayout just produced (the ensureLayout-vs-viewport disagreement;
    /// skipping it left a +55pt revision to land in the next async turn,
    /// outside any pin — the residual "view still jumps on click" report) —
    /// then layout up to the pin so its Y is trustworthy before correction.
    /// Bounded cost: only structural/reveal paths reach here; plain prose
    /// typing exits on the fast paths long before.
    func restylePreservingViewport(_ textView: NSTextView, mapPin: ((Int) -> Int)? = nil, anchoringVisibleSource: Bool = false, tag: String = #function, _ body: () -> Void) {
        guard let native = textView as? NativeTextView else { body(); return }
        let settle: (Int) -> Void = { pinLoc in
            guard let tlm = native.textLayoutManager,
                  let tcs = tlm.textContentManager as? NSTextContentStorage else { return }
            PerfTrace.time("pin.layoutViewport1") { tlm.textViewportLayoutController.layoutViewport() }
            let length = (native.string as NSString).length
            if !native.prefersEstimatedLayoutChain,
               let end = tcs.location(tcs.documentRange.location, offsetBy: min(pinLoc + 1, length)),
               let range = NSTextRange(location: tcs.documentRange.location, end: end) {
                PerfTrace.time("pin.ensureLayout") { tlm.ensureLayout(for: range) }
            }
            // Re-run the viewport pass AFTER the ensureLayout so the pin's afterY
            // (measured by preservingViewportAnchor right after settle) reads the
            // DRAWN geometry. TextKit 2 draws from layoutViewport, not from
            // ensureLayout, and the two disagree by exactly the above-fold estimate
            // revision — so ending the settle on ensureLayout made the pin correct
            // against soon-to-be-revised geometry and slide one frame later (the
            // residual view-jump on click). This runs SYNCHRONOUSLY inside the pin's
            // before/after window, so any scroll it induces is folded into
            // visibleRect.minY when the delta correction runs (the pin is the last
            // writer) — unlike the async overlay reconcile's layoutViewport, which
            // must stay OUT of the pin (887303b: async-outside-pin drifts 19pt).
            PerfTrace.time("pin.layoutViewport2") { tlm.textViewportLayoutController.layoutViewport() }
        }
        let continuesBulkEdit = bulkViewportAnchor?.isCurrent(in: native, sourceGeneration: nativeSourceGeneration) == true
        if bulkViewportAnchor != nil && !continuesBulkEdit { bulkViewportAnchor = nil }
        if anchoringVisibleSource || continuesBulkEdit {
            var receipt = bulkViewportAnchor
            if native.preservingVisibleSourceAnchor(continuing: &receipt,
                                                    sourceGeneration: { self.nativeSourceGeneration },
                                                    settle: settle, mapPin: mapPin, body) {
                bulkViewportAnchor = receipt
                return
            }
            bulkViewportAnchor = nil
        }
        native.preservingViewportAnchor(settle: settle, mapPin: mapPin, tag: tag, body)
    }

    /// Restyle `tv`, optionally pinning the viewport across the pass. `anchor`
    /// is computed per call site and legitimately differs: the structural
    /// typing path gates on banded-blocks + a structural change, the inline
    /// format path on a height-banded token set, the selection-reveal path is
    /// unconditional. Collapses the wrap/else boilerplate that each site used
    /// to inline verbatim; behavior is identical to that two-branch form (the
    /// pin no-ops when the reflow turns out height-neutral).
    func restyle(
        _ tv: NSTextView,
        paragraphCandidates: [NSRange],
        tokens: [MarkdownToken]? = nil,
        text: String? = nil,
        anchoringViewport anchor: Bool,
        anchoringVisibleSource: Bool = false,
        tag: String = #function
    ) {
        if anchor {
            restylePreservingViewport(tv, anchoringVisibleSource: anchoringVisibleSource, tag: tag) {
                self.restyleTextView(tv, paragraphCandidates: paragraphCandidates, tokens: tokens, text: text)
            }
        } else {
            restyleTextView(tv, paragraphCandidates: paragraphCandidates, tokens: tokens, text: text)
        }
    }

    func applyInlineReplacement(_ request: InlineReplacementRequest, to textView: NSTextView) {
        lastAppliedInlineReplacementID = request.id

        let currentText = textView.string as NSString
        let range = request.selection.displayRange
        guard range.location != NSNotFound,
              range.location + range.length <= currentText.length else {
            return
        }

        let replacementDisplay = request.storageFragment

        let undoActionName = request.isImageEmbedMode ? "Insert Image Embed" : "Insert Link"
        textView.breakUndoCoalescing()

        isProgrammaticEdit = true
        defer { isProgrammaticEdit = false }

        guard textView.shouldChangeText(in: range, replacementString: replacementDisplay) else {
            return
        }

        textView.textStorage?.replaceCharacters(in: range, with: replacementDisplay)

        textView.didChangeText()
        textView.undoManager?.setActionName(undoActionName)
        textView.breakUndoCoalescing()

        let caretRange = NSRange(location: range.location + replacementDisplay.utf16.count, length: 0)
        let documentLength = (textView.string as NSString).length
        let clampedCaret = NSRange(location: min(max(caretRange.location, 0), documentLength), length: 0)

        if let bottomTextView = textView as? NativeTextView {
            bottomTextView.suppressAutoRevealOnce = true
        }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(clampedCaret)
    }
}
