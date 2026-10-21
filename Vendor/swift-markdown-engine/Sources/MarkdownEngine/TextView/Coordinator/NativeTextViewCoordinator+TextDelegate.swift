//
//  NativeTextViewCoordinator+TextDelegate.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  The hot NSTextViewDelegate path: keystroke handling, selection-change
//  reaction, link-click forwarding, and the typing-attributes shim that
//  prevents AppKit from leaking heading paragraphStyle into the trailing
//  extra-line fragment. Restyle scoping (which paragraphs to re-tokenize on
//  each event) lives here too — it sets up the inputs that
//  `+Restyling.swift` then consumes.
//

import AppKit

extension NativeTextViewCoordinator {

    /// Force base typingAttributes on every change so AppKit's auto-inheritance
    /// can't bleed a heading paragraphStyle into the trailing extra-line
    /// fragment's metrics.
    public func textView(
        _ textView: NSTextView,
        shouldChangeTypingAttributes oldTypingAttributes: [String: Any],
        toAttributes newTypingAttributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        guard !isComposing(in: textView), !isWritingToolsActive else { return newTypingAttributes }
        let (baseFont, baseParagraphStyle) = baseFontAndStyle()
        var result = newTypingAttributes
        result[.paragraphStyle] = baseParagraphStyle
        result[.font] = baseFont
        result[.foregroundColor] = configuration.theme.bodyText
        return result
    }

