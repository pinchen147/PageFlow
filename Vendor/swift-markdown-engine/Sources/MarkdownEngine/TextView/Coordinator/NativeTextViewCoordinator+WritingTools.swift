//
//  NativeTextViewCoordinator+WritingTools.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  macOS 15+ Writing Tools integration: pauses styling during the session, re-syncs results on end, fixes child window position, and recovers from Apple's stale-accept-action bug after mid-session Cmd+Z.
//

import AppKit

extension NativeTextViewCoordinator {
    @available(macOS 15.0, *)
    public func textViewWritingToolsWillBegin(_ textView: NSTextView) {
        guard !isComposing(in: textView) else { return }
        let sel = textView.selectedRange()
        // Publish pending keystrokes before the session cancels their debounce.
        commitTextSync(for: textView)
        textSyncGeneration &+= 1
        wtSessionGeneration &+= 1
        isWritingToolsActive = true
        wtStartDocumentId = documentId
        wtChildWindow = nil
        wtInitialChildOrigin = nil
        wtInitialSelectionRange = sel.length > 0 ? sel : nil
        wtDetectedMode = .unknown
        wtUndoneDuringSession = false
        wtPostUndoSnapshot = nil
        observeUndoNotifications(for: textView.undoManager)
        scheduleChildWindowFix(textView: textView, attemptsRemaining: 20)
    }

