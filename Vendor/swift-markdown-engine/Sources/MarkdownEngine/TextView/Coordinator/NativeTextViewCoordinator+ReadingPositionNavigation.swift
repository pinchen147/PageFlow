import AppKit

extension NativeTextViewCoordinator {
    /// History shares the existing protected-input navigation slot, independently of
    /// heading publication. The native revision also rejects edit–Undo to equal bytes.
    func restoreWhenInputSettles(_ position: ReadingPosition, whileValid: @escaping () -> Bool,
                                didRestore: @escaping (ReadingPosition) -> Void) {
        let document = documentGeneration
        let source = nativeSourceGeneration
        weak var controller = editorController
        performNavigationWhenInputSettles { [weak self] in
            guard let self, let controller else { return }
            func ownsPresentation() -> Bool {
                self.documentGeneration == document && self.nativeSourceGeneration == source
                    && self.editorController === controller
                    && MainActor.assumeIsolated { controller.coordinator === self }
                    && self.lastDisplayed && self.textView?.window != nil
                    && self.textView?.enclosingScrollView?.isHidden == false
            }
            guard ownsPresentation(), whileValid(), ownsPresentation(),
                  let view = self.textView as? NativeTextView,
                  !self.isComposing(in: view), !self.isWritingToolsActive,
                  let departure = view.readingPosition(), view.restore(position) else { return }
            didRestore(departure)
        }
    }
}
