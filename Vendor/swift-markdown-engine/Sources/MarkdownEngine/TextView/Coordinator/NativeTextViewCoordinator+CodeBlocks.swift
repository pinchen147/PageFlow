//
//  NativeTextViewCoordinator+CodeBlocks.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Tracks code-block selections in the document so the host can render the
//  small "copy code" button overlay on top of every fenced code block. Skips
//  blocks the caret is currently inside (`activeTokenIndices`) to avoid the
//  button overlapping the cursor while editing.
//

import AppKit

extension NativeTextViewCoordinator {
    func scheduleCodeBlockSelectionUpdate(textView: NSTextView, tokens: [MarkdownToken]) {
        guard !isComposing(in: textView), !isWritingToolsActive else { return }
        guard onCodeBlockSelectionChange != nil else { return }
        let hasCodeBlocks = tokens.contains { $0.kind == .codeBlock }
        guard hasCodeBlocks || !cachedCodeBlockTokens.isEmpty else { return }

        codeBlockSelectionGeneration &+= 1
        let generation = codeBlockSelectionGeneration
        let ownerGeneration = documentGeneration
        let sourceGeneration = nativeSourceGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self, weak textView] in
            guard let self,
                  let textView,
                  generation == self.codeBlockSelectionGeneration,
                  ownerGeneration == self.documentGeneration,
                  sourceGeneration == self.nativeSourceGeneration,
                  !self.isComposing(in: textView) else { return }
            self.updateCodeBlockSelection(textView: textView, tokens: tokens)
        }
    }

    func updateCodeBlockSelection(textView: NSTextView, tokens: [MarkdownToken]? = nil) {
        guard !isComposing(in: textView), !isWritingToolsActive else { return }
        guard onCodeBlockSelectionChange != nil else { return }
        guard let textContainer = textView.textContainer else {
            onCodeBlockSelectionChange?([])
            return
        }

        let currentTokens = tokens ?? (cachedCodeBlockSourceGeneration != nativeSourceGeneration
            ? parsedDocument(for: textView.string).tokens : nil)
        if let currentTokens {
            cachedCodeBlockTokens = currentTokens.enumerated()
                .filter { $0.element.kind == .codeBlock }
                .map { (index: $0.offset, token: $0.element) }
            cachedCodeBlockSourceGeneration = nativeSourceGeneration
        }
        if cachedCodeBlockTokens.isEmpty {
            onCodeBlockSelectionChange?([])
            return
        }

        let documentText = textView.string
        let nsText = documentText as NSString
        let scrollOffset = textView.enclosingScrollView?.contentView.bounds.origin ?? .zero

        // One-shot full-document layout per document; fixes stale Y from TextKit 2's lazy layout without per-update cost.
        if !didEnsureLayoutForCurrentDocument, textView.textLayoutManager != nil {
            // Pin the viewport across this pass. The one-shot full-document
            // ensureLayout replaces TextKit 2's above-fold ESTIMATES with real
            // heights, shifting the document coordinate space; run UNPINNED (as
            // it was) it pans the view on the first discrete caret move after
            // each open/switch/resize — the click-jump, on ANY line. The pin
            // keeps the anchor char's on-screen Y fixed (the same treatment the
            // async wide-table reconcile already applies to its own reflow).
            if let native = textView as? NativeTextView {
                native.preservingViewportAnchor(tag: "codeBlockOneShot") {
                    native.ensureWholeNoteLayoutUnlessLong()
                }
            } else {
                textView.ensureWholeNoteLayoutUnlessLong()
            }
            didEnsureLayoutForCurrentDocument = true
        }

        let selections: [CodeBlockSelection] = cachedCodeBlockTokens.compactMap { originalIndex, token in
            guard !activeTokenIndices.contains(originalIndex),
                  token.range.location != NSNotFound, token.contentRange.location != NSNotFound,
                  NSMaxRange(token.range) <= nsText.length, NSMaxRange(token.contentRange) <= nsText.length,
                  token.markerRanges.allSatisfy({ $0.location != NSNotFound && NSMaxRange($0) <= nsText.length }) else { return nil }
            guard var boundingRect = textView.viewRect(forCharacterRange: token.range, using: layoutBridge) else { return nil }

            boundingRect.origin.x = textView.frame.origin.x + textView.textContainerOrigin.x - scrollOffset.x
            boundingRect.size.width = textContainer.containerSize.width

            return CodeBlockSelection(
                id: originalIndex,
                rect: boundingRect,
                language: MarkdownTokenizer.extractLanguage(from: token, in: documentText),
                code: nsText.substring(with: token.contentRange)
            )
        }

        onCodeBlockSelectionChange?(selections)
    }
}
