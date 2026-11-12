import AppKit

extension NativeTextViewCoordinator {
    /// Remember only the precomposition block and intent. Provisional text stays
    /// entirely under the input method's control until it commits or cancels.
    func beginEmphasisComposition(replacing range: NSRange, in view: NSTextView) {
        guard emphasisEditor.composition == nil, !isWritingToolsActive,
              let context = emphasisContext(in: view, selection: range) else { return }
        let local = range.location - context.range.location
        let inherited = range.length == 0 ? context.projection.traits(atSourceOffset: local)
            : context.projection.traits(atVisibleOffset: context.projection.visibleOffset(forSourceOffset: local), affinity: .downstream)
        let traits = emphasisEditor.typing.effectiveTraits(inheriting: inherited)
        guard !traits.isEmpty || !context.projection.hiddenDelimiterRanges.isEmpty else { return }
        emphasisEditor.typingRun = nil
        emphasisEditor.composition = .init(context: context, selection: range, traits: traits, typing: emphasisEditor.typing)
    }

    func finishEmphasisComposition(in view: NSTextView) {
        guard !isComposing(in: view), let composition = emphasisEditor.composition else { return }
        emphasisEditor.composition = nil
        guard pendingIncomingSource == nil, composition.context.document == documentGeneration,
              let storage = view.textStorage else { return }
        let initial = composition.context
        let start = composition.selection.location
        let end = view.selectedRange().location
        guard end >= start, end <= storage.length else { return }
        let text = storage.mutableString.substring(with: NSRange(location: start, length: end - start))
        let local = NSRange(location: start - initial.range.location, length: composition.selection.length)
        let current = (initial.projection.source as NSString).replacingCharacters(in: local, with: text)
        let currentRange = NSRange(location: initial.range.location, length: current.utf16.count)
        guard NSMaxRange(currentRange) <= storage.length,
              (storage.mutableString.substring(with: currentRange) as NSString).isEqual(to: current) else { return }
        // Cancellation that restores the original source is a presentation-only change.
        guard !(current as NSString).isEqual(to: initial.projection.source) else { return }
        let plan: MarkdownEmphasisEditPlan?
        if local.length == 0 {
            plan = MarkdownEmphasisEditPlanner.insertion(text: text, atSourceOffset: local.location,
                traits: composition.traits, projection: initial.projection)
        } else {
            let first = initial.projection.visibleOffset(forSourceOffset: local.location)
            let last = initial.projection.visibleOffset(forSourceOffset: NSMaxRange(local))
            plan = MarkdownEmphasisEditPlanner.replacement(text: text,
                visibleRange: NSRange(location: first, length: last - first), traits: composition.traits,
                projection: initial.projection)
        }
        let desired = plan.map { (initial.projection.source as NSString).replacingCharacters(in: $0.replacementRange, with: $0.replacement) } ?? current
        let selection = plan.map { NSRange(location: initial.range.location + $0.selectionAfter.location, length: 0) } ?? view.selectedRange()
        var edit = SpanEdit(range: currentRange, replacement: desired,
            selectionAfter: selection,
            actionName: "Typing", mapLocation: Self.paragraphPreservingMap(from: current, to: desired, spanStart: currentRange.location),
            inverseSelection: view.selectedRange())
        edit.registersUndo = false
        if !(desired as NSString).isEqual(to: current) {
            emphasisEditor.applying = true
            _ = performSpanEdit(edit, in: view)
            emphasisEditor.applying = false
        }
        if let undo = view.undoManager {
            let ownsGroup = undo.groupingLevel == 0
            if ownsGroup { undo.beginUndoGrouping() }
            undo.registerUndo(withTarget: self) { coordinator in
                guard let view = coordinator.textView else { return }
                let finalRange = NSRange(location: initial.range.location, length: desired.utf16.count)
                let inverse = SpanEdit(range: finalRange, replacement: initial.projection.source,
                    selectionAfter: composition.selection, actionName: "Typing",
                    mapLocation: Self.paragraphPreservingMap(from: desired, to: initial.projection.source, spanStart: initial.range.location),
                    inverseSelection: selection, emphasisTyping: composition.typing)
                _ = coordinator.performSpanEdit(inverse, in: view)
            }
            undo.setActionName("Typing")
            if ownsGroup { undo.endUndoGrouping() }
        }
        emphasisEditor.typing.retainTypingTraits(composition.traits)
        emphasisEditor.lastSelection = view.selectedRange()
        emphasisEditor.cache = nil
    }
}
