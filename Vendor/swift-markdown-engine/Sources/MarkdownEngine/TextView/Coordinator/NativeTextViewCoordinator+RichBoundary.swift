import AppKit

struct MarkdownRichBoundaryContext {
    let generation: Int
    let document: Int
    let range: NSRange
    let aliases: Bool
    let diagramLanguages: Set<String>
    let intentRange: NSRange?
    let intentKind: MarkdownTokenKind?
    let intentDocument: Int?
    let intentSource: Int?
    let index: MarkdownRichBoundaryIndex
    let tokens: [MarkdownToken]

    func touchesCollapsedContent(_ selection: NSRange, owner: NativeTextViewCoordinator, view: NSTextView) -> Bool {
        tokens.contains { token in
            let rendered = token.kind == .inlineLatex || token.kind == .blockLatex
                || (token.kind == .codeBlock && MarkdownTokenKind.isHeightBanded(token, in: index.source,
                    diagramLanguages: diagramLanguages))
            let touched = selection.length == 0 ? NSLocationInRange(selection.location, token.range)
                : NSIntersectionRange(selection, token.range).length > 0
            guard touched, rendered || token.kind == .imageLink || token.kind == .imageEmbed,
                  let storage = view.textStorage else { return false }
            var hasImage = false
            let global = NSRange(location: range.location + token.range.location, length: token.range.length)
            guard global.location >= 0, NSMaxRange(global) <= storage.length else { return true }
            storage.enumerateAttribute(.renderedBlockImage, in: global) { value, _, stop in
                if value is NSImage { hasImage = true; stop.pointee = true }
            }
            guard hasImage else { return false }
            if token.kind == .imageLink || token.kind == .imageEmbed { return true }
            return !owner.isEditingRenderedSource(token.shifted(by: range.location), in: view)
        }
    }
}

extension NativeTextViewCoordinator {
    func richBoundaryIsExplicitTableSource(in view: NSTextView, selection: NSRange) -> Bool {
        guard let location = tableEditingSession.revealedSourceTableLocation,
              let source = view.textStorage?.mutableString, selection.location != NSNotFound,
              selection.location >= 0, NSMaxRange(selection) <= source.length else { return false }
        let region = emphasisBlockRegion(around: selection, in: source)
        return location >= region.location && location < NSMaxRange(region)
    }

