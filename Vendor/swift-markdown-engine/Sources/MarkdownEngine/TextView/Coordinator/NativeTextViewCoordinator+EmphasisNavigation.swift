import AppKit

extension NativeTextViewCoordinator {
    /// Map a mouse/native caret out of concealed delimiters without changing source.
    func normalizedEmphasisSelection(_ selection: NSRange, in view: NSTextView) -> NSRange {
        let selection = normalizedRichBoundarySelection(selection, in: view)
        guard !emphasisEditor.applying, !emphasisEditor.navigating, listEditor.navigation == nil, !isApplyingSpanEdit,
              !isProgrammaticEdit, !isUpdatingSourceOrStyle, !isComposing(in: view),
              pendingEditedRange == nil, let context = emphasisContext(in: view, selection: selection),
              !context.projection.hiddenDelimiterRanges.isEmpty else { return selection }
        let projection = context.projection
        func boundary(_ offset: Int, affinity: MarkdownEmphasisAffinity) -> Int {
            let local = offset - context.range.location
            let visible = projection.visibleOffset(forSourceOffset: local)
            return context.range.location + projection.sourceOffset(forVisibleOffset: visible, affinity: affinity)
        }
        if selection.length > 0 {
            // Include complete boundary delimiters in a nonempty source selection.
            // Existing formatting commands require those exact source envelopes.
            let start = boundary(selection.location, affinity: .upstream)
            let end = boundary(NSMaxRange(selection), affinity: .downstream)
            return NSRange(location: min(start, end), length: max(0, end - start))
        }
        let local = selection.location - context.range.location
        let visible = projection.visibleOffset(forSourceOffset: local)
        let up = projection.sourceOffset(forVisibleOffset: visible, affinity: .upstream)
        let down = projection.sourceOffset(forVisibleOffset: visible, affinity: .downstream)
        let upTraits = projection.traits(atSourceOffset: up)
        let downTraits = projection.traits(atSourceOffset: down)
        let chosen = downTraits.rawValue.nonzeroBitCount > upTraits.rawValue.nonzeroBitCount ? down : up
        return NSRange(location: context.range.location + chosen, length: 0)
    }

