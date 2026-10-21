import AppKit
import SwiftUI

extension NativeTextViewCoordinator {
    func isComposing(in textView: NSTextView) -> Bool {
        if textView === self.textView, tableEditingSession.isComposing { return true }
        if let native = textView as? NativeTextView,
           native.isSettingMarkedText || native.isCommittingMarkedText { return true }
        return textView.hasMarkedText()
    }

    func finishComposition(in textView: NativeTextView) {
        guard !isComposing(in: textView) else { return }
        defer { textView.resumeCompletedImageImports() }
        guard pendingCompositionRefresh else {
            finishPendingFind(in: textView)
            return
        }
        pendingCompositionRefresh = false
        let incoming = pendingIncomingSource
        pendingIncomingSource = nil
        let needsPresentation = pendingPresentationRefresh
        pendingPresentationRefresh = false
        let position = textView.readingPosition()
        let caret = textView.selectedRange().location
        applyPendingEditability(to: textView)
        applyLayoutConfiguration(to: textView)
        if let incoming {
            cancelDocumentWork()
            if !(textView.string as NSString).isEqual(to: incoming) {
                textView.breakUndoCoalescing()
                textView.undoManager?.removeAllActions()
            }
            rebuildTextStorageAndStyle(textView, from: incoming, focusOffset: position?.anchorOffset ?? caret)
            restoreAfterRebuild(textView, position: position, caret: caret)
            updateCodeBlockSelection(textView: textView, tokens: parsedDocument(for: incoming).tokens)
        } else {
            if needsPresentation { restyleCurrentSource(in: textView, focusOffset: position?.anchorOffset ?? caret) }
            textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        }
        if let scrollView = textView.enclosingScrollView {
            textView.refreshOverscrollAfterTextEdit(for: scrollView)
        }
        enqueueDeferredRestyle([])
        finishPendingFind(in: textView)
    }

    /// Keep the outgoing write attached to its original document target.
    func publishOutgoingSource(from textView: NativeTextView) {
        tableEditingSession.finishInput()
        if textView.hasMarkedText() { textView.unmarkText() }
        guard !isWritingToolsActive else { return }
        let source = textView.string
        guard !(lastSyncedText as NSString).isEqual(to: source) else { return }
        let outgoingBinding = $text
        DispatchQueue.main.async { outgoingBinding.wrappedValue = source }
    }

    func cancelDocumentWork() {
        foldIndexTask?.cancel()
        foldIndexTask = nil
        foldIndexNeedsReconciliation = false
        foldCompositionStart = nil
        (textView as? NativeTextView)?.cancelImageImports()
        tableEditingSession.retire()
        cancelFindWork()
        documentGeneration &+= 1
        nativeSourceGeneration &+= 1
        deferredRestyleScheduled = false
        textSyncGeneration &+= 1
        codeBlockSelectionGeneration &+= 1
        wtSessionGeneration &+= 1
        pendingIncomingSource = nil
        pendingIsEditable = nil
        pendingCompositionRefresh = false
        pendingPresentationRefresh = false
        wtUndoObserverTokens.forEach(NotificationCenter.default.removeObserver(_:))
        wtUndoObserverTokens.removeAll()
        wtChildWindow = nil
        wtPostUndoSnapshot = nil
        resetPerDocumentEditState(preservingReadingPosition: true)
        objectSelection = nil
        activeTokenIndices.removeAll()
        cachedParsedChars = nil
        cachedParsedDocument = nil
        cachedCodeBlockTokens.removeAll()
        cachedCodeBlockSourceGeneration = -1
        pendingPlainFastPathExpansion = nil
        lastAppliedInlineReplacementID = nil
    }

    /// Map the former token extent through the native replacement so every old
    /// rendered row is reset even when the new source no longer has that token.
    func affectedTokenParagraphs(
        in text: NSString,
        newTokens: [MarkdownToken],
        change: TextChange
    ) -> [NSRange] {
        let newRange = NSRange(location: change.oldRange.location, length: change.replacementLength)
        let newExtents = newTokens.compactMap { token -> NSRange? in
            let overlaps = NSIntersectionRange(token.range, newRange).length > 0
                || (newRange.length == 0 && newRange.location >= token.range.location
                    && newRange.location <= NSMaxRange(token.range))
            return overlaps ? token.range : nil
        }
        let oldExtents = pendingPreEditRestyleRanges.map { range -> NSRange in
            let start = range.location <= change.oldRange.location ? range.location
                : max(change.oldRange.location, range.location + change.delta)
            let end = NSMaxRange(range) < change.oldRange.location ? NSMaxRange(range)
                : max(start, NSMaxRange(range) + change.delta)
            return NSRange(location: start, length: end - start)
        }
        return (oldExtents + newExtents).flatMap { paragraphRanges(in: text, intersecting: $0) }
    }
}