    @available(macOS 15.0, *)
    public func textViewWritingToolsDidEnd(_ textView: NSTextView) {
        guard isWritingToolsActive else { return }
        textSyncGeneration &+= 1
        isWritingToolsActive = false
        wtChildWindow = nil
        wtInitialChildOrigin = nil
        stopObservingUndoNotifications()

        // Doc switched mid-session — discard WT results, the new node already loaded.
        if wtStartDocumentId != nil && wtStartDocumentId != documentId {
            wtStartDocumentId = nil
            return
        }
        wtStartDocumentId = nil

        // Cmd+Z mid-session: Apple's stale accept-action corrupts text + contaminates attrs with 0.1pt marker font; the post-undo snapshot is the authoritative state.
        let sourceText: String
        let incomingSource = pendingIncomingSource
        pendingIncomingSource = nil
        if let incomingSource {
            sourceText = incomingSource
        } else if wtUndoneDuringSession, let snapshot = wtPostUndoSnapshot {
            sourceText = snapshot
        } else {
            sourceText = textView.string
        }
        wtUndoneDuringSession = false
        wtPostUndoSnapshot = nil

        let position = (textView as? NativeTextView)?.readingPosition()
        let caret = textView.selectedRange().location
        applyPendingEditability(to: textView)
        if let native = textView as? NativeTextView { applyLayoutConfiguration(to: native) }
        if incomingSource != nil {
            cancelDocumentWork()
            if !(textView.string as NSString).isEqual(to: sourceText) {
                textView.breakUndoCoalescing()
                textView.undoManager?.removeAllActions()
            }
            rebuildTextStorageAndStyle(textView, from: sourceText, focusOffset: position?.anchorOffset ?? caret)
            updateCodeBlockSelection(textView: textView, tokens: parsedDocument(for: sourceText).tokens)
        } else if !(textView.string as NSString).isEqual(to: sourceText) {
            isUpdatingSourceOrStyle = true
            textView.string = sourceText
            isUpdatingSourceOrStyle = false
        }
        if incomingSource == nil { restyleCurrentSource(in: textView, focusOffset: position?.anchorOffset ?? caret) }
        restoreAfterRebuild(textView, position: position, caret: caret)
        enqueueDeferredRestyle([])
        pendingPresentationRefresh = false
        if let native = textView as? NativeTextView {
            applyLayoutConfiguration(to: native)
            if let scrollView = native.enclosingScrollView {
                native.refreshOverscrollAfterTextEdit(for: scrollView)
            }
        }
        scheduleCodeBlockSelectionUpdate(textView: textView, tokens: parsedDocument(for: sourceText).tokens)
        finishPendingFind(in: textView)
        let binding = $text
        let bindingSource = binding.wrappedValue
        let generation = documentGeneration
        let session = wtSessionGeneration
        let sourceGeneration = nativeSourceGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.documentGeneration,
                  session == self.wtSessionGeneration,
                  sourceGeneration == self.nativeSourceGeneration,
                  (binding.wrappedValue as NSString).isEqual(to: bindingSource) else { return }
            self.lastSyncedText = sourceText
            binding.wrappedValue = sourceText
        }
    }

    /// Re-lands the reader after a whole-storage rebuild: the caret (clamped)
    /// and the reading position, when known.
    func restoreAfterRebuild(_ textView: NSTextView, position: ReadingPosition?, caret: Int) {
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: max(0, min(caret, length)), length: 0))
        if let position { (textView as? NativeTextView)?.restore(position) }
    }

    // MARK: - Ignored ranges (P4 — protect verbatim code & math from rewrites)

    /// Tells Writing Tools which spans of `enclosingRange` it must leave byte-for-byte
    /// unmodified. We protect every fenced code block, inline code span, block-LaTeX
    /// (`$$…$$`) and inline-LaTeX (`$…$`) token — Apple Intelligence otherwise rewrites
    /// literal code/math as if it were prose (R14 / doc 10 §3 P4 / ADR-0010 §P4).
    ///
    /// Ranges are sourced from the coordinator's existing parse cache
    /// (`parsedDocument(for:)`), whose token `.range`s span the full delimited region
    /// (fences / backticks / `$$` / `$` included) in the SAME display-text coordinate
    /// space AppKit hands us in `enclosingRange`. Each token range is clamped to the
    /// document and intersected with `enclosingRange` before boxing.
    @available(macOS 15.0, *)
    public func textView(
        _ textView: NSTextView,
        writingToolsIgnoredRangesInEnclosingRange enclosingRange: NSRange
    ) -> [NSValue] {
        let documentRange = NSRange(location: 0, length: (textView.string as NSString).length)
        let clampedEnclosing = NSIntersectionRange(enclosingRange, documentRange)
        guard clampedEnclosing.length > 0 else { return [] }

        let parsed = parsedDocument(for: textView.string)
        // codeTokens = fenced code blocks + inline code; latexTokens = inline `$…$`;
        // blockLatexTokens = `$$…$$`. All carry a `.range` over the full verbatim span.
        let protectedTokens = parsed.codeTokens + parsed.blockLatexTokens + parsed.latexTokens

        var ignored: [NSValue] = []
        ignored.reserveCapacity(protectedTokens.count)
        for token in protectedTokens {
            let clamped = NSIntersectionRange(token.range, documentRange)
            guard clamped.length > 0 else { continue }
            let inEnclosing = NSIntersectionRange(clamped, clampedEnclosing)
            guard inEnclosing.length > 0 else { continue }
            ignored.append(NSValue(range: inEnclosing))
        }
        return ignored
    }

    // MARK: - Child window (Done/Original panel) position fix

    private func scheduleChildWindowFix(textView: NSTextView, attemptsRemaining: Int) {
        guard attemptsRemaining > 0, isWritingToolsActive else { return }
        let generation = documentGeneration
        let session = wtSessionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak textView] in
            guard let self, let textView, self.isWritingToolsActive,
                  generation == self.documentGeneration,
                  session == self.wtSessionGeneration else { return }
            self.captureChildWindowIfNeeded(textView: textView)
            if self.wtChildWindow == nil {
                self.scheduleChildWindowFix(textView: textView, attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }

    private func captureChildWindowIfNeeded(textView: NSTextView) {
        guard wtChildWindow == nil,
              let mainWindow = textView.window,
              let childWin = mainWindow.childWindows?.first(where: { $0.isVisible }) else { return }
        wtChildWindow = childWin
        wtInitialChildOrigin = childWin.frame.origin
    }

    // MARK: - Undo observer (captures post-undo snapshot for recovery)

    private func observeUndoNotifications(for undoManager: UndoManager?) {
        stopObservingUndoNotifications()
        guard let um = undoManager else { return }
        let center = NotificationCenter.default
        wtUndoObserverTokens = [
            center.addObserver(forName: .NSUndoManagerDidUndoChange, object: um, queue: .main) { [weak self] _ in
                guard let self, let tv = self.textView, self.isWritingToolsActive else { return }
                self.wtUndoneDuringSession = true
                self.wtPostUndoSnapshot = tv.string
            }
        ]
    }

    private func stopObservingUndoNotifications() {
        wtUndoObserverTokens.forEach(NotificationCenter.default.removeObserver(_:))
        wtUndoObserverTokens.removeAll()
    }

    func fixWritingToolsChildWindowIfNeeded(textView: NSTextView) {
        guard let childWin = wtChildWindow,
              let correctOrigin = wtInitialChildOrigin else { return }

        let frame = childWin.frame
        let needsFix = abs(frame.origin.x - correctOrigin.x) > 0.5 || abs(frame.origin.y - correctOrigin.y) > 0.5
        if needsFix {
            var fixed = frame
            fixed.origin = correctOrigin
            childWin.setFrame(fixed, display: false)
        }
    }
}