    public func textDidChange(_ notification: Notification) {
        tableChrome?.invalidate()
        tableProxy?.update()
        // Native Undo and host replacements bypass admission; cell editing
        // continues only while its table survives them intact.
        if !tableEditingSession.applyingSource, !isApplyingSpanEdit { tableEditingSession.sourceMayHaveChanged() }
        selectionBar?.setNeedsUpdate()
        guard let tv = notification.object as? NSTextView, !isUpdatingSourceOrStyle else { return }
        // Last, after the restyle below: the object selection follows the edit.
        defer { reconcileObjectSelectionAfterEdit(in: tv) }
        if objectSelection != nil { imageChrome?.setNeedsRefresh() }
        retireFindAfterSourceEdit(in: tv)
        if isComposing(in: tv) {
            pendingCompositionRefresh = true
            return
        }
        nativeSourceGeneration &+= 1
        #if DEBUG
        (tv as? NativeTextView)?.anchorCensusTrace("textDidChange.start")
        #endif
        let signpostState = MarkdownPerfSignpost.signposter.beginInterval("textDidChange")
        defer { MarkdownPerfSignpost.signposter.endInterval("textDidChange", signpostState) }
        // Before the early returns: the first keystroke must hide the placeholder.
        (tv as? NativeTextView)?.refreshPlaceholderVisibility()
        let wtActive = isWritingToolsActive
        if wtActive, wtDetectedMode == .unknown {
            let firstEditLen = tv.textStorage?.editedRange.length ?? 0
            if let sel = wtInitialSelectionRange, sel.length > 0 {
                let threshold = max(10, Int(Double(sel.length) * 0.6))
                wtDetectedMode = firstEditLen >= threshold ? .rewrite : .proofread
            } else {
                wtDetectedMode = .rewrite
            }
        }
        if wtActive && wtDetectedMode == .proofread { return }


        guard let textStorage = tv.textStorage else { return }
        defer {
            synchronizeFolding(edit: committedFoldComposition(in: tv) ?? pendingTextChange)
            if tv.undoManager?.isUndoing == true || tv.undoManager?.isRedoing == true {
                _ = revealFoldedSource(tv.selectedRange())
            }
            pendingEditedRange = nil
            pendingTextChange = nil
            pendingEditMayChangeBlockStructure = false
            pendingEditRequiresFullDocumentRestyle = false
            pendingInlineFormattingEdit = false
            pendingViewportFirstRange = nil
            pendingPreEditActiveTokenIndices = nil
            pendingPreEditRestyleRanges.removeAll(keepingCapacity: true)
        }

        let rawSelRange = tv.selectedRange()
        // Stay on NSTextStorage's mutable string until we know this is a
        // structural Markdown edit. Bridging `tv.string` copies the full document;
        // ordinary prose typing should not pay that cost.
        let documentNS = textStorage.mutableString
        let fullLength = documentNS.length
        guard !isComposing(in: tv) else { return }
        let safeLocation = min(rawSelRange.location, fullLength)
        let safeSelRange = NSRange(location: safeLocation, length: 0)
        previousCaretLocation = safeSelRange.location
        if !wtActive {
            // Publish at the trailing edge of a typing burst; live storage stays
            // authoritative while the host binding catches up.
            scheduleTextSync(for: tv)
        }

        let fullText = documentNS
        let editedRange = pendingEditedRange ?? textStorage.editedRange
        let safeEditedRange: NSRange = {
            if wtActive, let sel = wtInitialSelectionRange {
                let docLength = fullText.length
                let loc = min(sel.location, docLength)
                let len = min(sel.length, docLength - loc)
                return NSRange(location: loc, length: len)
            }
            return editedRange.location == NSNotFound ? safeSelRange : editedRange
        }()
        // Idle restyle passes still queued from an earlier whole-document edit
        // follow this edit's length change, whichever path styles it below.
        // (`changeInLength` is already reset by the time textDidChange runs.)
        shiftDeferredRestyle(edited: safeEditedRange, delta: pendingTextChange?.delta ?? 0)
        if isDeferringTableRender {
            // The cell's grid shows this edit; its table re-renders when typing pauses.
            cachedParsedChars = nil
            return
        }

        if tryPlainTextEditFastPath(
            textView: tv,
            text: fullText,
            selectionRange: safeSelRange,
            editedRange: safeEditedRange
        ) {
            return
        }
        if pendingInlineFormattingEdit,
           tryInlineFormattingEditFastPath(
            textView: tv,
            text: fullText,
            selectionRange: safeSelRange,
            editedRange: safeEditedRange
           ) {
            return
        }

        let paragraphRange = fullText.paragraphRange(for: safeSelRange)
        let documentLength = fullText.length
        let nextLocation = min(documentLength, NSMaxRange(paragraphRange))
        let previousParagraph = paragraphRange.location > 0
            ? fullText.paragraphRange(for: NSRange(location: max(0, paragraphRange.location - 1), length: 0))
            : NSRange(location: NSNotFound, length: 0)
        let nextParagraph = nextLocation < documentLength
            ? fullText.paragraphRange(for: NSRange(location: nextLocation, length: 0))
            : NSRange(location: NSNotFound, length: 0)
        let editedParagraphs = paragraphRanges(in: fullText, intersecting: safeEditedRange)
        let paragraphCandidates: [NSRange] = [
            paragraphRange
        ] + editedParagraphs + (pendingEditMayChangeBlockStructure ? [
            previousParagraph,
            nextParagraph
        ] : [])

        let requiresFullDocumentRestyle = pendingEditRequiresFullDocumentRestyle

        let documentText = documentNS as String
        var parsed: ParsedDocument!
        PerfTrace.time("tdc.tokens") { parsed = parsedDocument(for: documentText) }
        let tokens = parsed.tokens
        let codeTokens = parsed.codeTokens
        let latexTokens = parsed.latexTokens
        let preEditActiveTokenIndices = pendingPreEditActiveTokenIndices ?? previousActiveTokenIndices

        // A selection the edit left on an image's line (Undo of Delete Image)
        // keeps the image rendered; the reconcile after the restyle selects it.
        let imageObject = rawSelRange.length > 0
            ? Self.imageToken(around: rawSelRange, tokens: tokens, in: fullText)?.range : nil
        activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: imageObject ?? safeSelRange,
            tokens: tokens,
            in: fullText,
            suppressed: !tv.isEditable,
            objectSelection: imageObject
        )
        filterImageEmbedActiveTokens(parsed: parsed, text: fullText, selectionLocation: safeSelRange.location,
                                     excluding: imageObject)
        updateAutocorrectSettings(
            tv,
            caretLocation: safeSelRange.location,
            codeTokens: codeTokens,
            latexTokens: latexTokens,
            allTokens: tokens
        )

        var effectiveParagraphCandidates = paragraphCandidates
        if requiresFullDocumentRestyle {
            effectiveParagraphCandidates = [NSRange(location: 0, length: fullText.length)]
        }
        effectiveParagraphCandidates.append(contentsOf: tokenRestyleParagraphs(
            in: fullText,
            tokens: tokens,
            currentActiveTokenIndices: activeTokenIndices,
            previousActiveTokenIndices: preEditActiveTokenIndices
        ))
        if let change = pendingTextChange,
           !pendingPreEditRestyleRanges.isEmpty || pendingEditMayChangeBlockStructure || pendingEditRequiresFullDocumentRestyle {
            effectiveParagraphCandidates.append(contentsOf: affectedTokenParagraphs(
                in: fullText, newTokens: tokens, change: change
            ))
        }