    /// Keep AppKit's anchor in visible text while Shift-arrows cross concealed style delimiters.
    func extendProseSelection(_ selector: Selector, in view: NSTextView) -> Bool {
        guard [#selector(NSResponder.moveLeftAndModifySelection(_:)), #selector(NSResponder.moveRightAndModifySelection(_:)),
               #selector(NSResponder.moveForwardAndModifySelection(_:)), #selector(NSResponder.moveBackwardAndModifySelection(_:))]
            .contains(selector), !emphasisEditor.navigating, !emphasisEditor.applying, !isComposing(in: view),
              !isWritingToolsActive, let context = emphasisContext(in: view),
              context.projection.tokens.allSatisfy({ $0.kind == .backslashEscape || !MarkdownEmphasisTraits(kind: $0.kind).isEmpty }),
              !context.projection.tokens.isEmpty else { return false }
        let selection = view.selectedRange()
        let state = emphasisEditor
        let navigator = state.selectionNavigator
        let cached = state.keyboardSelectionContext
        let sameBlock = cached?.document == context.document && cached?.range.location == context.range.location
        let projected: MarkdownEmphasisEditorState.Context
        let retainAnchor: Bool
        if let cached, sameBlock, cached.generation == context.generation, cached.range == context.range {
            projected = cached
            retainAnchor = state.lastSelection == selection
        } else {
            projected = typingContext(context, hidesEscapes: true)
            // Formatting can replace every source delimiter while the selected
            // visible text and AppKit's active edge stay exactly the same.
            retainAnchor = sameBlock && selection.length > 0
                && navigator.string.utf16.elementsEqual(projected.projection.visibleText.utf16)
        }
        let projection = projected.projection
        let start = projection.visibleOffset(forSourceOffset: selection.location - context.range.location)
        let end = projection.visibleOffset(forSourceOffset: NSMaxRange(selection) - context.range.location)
        let visible = NSRange(location: start, length: end - start)
        if !retainAnchor || navigator.selectedRange() != visible {
            navigator.string = projection.visibleText
            navigator.baseWritingDirection = view.baseWritingDirection
            navigator.setSelectedRange(visible, affinity: view.selectionAffinity, stillSelecting: false)
        }
        navigator.doCommand(by: selector)
        let moved = navigator.selectedRange()
        guard moved != visible else { return false }
        let lower = projection.sourceOffset(forVisibleOffset: moved.location, affinity: .upstream)
        let upper = moved.length == 0 ? lower : projection.sourceOffset(forVisibleOffset: NSMaxRange(moved), affinity: .downstream)
        state.typingRun = nil
        state.typing.adopt()
        state.navigating = true
        view.setSelectedRange(NSRange(location: context.range.location + lower, length: upper - lower),
                              affinity: navigator.selectionAffinity, stillSelecting: false)
        state.navigating = false
        state.keyboardSelectionContext = projected
        state.lastSelection = view.selectedRange()
        textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view))
        return true
    }

    func handleEmphasisCommand(_ selector: Selector, in view: NSTextView) -> Bool? {
        guard !emphasisEditor.navigating, !emphasisEditor.applying, !isComposing(in: view),
              !isWritingToolsActive, let context = emphasisContext(in: view),
              !context.projection.hiddenDelimiterRanges.isEmpty else { return nil }
        let command = NSStringFromSelector(selector)
        let projection = context.projection
        let selection = view.selectedRange()
        let localStart = selection.location - context.range.location
        let start = projection.visibleOffset(forSourceOffset: localStart)
        let end = projection.visibleOffset(forSourceOffset: localStart + selection.length)
        if command == "deleteBackward:" || command == "deleteForward:"
            || command == "deleteWordBackward:" || command == "deleteWordForward:" {
            guard view.isEditable else { return true }
            var range = NSRange(location: start, length: end - start)
            if range.length == 0 {
                let backward = command.contains("Backward")
                let destination: Int
                if command.contains("Word") {
                    let navigator = emphasisEditor.wordNavigator
                    navigator.string = projection.visibleText
                    navigator.setSelectedRange(NSRange(location: start, length: 0))
                    navigator.doCommand(by: NSSelectorFromString(backward ? "moveWordBackward:" : "moveWordForward:"))
                    destination = navigator.selectedRange().location
                } else { destination = projection.nextVisibleOffset(from: start, direction: backward ? -1 : 1) }
                range = NSRange(location: min(start, destination), length: abs(start - destination))
            }
            if range.length == 0 {
                let text = (view.textStorage?.mutableString ?? NSMutableString(string: ""))
                let boundary = command.contains("Backward") ? context.range.location : NSMaxRange(context.range)
                if command.contains("Backward"), boundary > 0 {
                    view.insertText("", replacementRange: text.rangeOfComposedCharacterSequence(at: boundary - 1))
                } else if !command.contains("Backward"), boundary < text.length {
                    view.insertText("", replacementRange: text.rangeOfComposedCharacterSequence(at: boundary))
                }
                return true
            }
            let traits = emphasisTraits(in: view)
            guard let plan = MarkdownEmphasisEditPlanner.deletion(visibleRange: range, projection: projection) else { return nil }
            _ = performEmphasisEdit(plan, context: context, traits: traits, in: view)
            return true
        }
        guard command.hasPrefix("move") else { return nil }
        emphasisEditor.typingRun = nil
        emphasisEditor.typing.adopt()
        // Word boundaries belong to visible text. A derived native text view uses
        // AppKit's word/bidi rules without treating Markdown punctuation as a word.
        if command.contains("Word") {
            let navigator = emphasisEditor.wordNavigator
            navigator.string = projection.visibleText
            navigator.baseWritingDirection = view.baseWritingDirection
            navigator.setSelectedRange(NSRange(location: start, length: end - start),
                                       affinity: view.selectionAffinity, stillSelecting: false)
            navigator.doCommand(by: selector)
            let moved = navigator.selectedRange()
            if moved == NSRange(location: start, length: end - start), selection.length == 0 {
                // At a local block edge, let the native document command cross
                // the separator, then normalize any concealed destination.
                emphasisEditor.navigating = true
                let limit = projection.hiddenDelimiterRanges.reduce(2) { $0 + $1.length }
                for _ in 0..<limit {
                    let before = view.selectedRange()
                    view.doCommand(by: selector)
                    let after = view.selectedRange()
                    if after == before || after.location < context.range.location || after.location > NSMaxRange(context.range) { break }
                    if projection.visibleOffset(forSourceOffset: after.location - context.range.location) != start { break }
                }
                emphasisEditor.navigating = false
                let normalized = normalizedEmphasisSelection(view.selectedRange(), in: view)
                emphasisEditor.navigating = true
                view.setSelectedRange(normalized)
                emphasisEditor.navigating = false
                emphasisEditor.lastSelection = view.selectedRange()
                textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view))
                return true
            }
            let sourceStart = projection.sourceOffset(forVisibleOffset: moved.location, affinity: .downstream)
            let sourceEnd = projection.sourceOffset(forVisibleOffset: NSMaxRange(moved), affinity: .upstream)
            emphasisEditor.navigating = true
            view.setSelectedRange(NSRange(location: context.range.location + sourceStart,
                length: max(0, sourceEnd - sourceStart)), affinity: navigator.selectionAffinity, stillSelecting: false)
            emphasisEditor.navigating = false
            let normalized = normalizedEmphasisSelection(view.selectedRange(), in: view)
            emphasisEditor.navigating = true
            view.setSelectedRange(normalized)
            emphasisEditor.navigating = false
        } else {
            // Preserve native visual arrows, wrapped lines, bidi and selection anchors.
            // Repeat only while an arrow traverses concealed source with no visible step.
            emphasisEditor.navigating = true
            let limit = projection.hiddenDelimiterRanges.reduce(2) { $0 + $1.length }
            for _ in 0..<limit {
                let before = view.selectedRange()
                view.doCommand(by: selector)
                let after = view.selectedRange()
                guard after != before else { break }
                let local = after.location - context.range.location
                guard local >= 0, NSMaxRange(after) <= NSMaxRange(context.range) else { break }
                let visibleStart = projection.visibleOffset(forSourceOffset: local)
                let visibleEnd = projection.visibleOffset(forSourceOffset: local + after.length)
                if visibleStart != start || visibleEnd != end { break }
            }
            emphasisEditor.navigating = false
            let normalized = normalizedEmphasisSelection(view.selectedRange(), in: view)
            emphasisEditor.navigating = true
            if normalized != view.selectedRange() { view.setSelectedRange(normalized) }
            emphasisEditor.navigating = false
        }
        emphasisEditor.lastSelection = view.selectedRange()
        textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view))
        return true
    }
}