    func richBoundaryContext(in view: NSTextView, selection: NSRange? = nil) -> MarkdownRichBoundaryContext? {
        guard view === textView, !isApplyingSpanEdit, !isUpdatingSourceOrStyle, !isProgrammaticEdit,
              !isComposing(in: view), !isWritingToolsActive, !tableEditingSession.isActive,
              let storage = view.textStorage else { return nil }
        let selection = selection ?? view.selectedRange()
        guard selection.location != NSNotFound, selection.location >= 0, NSMaxRange(selection) <= storage.length,
              !richBoundaryIsExplicitTableSource(in: view, selection: selection) else { return nil }
        if let cache = emphasisEditor.richBoundaryCache, cache.generation == nativeSourceGeneration,
           cache.document == documentGeneration, cache.aliases == configuration.link.wikiLinkAliases,
           cache.diagramLanguages == configuration.diagramLanguages,
           cache.intentRange == renderedSourceIntent?.range, cache.intentKind == renderedSourceIntent?.kind,
           cache.intentDocument == renderedSourceIntent?.document, cache.intentSource == renderedSourceIntent?.source,
           selection.location >= cache.range.location, NSMaxRange(selection) <= NSMaxRange(cache.range) {
            let local = NSRange(location: selection.location - cache.range.location, length: selection.length)
            return cache.touchesCollapsedContent(local, owner: self, view: view) ? nil : cache
        }
        let text = storage.mutableString
        var region = emphasisBlockRegion(around: selection, in: text)
        // Only a source-admitted document snapshot may extend a local window across an opaque fence.
        if let chars = cachedParsedChars, utf16(chars, equals: text), plainInsertionsSinceParse.isEmpty,
           let parsed = cachedParsedDocument,
           let fence = parsed.codeTokens.first(where: { $0.kind == .codeBlock
               && selection.location >= $0.range.location && NSMaxRange(selection) <= NSMaxRange($0.range) }) {
            region = NSUnionRange(region, fence.range)
        }
        let source = text.substring(with: region)
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: source, memoizing: false)
        let local = NSRange(location: selection.location - region.location, length: selection.length)
        // Refuse to reinterpret an opaque source fragment if its enclosing fence is not admitted yet.
        if selection.location < storage.length,
           (storage.attribute(.markdownCode, at: selection.location, effectiveRange: nil) as? Int ?? 0) > 0,
           !tokens.contains(where: { [.inlineCode, .codeBlock].contains($0.kind)
               && local.location >= $0.range.location && NSMaxRange(local) <= NSMaxRange($0.range) }) { return nil }
        let index = MarkdownRichBoundaryIndex(source: source, tokens: tokens,
            aliases: configuration.link.wikiLinkAliases)
        guard index.hasRichSyntax else { return nil }
        let result = MarkdownRichBoundaryContext(generation: nativeSourceGeneration, document: documentGeneration,
            range: region, aliases: configuration.link.wikiLinkAliases, diagramLanguages: configuration.diagramLanguages,
            intentRange: renderedSourceIntent?.range, intentKind: renderedSourceIntent?.kind,
            intentDocument: renderedSourceIntent?.document, intentSource: renderedSourceIntent?.source,
            index: index, tokens: tokens)
        guard !result.touchesCollapsedContent(local, owner: self, view: view) else { return nil }
        emphasisEditor.richBoundaryCache = result
        return result
    }

    func normalizedRichBoundarySelection(_ selection: NSRange, in view: NSTextView) -> NSRange {
        guard !emphasisEditor.navigating, !emphasisEditor.applying, pendingEditedRange == nil,
              let context = richBoundaryContext(in: view, selection: selection) else { return selection }
        let local = NSRange(location: selection.location - context.range.location, length: selection.length)
        guard context.index.owns(local) else { return selection }
        let normalized = context.index.normalized(local)
        return NSRange(location: context.range.location + normalized.location, length: normalized.length)
    }

    func applyRichBoundaryInput(_ replacement: String, range: NSRange, in view: NSTextView) -> Bool {
        guard !emphasisEditor.applying, !isLiteralInsertion, !pendingInlineFormattingEdit,
              view.isEditable, view.undoManager?.isUndoing != true, view.undoManager?.isRedoing != true,
              let context = richBoundaryContext(in: view, selection: range) else { return false }
        let local = NSRange(location: range.location - context.range.location, length: range.length)
        guard context.index.owns(local) else { return false }
        if !emphasisEditor.typing.enabled.isEmpty || !emphasisEditor.typing.disabled.isEmpty { return false }
        if range.length == 0 {
            let emphasis = MarkdownEmphasisProjection(source: context.index.source, tokens: context.tokens)
            if !emphasis.traits(atSourceOffset: local.location).isEmpty { return false }
        }
        let visible = context.index.visibleRange(local)
        let anchor = local.length == 0 ? context.index.normalized(local).location : nil
        guard let edit = context.index.replacement(visible, with: replacement, sourceAnchor: anchor) else { return true }
        let nativeSelection = NSRange(location: range.location + replacement.utf16.count, length: 0)
        let sourceRange = NSRange(location: context.range.location + edit.range.location, length: edit.range.length)
        let sourceSelection = NSRange(location: context.range.location + edit.selection.location, length: edit.selection.length)
        if sourceRange == range, sourceSelection == nativeSelection,
           edit.replacement.utf16.elementsEqual(replacement.utf16) {
            return false
        }
        applyRichBoundaryEdit(edit, context: context, inverseSelection: view.selectedRange(), action: "Typing")
        return true
    }

    private func applyRichBoundaryEdit(_ edit: MarkdownSourceEdit, context: MarkdownRichBoundaryContext,
                                       inverseSelection: NSRange, action: String) {
        applySourceFormat(action, inverseSelection: inverseSelection) { _, _ in
            MarkdownSourceEdit(range: NSRange(location: context.range.location + edit.range.location, length: edit.range.length),
                replacement: edit.replacement,
                selection: NSRange(location: context.range.location + edit.selection.location, length: edit.selection.length))
        }
    }

    func handleRichBoundaryCommand(_ selector: Selector, in view: NSTextView) -> Bool? {
        guard !emphasisEditor.navigating, !emphasisEditor.applying,
              let context = richBoundaryContext(in: view) else { return nil }
        let local = NSRange(location: view.selectedRange().location - context.range.location,
                            length: view.selectedRange().length)
        let command = NSStringFromSelector(selector)
        if !context.index.owns(local) {
            guard command.hasPrefix("move"), context.index.ownsNavigation(local) else { return nil }
            let start = max(0, local.location - 1)
            let end = min((context.index.source as NSString).length, NSMaxRange(local) + 1)
            guard !context.touchesCollapsedContent(NSRange(location: start, length: end - start),
                owner: self, view: view) else { return nil }
        }
        let selection = context.index.visibleRange(local)
        if ["deleteBackward:", "deleteForward:", "deleteWordBackward:", "deleteWordForward:"].contains(command) {
            guard view.isEditable else { return true }
            var range = selection
            if range.length == 0 {
                let backward = command.contains("Backward")
                let next: Int
                if command.contains("Word") {
                    let navigator = emphasisEditor.wordNavigator
                    navigator.string = context.index.visible as String
                    navigator.baseWritingDirection = view.baseWritingDirection
                    navigator.setSelectedRange(range)
                    navigator.doCommand(by: NSSelectorFromString(backward ? "moveWordBackward:" : "moveWordForward:"))
                    next = navigator.selectedRange().location
                } else { next = context.index.nextVisibleOffset(range.location, backward: backward) }
                range = NSRange(location: min(range.location, next), length: abs(next - range.location))
            }
            if range.length == 0 {
                let boundary = command.contains("Backward") ? context.range.location : NSMaxRange(context.range)
                let length = (view.string as NSString).length
                if command.contains("Backward"), boundary > 0 {
                    view.insertText("", replacementRange: (view.string as NSString).rangeOfComposedCharacterSequence(at: boundary - 1))
                } else if !command.contains("Backward"), boundary < length {
                    view.insertText("", replacementRange: (view.string as NSString).rangeOfComposedCharacterSequence(at: boundary))
                }
                return true
            }
            if let edit = context.index.replacement(range, with: "") {
                applyRichBoundaryEdit(edit, context: context, inverseSelection: view.selectedRange(), action: "Delete")
            }
            return true
        }
        guard command.hasPrefix("move") else { return nil }
        emphasisEditor.typingRun = nil
        emphasisEditor.typing.adopt()
        emphasisEditor.navigating = true
        if command.contains("Word") {
            let navigator = emphasisEditor.wordNavigator
            navigator.string = context.index.visible as String
            navigator.baseWritingDirection = view.baseWritingDirection
            navigator.setSelectedRange(selection, affinity: view.selectionAffinity, stillSelecting: false)
            navigator.doCommand(by: selector)
            let moved = navigator.selectedRange()
            if moved == selection && selection.length == 0 {
                moveRichBoundaryNatively(selector, context: context, initial: selection, in: view)
            } else {
                let start = context.index.sourceOffset(moved.location, downstream: true)
                let end = moved.length == 0 ? start : context.index.sourceOffset(NSMaxRange(moved), downstream: false)
                view.setSelectedRange(NSRange(location: context.range.location + start, length: max(0, end - start)),
                                      affinity: navigator.selectionAffinity, stillSelecting: false)
            }
        } else {
            moveRichBoundaryNatively(selector, context: context, initial: selection, in: view)
        }
        let after = view.selectedRange()
        if after.location >= context.range.location, NSMaxRange(after) <= NSMaxRange(context.range) {
            let normalized = context.index.normalized(NSRange(location: after.location - context.range.location, length: after.length))
            let final = NSRange(location: context.range.location + normalized.location, length: normalized.length)
            if final != after { view.setSelectedRange(final) }
        }
        emphasisEditor.navigating = false
        emphasisEditor.lastSelection = view.selectedRange()
        textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view))
        return true
    }
    private func moveRichBoundaryNatively(_ selector: Selector, context: MarkdownRichBoundaryContext,
                                           initial: NSRange, in view: NSTextView) {
        let horizontal = ["moveLeft:", "moveRight:", "moveBackward:", "moveForward:",
                          "moveLeftAndModifySelection:", "moveRightAndModifySelection:",
                          "moveBackwardAndModifySelection:", "moveForwardAndModifySelection:"]
        var expected: NSRange?
        if horizontal.contains(NSStringFromSelector(selector)) {
            let navigator = emphasisEditor.wordNavigator
            navigator.string = context.index.visible as String
            navigator.baseWritingDirection = view.baseWritingDirection
            navigator.setSelectedRange(initial, affinity: view.selectionAffinity, stillSelecting: false)
            navigator.doCommand(by: selector)
            let projected = navigator.selectedRange()
            if projected != initial || (context.range.location == 0 && NSMaxRange(context.range) == (view.string as NSString).length) {
                expected = projected
            }
        }
        emphasisEditor.richBoundarySelectionProposal = { before, proposed in
            guard before.location >= context.range.location, NSMaxRange(before) <= NSMaxRange(context.range),
                  proposed.location >= context.range.location, NSMaxRange(proposed) <= NSMaxRange(context.range) else { return proposed }
            let localBefore = NSRange(location: before.location - context.range.location, length: before.length)
            let localProposed = NSRange(location: proposed.location - context.range.location, length: proposed.length)
            if NSStringFromSelector(selector).contains("AndModifySelection"),
               context.index.visibleRange(localProposed) == initial,
               let endpoints = context.index.extendingEndpoints(from: localBefore, to: localProposed) {
                let navigator = self.emphasisEditor.wordNavigator
                navigator.string = context.index.visible as String
                navigator.baseWritingDirection = view.baseWritingDirection
                navigator.setSelectedRange(NSRange(location: context.index.visibleOffset(endpoints.active), length: 0),
                    affinity: view.selectionAffinity, stillSelecting: false)
                let move = NSStringFromSelector(selector).replacingOccurrences(of: "AndModifySelection", with: "")
                navigator.doCommand(by: NSSelectorFromString(move))
                let visibleActive = navigator.selectedRange().location
                if visibleActive != context.index.visibleOffset(endpoints.active) {
                    let active = context.index.sourceOffset(visibleActive, downstream: true)
                    return NSRange(location: context.range.location + min(endpoints.anchor, active),
                        length: abs(active - endpoints.anchor))
                }
            }
            let admitted = context.index.nativeMovementProposal(from: localBefore, to: localProposed,
                initialVisible: initial, expectedVisible: expected)
            return NSRange(location: context.range.location + admitted.location, length: admitted.length)
        }
        defer { emphasisEditor.richBoundarySelectionProposal = nil }
        for _ in 0..<context.index.movementLimit {
            let before = view.selectedRange()
            view.doCommand(by: selector)
            let after = view.selectedRange()
            guard after != before, after.location >= context.range.location,
                  NSMaxRange(after) <= NSMaxRange(context.range) else { break }
            let moved = context.index.visibleRange(NSRange(location: after.location - context.range.location, length: after.length))
            if moved != initial { break }
        }
    }

}
