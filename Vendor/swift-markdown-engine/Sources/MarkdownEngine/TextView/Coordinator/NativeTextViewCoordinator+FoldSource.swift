import AppKit

extension NativeTextViewCoordinator {
    /// Native typing Undo edits storage before NSTextView repairs its selection,
    /// and can publish textDidChange later. Writing Tools also issues successive
    /// source replacements before final styling. Map visibility before either repair.
    func observeFoldSource(in view: NativeTextView) {
        if let foldStorageObserver { NotificationCenter.default.removeObserver(foldStorageObserver) }
        foldStorageObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.willProcessEditingNotification, object: view.textStorage, queue: nil
        ) { [weak self, weak view] notification in
            guard let self, let view, let storage = notification.object as? NSTextStorage,
                  view === self.textView, storage.editedMask.contains(.editedCharacters),
                  self.isWritingToolsActive || view.undoManager?.isUndoing == true || view.undoManager?.isRedoing == true,
                  self.pendingTextChange == nil, !self.isUpdatingSourceOrStyle,
                  !self.isComposing(in: view), self.foldBoundSession === self.foldSession else { return }
            let writingTools = self.isWritingToolsActive
            guard writingTools ? self.wtStartDocumentId == self.documentId
                : self.foldSourceGeneration == self.nativeSourceGeneration else { return }
            let newRange = storage.editedRange
            let oldLength = newRange.length - storage.changeInLength
            guard newRange.location != NSNotFound, oldLength >= 0,
                  NSMaxRange(newRange) <= storage.length else { return }
            let oldRange = NSRange(location: newRange.location, length: oldLength)
            let replacement = storage.mutableString.substring(with: newRange)
            let edit = TextChange(oldRange: oldRange, replacement: replacement)
            guard self.mapFoldSourceEdit(edit, resultingLength: storage.length) else { return }
            self.foldLayout.hiddenRanges = self.foldSession.hiddenRanges
            self.foldControls?.setNeedsRefresh()
            if writingTools {
                // Accepted source notifications are authoritative during a Writing Tools
                // session; its delegate still owns generation and final presentation.
                self.foldIndexNeedsReconciliation = true
                return
            }
            self.nativeSourceGeneration &+= 1
            self.foldSourceGeneration = self.nativeSourceGeneration
            // Never enter TextKit layout from willProcessEditing.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.applyFoldPresentation()
                self.scheduleFoldIndex()
            }
        }
    }
}