        // A whole-document edit: style the screen now, queue the rest for idle
        // passes (+DeferredRestyle) instead of blocking on the whole note.
        if let viewport = pendingViewportFirstRange {
            pendingViewportFirstRange = nil
            let present = effectiveParagraphCandidates.filter { $0.location != NSNotFound }
            let span = present.dropFirst().reduce(present.first ?? NSRange(location: 0, length: 0)) { NSUnionRange($0, $1) }
            let split = splitViewportFirst(span: span, viewport: viewport, in: fullText)
            effectiveParagraphCandidates = [split.now]
            enqueueDeferredRestyle(split.later,
                                   anchoringVisibleSource: fullLength > NativeTextView.estimatedLayoutChainThreshold)
        }

        // Structural edits (format toggles, block edits, full-document
        // restyles) can re-band tables and shift heights above the viewport;
        // anchor the viewport across the restyle (field: ⌘B/I/U made the view
        // jump). Plain prose typing never reaches this path, and documents
        // with no banded blocks skip the anchor entirely — its post-restyle
        // ensureLayout-to-pin must not tax structural typing in plain docs
        // (the "typing stays O(edit)" invariant).
        let hasBandedBlocks = tokens.contains {
            MarkdownTokenKind.isHeightBanded($0, in: documentText, diagramLanguages: configuration.diagramLanguages)
        }
        let anchorViewport = hasBandedBlocks && (requiresFullDocumentRestyle || pendingEditMayChangeBlockStructure
            || activeTokenIndices != preEditActiveTokenIndices)
        #if DEBUG
        (tv as? NativeTextView)?.anchorCensusTrace("textDidChange.beforeRestyle")
        if let native = tv as? NativeTextView, native.anchorTraceIsEnabled {
            let hull = effectiveParagraphCandidates.dropFirst().reduce(effectiveParagraphCandidates[0]) { NSUnionRange($0, $1) }
            native.anchorTraceLine("RESTYLE-PLAN: candidates=\(effectiveParagraphCandidates.count) hull=\(hull.location)…\(NSMaxRange(hull)) full=\(requiresFullDocumentRestyle) blockStructure=\(pendingEditMayChangeBlockStructure) anchored=\(anchorViewport) tokensChanged=\(activeTokenIndices != preEditActiveTokenIndices)")
        }
        #endif
        PerfTrace.time("tdc.restyle") { restyle(tv, paragraphCandidates: effectiveParagraphCandidates, tokens: tokens, text: documentText, anchoringViewport: anchorViewport) }
        scheduleCodeBlockSelectionUpdate(textView: tv, tokens: tokens)
        if wtActive {
            previousActiveTokenIndices = activeTokenIndices
            return
        }
        if let bottomTextView = tv as? NativeTextView,
           let scrollView = tv.enclosingScrollView {
            PerfTrace.time("tdc.overscroll") { bottomTextView.refreshOverscrollAfterTextEdit(for: scrollView, scheduleExactMeasure: false) }
            (scrollView as? ClampedScrollView)?.clampToInsets()
        }
        previousActiveTokenIndices = activeTokenIndices
    }

    /// Coalesce source publication onto the trailing edge of a typing burst.
    /// Live storage remains authoritative until the host binding catches up.
    func scheduleTextSync(for tv: NSTextView) {
        textSyncGeneration &+= 1
        let generation = textSyncGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak tv] in
            guard let self, let tv, generation == self.textSyncGeneration else { return }
            self.commitTextSync(for: tv)
        }
    }

    /// Publish exact native source after a typing pause or synchronously for save.
    func commitTextSync(for tv: NSTextView) {
        guard !isWritingToolsActive, !isComposing(in: tv) else { return }
        publishSource(tv.string)
    }

    func publishSource(_ source: String) {
        #if DEBUG
        let comparisonStart = CFAbsoluteTimeGetCurrent()
        #endif
        let unchanged = (lastSyncedText as NSString).isEqual(to: source)
        #if DEBUG
        PerfTrace.add("source.publish.compare", since: comparisonStart)
        #endif
        if !unchanged {
            lastSyncedText = source
            #if DEBUG
            let bindingStart = CFAbsoluteTimeGetCurrent()
            #endif
            text = source
            #if DEBUG
            PerfTrace.add("source.publish.binding", since: bindingStart)
            #endif
        }
    }

    func spaceCouldCompleteBlockSyntax(at location: Int, in text: NSString) -> Bool {
        guard location <= text.length else { return true }
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        guard location >= line.location else { return true }
        let prefix = text.substring(with: NSRange(location: line.location, length: location - line.location))
            .trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty else { return false }
        if (1...6).contains(prefix.count), prefix.allSatisfy({ $0 == "#" }) {
            return true
        }
        if prefix == "-" || prefix == "*" || prefix == "+" || prefix == ">" {
            return true
        }
        if let last = prefix.last, last == "." || last == ")" {
            let digits = prefix.dropLast()
            return !digits.isEmpty && digits.allSatisfy(\.isNumber)
        }
        return false
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        selectionBar?.setNeedsUpdate()
        if let comments { MainActor.assumeIsolated { comments.selectionDidChange() } }
        (notification.object as? NativeTextView)?.selectionDidChangeForWideTables()
        guard !isUpdatingSourceOrStyle else { return }
        guard let tv = notification.object as? NSTextView else { return }
        let signpostState = MarkdownPerfSignpost.signposter.beginInterval("selectionChange")
        defer { MarkdownPerfSignpost.signposter.endInterval("selectionChange", signpostState) }
        if isWritingToolsActive { return }
        // Every IME composition update moves the selection; the handler below
        // re-parses the document (composition text invalidates the parse
        // cache) and can restyle mid-composition — per-keystroke O(document)
        // work that also fights the input context. Composition visuals are
        // handled in setMarkedText; the commit path reconciles the rest.
        if isComposing(in: tv) {
            pendingCompositionRefresh = true
            return
        }
        notifyFoldingStateChange()
        foldControls?.refresh()
        let selRange = tv.selectedRange()
        let currentEventType = NSApp.currentEvent?.type
        if skipNextSelectionChangeAfterPlainEdit {
            skipNextSelectionChangeAfterPlainEdit = false
            previousCaretLocation = selRange.location
            return
        }
        skipNextSelectionChangeAfterPlainEdit = false
        if pendingEditedRange != nil {
            previousCaretLocation = selRange.location
            return
        }
        // A selection on a rendered image's line selects the image (doc 26 §3.2);
        // that selection change runs this handler again and does the rest. A
        // drag leaves the selection to AppKit until mouse-up.
        if currentEventType == .leftMouseDragged || currentEventType == .periodic {
            if objectSelectionRange(for: selRange) == nil { objectSelection = nil }
        } else if selectImageUnderSelection(selRange, in: tv) {
            return
        }
        // Bridge the document to String/NSString exactly once. This handler runs on
        // every caret move; it previously re-bridged `tv.string` ~9 times (parse plus
        // the task/HR/bullet membership probes, twice each), and each access copies the
        // whole document. One bridge, reused everywhere below.
        let docString = tv.string
        let nsText = docString as NSString
        // Mouse-/Wake-Fokus auf Link: kein Preview, erst Navigation. Gilt für alle Nicht-Key-Events.
        if currentEventType != .keyDown,
           selRange.location < nsText.length,
           tv.textStorage?.attribute(.link, at: selRange.location, effectiveRange: nil) != nil {
            isImageEmbedActive = false
            isWikiLinkActive = false
            onInlineSelectionChange?(nil)
            return
        }
        updateSelectionStates(tv)
        let selLoc = selRange.location

        let parsed = parsedDocument(for: docString)
        let tokens = parsed.tokens
        let codeTokens = parsed.codeTokens
        let latexTokens = parsed.latexTokens
        if tableGapCaret != nil, !(selRange.length == 0 && selRange.location == nsText.length) { tableGapCaret = nil }
        // A selection moved out of the edited table ends cell editing there.
        if let owned = tableEditingSession.table, !tableEditingSession.applyingSource, !isApplyingSpanEdit,
           selRange.location < owned.range.location || NSMaxRange(selRange) > NSMaxRange(owned.range) {
            tableEditingSession.yieldToDocumentSelection()
        }
        // A caret in a rendered table's source edits a cell instead (+TableEntry);
        // the cell session's own caret move re-enters this handler and settles.
        if enterTableCell(for: selRange, in: tv, parsed: parsed) { return }
        if let revealed = tableEditingSession.revealedSourceTableLocation, !tokens.contains(where: {
            $0.kind == .table && $0.range.location == revealed
                && selRange.location >= $0.range.location && selRange.location <= NSMaxRange($0.range)
        }) {
            tableEditingSession.concealSource()
        }

        let prevActive = activeTokenIndices
        let imageObject = objectSelectionRange(for: selRange)
        activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(selectionRange: selRange, tokens: tokens, in: nsText,
                                                                         suppressed: !tv.isEditable, objectSelection: imageObject)
        filterImageEmbedActiveTokens(parsed: parsed, text: nsText, selectionLocation: selRange.location, excluding: imageObject)
        updateAutocorrectSettings(
            tv,
            caretLocation: selLoc,
            codeTokens: codeTokens,
            latexTokens: latexTokens,
            allTokens: tokens
        )
        let caretLoc = selRange.location
        let paragraphRange = nsText.paragraphRange(for: NSRange(location: caretLoc, length: 0))

        var paragraphCandidates: [NSRange] = [paragraphRange]
        if paragraphRange.length == 0 && caretLoc > 0 {
            paragraphCandidates.append(nsText.paragraphRange(for: NSRange(location: max(0, caretLoc - 1), length: 0)))
        }
        if let prevLoc = previousCaretLocation, prevLoc != caretLoc {
            let safePrev = min(prevLoc, nsText.length)
            let prevPara = nsText.paragraphRange(for: NSRange(location: safePrev, length: 0))
            paragraphCandidates.append(prevPara)
        }
        paragraphCandidates.append(contentsOf: tokenRestyleParagraphs(
            in: nsText,
            tokens: tokens,
            currentActiveTokenIndices: activeTokenIndices,
            previousActiveTokenIndices: previousActiveTokenIndices
        ))

        let tokensChanged = activeTokenIndices != prevActive
        // Caret crossings in/out of `- [ ]` syntax need a restyle too: task
        // checkboxes aren't tracked as tokens, so `tokensChanged` won't
        // notice them, but the styler suppresses the checkbox glyph while
        // the caret sits inside the syntax. Without this signal a
        // cursor-out (after editing the brackets) leaves the line stuck on
        // raw chars.
        let prevTaskSyntax = previousCaretLocation.flatMap {
            MarkdownStyler.taskSyntaxRange(at: $0, in: nsText)
        }
        let currentTaskSyntax = MarkdownStyler.taskSyntaxRange(at: selLoc, in: nsText)
        let taskSyntaxChanged = prevTaskSyntax?.location != currentTaskSyntax?.location
            || prevTaskSyntax?.length != currentTaskSyntax?.length
        // Caret crossings in/out of a thematic-break (HR) line also need a
        // restyle: HR rendering is a pure attribute (no MarkdownToken), so
        // `tokensChanged` won't notice when the caret enters/leaves an
        // `---` / `***` / `___` line. Without this, clicking on a rendered
        // HR wouldn't reveal the source dashes for editing.
        let prevHRLine = previousCaretLocation.flatMap {
            MarkdownStyler.hrLineRange(at: $0, in: nsText)
        }
        let currentHRLine = MarkdownStyler.hrLineRange(at: selLoc, in: nsText)
        let hrLineChanged = prevHRLine?.location != currentHRLine?.location
            || prevHRLine?.length != currentHRLine?.length
        // Bullet markers: caret in/out of `- ` syntax flips glyph ↔ raw.
        let prevBulletSyntax = previousCaretLocation.flatMap {
            MarkdownStyler.bulletSyntaxRange(at: $0, in: nsText)
        }
        let currentBulletSyntax = MarkdownStyler.bulletSyntaxRange(at: selLoc, in: nsText)
        let bulletSyntaxChanged = prevBulletSyntax?.location != currentBulletSyntax?.location
            || prevBulletSyntax?.length != currentBulletSyntax?.length
        // Mid-drag restyle is suppressed (revealing markers shifts the layout → drag hit-test lands short, dropping trailing chars) and replayed on release.
        let isDragSelecting = currentEventType == .leftMouseDragged || currentEventType == .periodic
        if isDragSelecting {
            needsRestyleAfterDrag = true
        } else if tokensChanged || taskSyntaxChanged || hrLineChanged || bulletSyntaxChanged || needsRestyleAfterDrag {
            needsRestyleAfterDrag = false
            // EVERY selection-driven reveal/collapse can change layout height:
            // banded blocks (table, block LaTeX, image embed) swap a ~207pt
            // band with hundreds of points of raw source, and even a heading
            // or list marker reveal changes the line's wrap count (field:
            // clicking headers, tables, and empty lines — which collapse the
            // PREVIOUS element — made the view jump). This path fires on
            // discrete caret moves (clicks, arrows, drag release), never on
            // the plain-typing hot path, so anchor unconditionally — the pin
            // no-ops when the reflow turns out to be height-neutral.
            restyle(tv, paragraphCandidates: paragraphCandidates, tokens: tokens, anchoringViewport: true)
        }

        // Auto-select content when clicking (mouse) into a rendered (previously inactive) latex or image embed
        if selRange.length == 0,
           let eventType = currentEventType,
           eventType == .leftMouseUp || eventType == .leftMouseDown {
            let newlyActive = activeTokenIndices.subtracting(previousActiveTokenIndices)
            for idx in newlyActive {
                let token = tokens[idx]
                // Block LaTeX is intentionally EXCLUDED: auto-selecting its whole multi-line
                // body on click highlighted the entire `$$…$$` expression and scrolled it into
                // view (the jarring "jump + select-all"). Clicking block math should just place
                // a caret to edit the revealed source. Inline latex / image embeds are atomic
                // chips where select-to-retype is the intended affordance, so they stay.
                guard token.kind == .inlineLatex
                    || token.kind == .imageEmbed else {
                    continue
                }
                let selectRange = token.contentRange
                if selectRange.length > 0 {
                    tv.setSelectedRange(selectRange)
                    break
                }
            }
        }

        let nsString = nsText
        let selLocation = tv.selectedRange().location
        // An image selected as a whole is not an inline token being edited.
        let inlineContext = imageObject != nil ? nil : inlineTokenContext(
            at: selLocation,
            parsed: parsed,
            codeTokens: codeTokens,
            text: nsText
        )
        let isInsideImageEmbed = {
            guard case .imageEmbed = inlineContext else { return false }
            return true
        }()
        // Preview must only trigger inside the `![[…]]` content area
        let isInsideImageEmbedContent: Bool = {
            guard case .imageEmbed(let token) = inlineContext else { return false }
            let start = token.range.location + 3
            let end = NSMaxRange(token.range) - 2
            return selLocation >= start && selLocation <= end
        }()

        let isTyping = currentEventType == .keyDown
        let imageEmbedShowsInlinePreview = isInsideImageEmbedContent && isTyping
        var inlineSelectionState: InlineSelectionState? = nil
        if let inlineContext {
            let openingMarkerLength = inlineContext.selectionKind == .imageEmbed ? 3 : 2
            let displayRange = selectionDisplayRange(for: inlineContext.token, openingMarkerLength: openingMarkerLength)
            let placeholder = nsString.substring(with: displayRange)
            let storageRange = inlineContext.selectionKind == .wikiLink ? displayRange : nil
            let previewRect = tv.viewRect(forCharacterRange: displayRange, using: layoutBridge)
                ?? tv.viewRect(forCharacterRange: tv.selectedRange(), using: layoutBridge)

            let shouldShowInlinePreview =
                inlineContext.selectionKind == .wikiLink
                || (inlineContext.selectionKind == .imageEmbed && imageEmbedShowsInlinePreview)
            if shouldShowInlinePreview, let previewRect {
                let selection = WikiLinkSelection(
                    displayRange: displayRange,
                    storageRange: storageRange,
                    placeholder: placeholder
                )
                inlineSelectionState = InlineSelectionState(kind: inlineContext.selectionKind, selection: selection)
                let generation = documentGeneration
                DispatchQueue.main.async { [weak self, weak tv] in
                    guard let self, let tv, generation == self.documentGeneration,
                          !self.isComposing(in: tv) else { return }
                    self.onCaretRectChange?(previewRect)
                }
            }
        }

        let generation = documentGeneration
        DispatchQueue.main.async { [weak self, weak tv] in
            guard let self, let tv, generation == self.documentGeneration,
                  !self.isComposing(in: tv) else { return }
            self.isWikiLinkActive = inlineSelectionState?.kind == .wikiLink
            self.isImageEmbedActive = isInsideImageEmbed
            self.onInlineSelectionChange?(inlineSelectionState)
        }

        self.previousActiveTokenIndices = self.activeTokenIndices
        self.previousCaretLocation = caretLoc

        updateCodeBlockSelection(textView: tv, tokens: tokens)
    }

    public func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard admitFoldedEdit(affectedCharRange, in: textView) else { return false }
        // Prose typing never writes into a rendered table's hidden source; only
        // cell edits, span edits and Undo do. Unguarded, a keystroke there
        // corrupted the table invisibly (`Q| Case | Source |`).
        if !tableEditingSession.applyingSource, !isApplyingSpanEdit, !isProgrammaticEdit,
           textView.undoManager?.isUndoing != true, textView.undoManager?.isRedoing != true,
           renderedTable(cutBy: affectedCharRange, in: textView) != nil {
            // A selection across a table's edge keeps the table (the reference editor).
            if affectedCharRange.length > 0, let replacementString, !textView.hasMarkedText(), !isComposing(in: textView) {
                replaceAcrossTables(affectedCharRange, with: replacementString, in: textView)
            }
            return false
        }
        // Any other direct edit of the document ends cell editing. Committing the
        // cell here would shift the range this edit was computed against.
        if !tableEditingSession.applyingSource, !isApplyingSpanEdit { tableEditingSession.retire() }
        if isProgrammaticEdit || isComposing(in: textView) { return true }
        if isWritingToolsActive { return true }
        guard let textStorage = textView.textStorage else { return true }
        guard captureSourceEdit(in: textView, range: affectedCharRange, replacement: replacementString ?? "") else { return false }
        let currentText = textStorage.mutableString
        let replacement = replacementString ?? ""
        if textView.undoManager?.isUndoing == true || textView.undoManager?.isRedoing == true {
            pendingPreEditActiveTokenIndices = nil
            return true
        }
        if isLiteralInsertion { return true }
        let parsed = cachedParsedDocument
        prepareTypingAttributesForPlainFastPath(
            textView: textView,
            text: currentText,
            affectedCharRange: affectedCharRange,
            replacement: replacement,
            parsed: parsed
        )

        // Block LaTeX auto-wrap: insert newlines to keep $$ on its own line
        if MarkdownInputHandler.handleBlockLatexAutoWrap(
            textView: textView,
            affectedCharRange: affectedCharRange,
            replacementString: replacementString,
            blockLatexTokens: parsed?.blockLatexTokens ?? []
        ) {
            return false
        }

        if MarkdownInputHandler.handleImageEmbedAutoWrap(
            textView: textView,
            affectedCharRange: affectedCharRange,
            replacementString: replacementString,
            imageEmbedTokens: parsed?.imageEmbedTokens ?? []
        ) {
            return false
        }

        return MarkdownInputHandler.handleListInsertion(
            textView: textView,
            affectedCharRange: affectedCharRange,
            replacementString: replacementString,
            codeTokens: parsed?.codeTokens
        )
    }

    /// Capture the actual source mutation, independently of policy admission. Atomic
    /// block moves admit both locations first, but each edit needs its own old coordinates.
    func captureSourceEdit(in textView: NSTextView, range affectedCharRange: NSRange,
                           replacement replacementString: String) -> Bool {
        guard let textStorage = textView.textStorage else { return true }
        let currentText = textStorage.mutableString
        let replacement = replacementString
        pendingTextChange = TextChange(oldRange: affectedCharRange, replacement: replacement)
        pendingEditMayChangeBlockStructure = editMayChangeBlockStructure(
            in: currentText,
            affectedCharRange: affectedCharRange,
            replacementString: replacementString
        )
        pendingEditRequiresFullDocumentRestyle = editMayRequireFullDocumentRestyle(
            in: currentText,
            affectedCharRange: affectedCharRange,
            replacementString: replacementString
        )
        pendingPreEditActiveTokenIndices = previousActiveTokenIndices

        if let nativeTextView = textView as? NativeTextView {
            if affectedCharRange.location != NSNotFound,
               NSMaxRange(affectedCharRange) <= currentText.length {
                let oldText = currentText.substring(with: affectedCharRange)
                nativeTextView.pendingTextEditLineDelta += lineBreakCount(in: replacement) - lineBreakCount(in: oldText)
            }
        }
        pendingEditedRange = NSRange(location: affectedCharRange.location, length: replacement.utf16.count)
        let currentLen = currentText.length
        let maxR = affectedCharRange.location + affectedCharRange.length
        if affectedCharRange.location > currentLen || maxR > currentLen {
            pendingPreEditActiveTokenIndices = nil
            return false
        }
        pendingPreEditRestyleRanges.removeAll(keepingCapacity: true)
        // A deferred table-cell edit restyles nothing now, so it needs no pre-edit tokens.
        if pendingEditMayChangeBlockStructure || pendingEditRequiresFullDocumentRestyle, !isDeferringTableRender {
            let before = parsedDocument(for: currentText as String)
            pendingPreEditRestyleRanges = before.tokens.enumerated().compactMap { index, token in
                let intersects = NSIntersectionRange(token.range, affectedCharRange).length > 0
                    || (affectedCharRange.length == 0 && affectedCharRange.location >= token.range.location
                        && affectedCharRange.location <= NSMaxRange(token.range))
                return intersects || previousActiveTokenIndices.contains(index) ? token.range : nil
            }
        }
        return true
    }

    private func lineBreakCount(in text: String) -> Int {
        text.unicodeScalars.reduce(0) { partial, scalar in
            partial + (scalar == "\n" ? 1 : 0)
        }
    }

    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if let handled = handleImageCommand(commandSelector, in: textView) { return handled }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            return handleBacktab(textView)
        }
        if let handled = handleGapCaretCommand(commandSelector, in: textView) { return handled }
        if let handled = handleBackspaceAfterTable(commandSelector, in: textView) { return handled }
        // Escape hides the selection bar for this selection (the reference editor's Escape ladder).
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Escape closes an open comment card, then hides the bar.
            if let comments, MainActor.assumeIsolated({ comments.store.focusID != nil }) {
                MainActor.assumeIsolated { comments.collapse(announce: true) }
                return true
            }
            if selectionBar?.suppressForEscape() == true { return true }
        }
        return moveCaretRememberingTableEntry(commandSelector, in: textView)
    }

    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard !isComposing(in: textView) else { return true }
        if let url = link as? URL {
            let scheme = url.scheme?.lowercased()
            // the reference editor: a click on a link opens its actions; Open link navigates.
            if scheme == "http" || scheme == "https" || scheme == "mailto",
               let bar = selectionBar, bar.showLinkActions(at: charIndex) { return true }
            if scheme == "http" || scheme == "https" || scheme == "mailto" { return false }
            // A local destination is the host's to scope-check and open; any
            // other scheme is refused.
            if scheme == nil || scheme == "file", let open = onOpenLocalLink {
                DispatchQueue.main.async { open(url) }
            }
            return true
        }
        guard link is String,
              let target = WikiLinkService.resolveIdentifier(link: link, textView: textView, at: charIndex) else {
            return true
        }
        isWikiLinkActive = false
        let callback = onLinkClick
        let generation = documentGeneration
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self, let textView, generation == self.documentGeneration,
                  !self.isComposing(in: textView) else { return }
            callback?(target)
        }
        return true
    }

    func updateSelectionStates(_ tv: NSTextView) {
        guard !isComposing(in: tv) else { return }
        let nsText = tv.string as NSString
        let selRange = tv.selectedRange()
        let bus = configuration.services.bus
        let center = NotificationCenter.default
        // When scoping, stamp the post with our documentId so the host toolbar
        // can filter to the foreground tab; else legacy nil broadcast.
        let scopeObject: Any? = bus.scopeObject(for: documentId)
        if let name = bus.selectionBoldDidChange {
            center.post(
                name: name, object: scopeObject,
                userInfo: ["isBold": isSelectionBold(in: nsText, range: selRange)]
            )
        }
        if let name = bus.selectionItalicDidChange {
            center.post(
                name: name, object: scopeObject,
                userInfo: ["isItalic": isSelectionItalic(in: nsText, range: selRange)]
            )
        }
    }

    func handleBacktab(_ textView: NSTextView) -> Bool {
        let nsText = textView.string as NSString
        let caretLoc = textView.selectedRange().location
        let lineRange = nsText.lineRange(for: NSRange(location: caretLoc, length: 0))
        let line = nsText.substring(with: lineRange)

        let pattern = #"^([\t ]*)((\d+)\.|[-•*+])\s"#
        let regex = try? NSRegularExpression(pattern: pattern)
        if let regex = regex,
           let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) {
            let wsRangeLocal = match.range(at: 1)
            let wsString = (line as NSString).substring(with: wsRangeLocal)
            let wsDocStart = lineRange.location + wsRangeLocal.location
            let depth = MarkdownLists.indentLevel(from: wsString)
            // Legacy `\t• ` top-level depth=1 (synthetic tab); new format depth=0.
            let markerString = (line as NSString).substring(with: match.range(at: 2))
            let isLegacyBulletGlyph = markerString.first == "•"
            let minDepth = isLegacyBulletGlyph ? 1 : 0
            if depth <= minDepth {
                return true
            }

            if wsRangeLocal.length > 0 {
                if wsString.hasPrefix("\t") {
                    MarkdownLists.performEdit(textView, replace: NSRange(location: wsDocStart, length: 1), with: "")
                    textView.setSelectedRange(NSRange(location: max(0, caretLoc - 1), length: 0))
                    return true
                } else {
                    var removeCount = 0
                    for ch in wsString {
                        if ch == " " && removeCount < 2 { removeCount += 1 } else { break }
                    }
                    if removeCount == 0 { removeCount = min(2, wsRangeLocal.length) }
                    MarkdownLists.performEdit(textView, replace: NSRange(location: wsDocStart, length: removeCount), with: "")
                    textView.setSelectedRange(NSRange(location: max(0, caretLoc - removeCount), length: 0))
                    return true
                }
            } else {
                return true
            }
        }

        if line.hasPrefix("\t") {
            MarkdownLists.performEdit(textView, replace: NSRange(location: lineRange.location, length: 1), with: "")
            textView.setSelectedRange(NSRange(location: max(0, caretLoc - 1), length: 0))
            return true
        }
        return false
    }

}
