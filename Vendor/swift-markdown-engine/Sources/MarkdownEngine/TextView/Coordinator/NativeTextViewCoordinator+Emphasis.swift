import AppKit

/// Native adapters keep Markdown authoritative; this state holds only view-local intent
/// and a bounded, revision-keyed projection of the current block.
final class MarkdownEmphasisEditorState: NSObject, NSTextViewDelegate {
    var typing = MarkdownEmphasisTypingState()
    var cache: Context?
    var richBoundaryCache: MarkdownRichBoundaryContext?
    var richBoundarySelectionProposal: ((NSRange, NSRange) -> NSRange)?
    var applying = false
    var navigating = false
    var lastSelection: NSRange?
    var typingRun: TypingRun?
    var composition: Composition?
    struct Composition {
        let context: Context
        let selection: NSRange
        let traits: MarkdownEmphasisTraits
        let typing: MarkdownEmphasisTypingState
    }
    lazy var selectionNavigator: NSTextView = {
        let navigator = NSTextView(frame: .zero)
        navigator.delegate = self
        return navigator
    }()

    // Mirror the editor's single-range delegate so AppKit resolves visual
    // selection through bidirectional runs the same way in both views.
    func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange oldRange: NSRange,
                  toCharacterRange newRange: NSRange) -> NSRange { newRange }

    var keyboardSelectionContext: Context?
    lazy var wordNavigator = NSTextView(frame: .zero)

    struct Context {
        let generation: Int
        let document: Int
        let range: NSRange
        let projection: MarkdownEmphasisProjection
    }

    final class TypingRun {
        let location: Int
        let original: String
        let selection: NSRange
        let typing: MarkdownEmphasisTypingState
        var length: Int
        var caret: Int
        var timestamp = Date.timeIntervalSinceReferenceDate
        init(range: NSRange, source: String, selection: NSRange, typing: MarkdownEmphasisTypingState) {
            self.typing = typing
            location = range.location
            length = range.length
            original = source
            self.selection = selection
            caret = selection.location
        }
    }
}

extension NativeTextViewCoordinator {
    func emphasisContext(in view: NSTextView, selection: NSRange? = nil) -> MarkdownEmphasisEditorState.Context? {
        guard !isApplyingSpanEdit, !isUpdatingSourceOrStyle, !isProgrammaticEdit,
              let storage = view.textStorage else { return nil }
        let selection = selection ?? view.selectedRange()
        guard !richBoundaryIsExplicitTableSource(in: view, selection: selection) else { return nil }
        guard selection.location != NSNotFound, selection.location >= 0,
              NSMaxRange(selection) <= storage.length else { return nil }
        if let cache = emphasisEditor.cache, cache.generation == nativeSourceGeneration,
           cache.document == documentGeneration, selection.location >= cache.range.location,
           NSMaxRange(selection) <= NSMaxRange(cache.range) { return cache }
        let text = storage.mutableString
        // Native Undo/Redo can leave an older parsed snapshot while storage is current.
        // Reuse token coordinates only when their exact source is still admitted.
        let parsedMatchesSource = cachedParsedChars.map { utf16($0, equals: text) } == true
        // The document parse supplies enclosing opaque context even when a fence
        // contains blank lines that lie beyond the local projection window.
        if let parsed = cachedParsedDocument, parsedMatchesSource, plainInsertionsSinceParse.isEmpty {
            for tokens in [parsed.codeTokens, parsed.latexTokens] {
                var low = 0, high = tokens.count
                while low < high {
                    let middle = (low + high) / 2
                    if tokens[middle].range.location <= selection.location { low = middle + 1 } else { high = middle }
                }
                if low > 0, NSLocationInRange(selection.location, tokens[low - 1].range) { return nil }
            }
        } else if let snapshot = cachedBlockParse {
            // A stale block snapshot is not used as an admission decision.
            if cachedBlockParseRevision?.source == nativeSourceGeneration,
               cachedBlockParseRevision?.document == documentGeneration,
               !snapshot.blocks.isEmpty {
                var low = 0, high = snapshot.blocks.count
                while low < high {
                    let middle = (low + high) / 2
                    if NSMaxRange(snapshot.blocks[middle].range) <= selection.location { low = middle + 1 } else { high = middle }
                }
                if low < snapshot.blocks.count {
                    let block = snapshot.blocks[low]
                    if block.kind == .fencedCode || block.kind == .blockLatex { return nil }
                }
            }
        }
        let region = emphasisBlockRegion(around: selection, in: text)
        let source = text.substring(with: region)
        // A block window includes soft newlines, unlike a physical-line tokenize.
        // Reuse admitted document tokens when available, preserving enclosing code context.
        let tokens: [MarkdownToken]
        if let cached = cachedParsedDocument, parsedMatchesSource,
           plainInsertionsSinceParse.isEmpty {
            var low = 0, high = cached.tokens.count
            while low < high {
                let middle = (low + high) / 2
                if cached.tokens[middle].range.location < region.location { low = middle + 1 } else { high = middle }
            }
            var localTokens: [MarkdownToken] = []
            while low < cached.tokens.count, cached.tokens[low].range.location < NSMaxRange(region) {
                let token = cached.tokens[low]
                if NSMaxRange(token.range) <= NSMaxRange(region) {
                    func local(_ r: NSRange) -> NSRange { NSRange(location: r.location - region.location, length: r.length) }
                    localTokens.append(MarkdownToken(kind: token.kind, range: local(token.range), contentRange: local(token.contentRange),
                        markerRanges: token.markerRanges.map(local)))
                }
                low += 1
            }
            tokens = localTokens
        } else {
            tokens = MarkdownTokenizer.parseTokensViaAST(in: source, memoizing: false)
        }
        let context = MarkdownEmphasisEditorState.Context(generation: nativeSourceGeneration, document: documentGeneration,
            range: region, projection: MarkdownEmphasisProjection(source: source, tokens: tokens))
        emphasisEditor.cache = context
        return context
    }

    func emphasisBlockRegion(around selection: NSRange, in text: NSString) -> NSRange {
        // Lists have independent inline bodies. A caret must not project every
        // item in a large list just to normalize one concealed delimiter.
        if selection.length == 0, let view = textView,
           let item = unorderedListPrefix(at: selection.location, in: view) { return item.line }
        if let snapshot = cachedBlockParse, cachedBlockParseRevision?.source == nativeSourceGeneration,
           cachedBlockParseRevision?.document == documentGeneration, snapshot.characters.count == text.length, !snapshot.blocks.isEmpty {
            let blocks = snapshot.blocks
            var low = 0, high = blocks.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(blocks[middle].range) < selection.location { low = middle + 1 } else { high = middle }
            }
            var region = selection
            while low < blocks.count, blocks[low].range.location <= NSMaxRange(selection) {
                region = NSUnionRange(region, blocks[low].range)
                low += 1
            }
            return region
        }
        // The parse may be deferred after plain input. Scan only this inline block
        // through its separator rather than truncating an enclosing emphasis span.
        func separator(endingAt end: Int) -> Bool {
            guard end >= 2 else { return false }
            let a = text.character(at: end - 2), b = text.character(at: end - 1)
            if (a == 10 && b == 10) || (a == 13 && b == 13) { return true }
            return end >= 4 && text.character(at: end - 4) == 13
                && text.character(at: end - 3) == 10 && a == 13 && b == 10
        }
        var start = selection.location, end = NSMaxRange(selection)
        while start > 0, !separator(endingAt: start) { start -= 1 }
        // The preceding separator starts this block; it cannot also end an empty caret region.
        if start == end, end < text.length { end += 1 }
        while end < text.length, !separator(endingAt: end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    func typingContext(_ context: MarkdownEmphasisEditorState.Context, hidesEscapes: Bool = false) -> MarkdownEmphasisEditorState.Context {
        let projection = context.projection
        return .init(generation: context.generation, document: context.document, range: context.range,
            projection: MarkdownEmphasisProjection(source: projection.source, tokens: projection.tokens,
                scope: projection.scope, includesDecorations: true, hidesEscapes: hidesEscapes))
    }

    func emphasisTraits(in view: NSTextView) -> MarkdownEmphasisTraits {
        guard let context = emphasisContext(in: view) else {
            return emphasisEditor.typing.effectiveTraits(inheriting: [])
        }
        return emphasisEditor.typing.effectiveTraits(inheriting: typingContext(context).projection.traits(
            atSourceOffset: view.selectedRange().location - context.range.location))
    }

    func toggleEmphasis(_ style: MarkdownInlineStyle, in view: NSTextView) -> Bool {
        let trait = MarkdownEmphasisTraits(style: style)
        guard view.selectedRange().length == 0, !trait.isEmpty else { return false }
        guard let baseContext = emphasisContext(in: view) else { return true }
        let context = [.highlight, .strikethrough].contains(style) ? typingContext(baseContext) : baseContext
        if context.projection.tokens.contains(where: {
            [.inlineCode, .inlineLatex, .codeBlock, .blockLatex].contains($0.kind)
                && NSLocationInRange(view.selectedRange().location - context.range.location, $0.range)
        }) { return true }
        if case .word(let plan) = MarkdownNativeWordFormatting.resolve(style: style,
            sourceOffset: view.selectedRange().location - context.range.location,
            projection: context.projection, navigator: emphasisEditor.wordNavigator,
            writingDirection: view.baseWritingDirection) {
            guard let plan else { return true }
            let source = (context.projection.source as NSString).replacingCharacters(in: plan.replacementRange, with: plan.replacement)
            let traits = MarkdownEmphasisProjection(source: source, scope: context.projection.scope)
                .traits(atSourceOffset: plan.selectionAfter.location)
            emphasisEditor.typingRun = nil
            let undo = view.undoManager
            let ownsGroup = undo?.groupingLevel == 0
            if ownsGroup { undo?.beginUndoGrouping() }
            defer { if ownsGroup { undo?.endUndoGrouping() } }
            _ = performEmphasisEdit(plan, context: context, traits: traits, in: view,
                                    coalescing: false, actionName: style.actionName)
            return true
        }
        let inherited = context.projection.traits(atSourceOffset: view.selectedRange().location - context.range.location)
        emphasisEditor.typingRun = nil
        view.breakUndoCoalescing()
        emphasisEditor.typing.toggle(trait, inheriting: inherited)
        emphasisEditor.lastSelection = view.selectedRange()
        selectionBar?.setNeedsUpdate()
        updateSelectionStates(view)
        if let state = currentFormatState() { publishFormatState(state) }
        return true
    }

    /// The native insertion callback can settle before its edit receipt clears.
    /// Normalize once after that transaction, without adopting away pending intent.
    func normalizeCommittedEmphasisCaret(in view: NSTextView) {
        guard !isApplyingSpanEdit, !isProgrammaticEdit, !isUpdatingSourceOrStyle,
              !isComposing(in: view), !isWritingToolsActive, view.selectedRange().length == 0,
              view.undoManager?.isUndoing != true, view.undoManager?.isRedoing != true else { return }
        let normalized = normalizedEmphasisSelection(view.selectedRange(), in: view)
        setCommittedCaret(normalized, in: view)
    }

    /// A source transaction can move a concealed caret without a user selection
    /// change. Preserve explicit typing intent for both emphasis and list settlement.
    func setCommittedCaret(_ normalized: NSRange, in view: NSTextView) {
        guard normalized != view.selectedRange() else { return }
        let wasNavigating = emphasisEditor.navigating
        emphasisEditor.navigating = true
        view.setSelectedRange(normalized)
        emphasisEditor.navigating = wasNavigating
        emphasisEditor.lastSelection = view.selectedRange()
        emphasisEditor.typingRun?.caret = view.selectedRange().location
        textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view))
    }

    func emphasisSelectionDidChange(in view: NSTextView) {
        guard !emphasisEditor.applying, !emphasisEditor.navigating, listEditor.navigation == nil, !isApplyingSpanEdit,
              pendingEditedRange == nil, !isProgrammaticEdit, !isComposing(in: view) else { return }
        if emphasisEditor.lastSelection != view.selectedRange() {
            emphasisEditor.keyboardSelectionContext = nil
            emphasisEditor.typing.adopt()
            emphasisEditor.typingRun = nil
            emphasisEditor.lastSelection = view.selectedRange()
        }
    }

    /// True means this native edit was consumed by one canonical source transaction.
    func applyEmphasisInput(_ replacement: String, range: NSRange, in view: NSTextView) -> Bool {
        guard !emphasisEditor.applying, !isApplyingSpanEdit, !isLiteralInsertion, !pendingInlineFormattingEdit,
              !isProgrammaticEdit, !isComposing(in: view), !isWritingToolsActive,
              view.undoManager?.isUndoing != true, view.undoManager?.isRedoing != true,
              let baseContext = emphasisContext(in: view, selection: range) else { return false }
        let decorations: MarkdownEmphasisTraits = [.highlight, .strikethrough]
        let hasDecorationIntent = !emphasisEditor.typing.enabled.intersection(decorations).isEmpty
            || !emphasisEditor.typing.disabled.intersection(decorations).isEmpty
        let context = hasDecorationIntent ? typingContext(baseContext) : baseContext
        let projection = context.projection
        if projection.tokens.contains(where: {
            [.inlineCode, .inlineLatex, .codeBlock, .blockLatex].contains($0.kind)
                && NSLocationInRange(range.location - context.range.location, $0.range)
        }) { return false }
        let local = NSRange(location: range.location - context.range.location, length: range.length)
        let inherited = range.length == 0 ? projection.traits(atSourceOffset: local.location)
            : projection.traits(atVisibleOffset: projection.visibleOffset(forSourceOffset: local.location), affinity: .downstream)
        let traits = emphasisEditor.typing.effectiveTraits(inheriting: inherited)
        // Leave unrelated typing and block input policies on their existing native path.
        guard !projection.hiddenDelimiterRanges.isEmpty || !traits.isEmpty
                || !emphasisEditor.typing.disabled.isEmpty else { return false }
        let plan: MarkdownEmphasisEditPlan?
        if range.length == 0 {
            plan = MarkdownEmphasisEditPlanner.insertion(text: replacement, atSourceOffset: local.location,
                                                        traits: traits, projection: projection)
        } else {
            let start = projection.visibleOffset(forSourceOffset: local.location)
            let end = projection.visibleOffset(forSourceOffset: NSMaxRange(local))
            guard end > start else { return false }
            plan = MarkdownEmphasisEditPlanner.replacement(text: replacement,
                visibleRange: NSRange(location: start, length: end - start), traits: traits, projection: projection)
        }
        guard let plan else { return false }
        // Ordinary insertion inside an existing run keeps AppKit's native typing
        // coalescing and the established scoped fast path. A pending custom run
        // continues through our transaction so its first character shares one Undo.
        if emphasisEditor.typingRun == nil, emphasisEditor.typing.enabled.isEmpty,
           emphasisEditor.typing.disabled.isEmpty, local == plan.replacementRange,
           plan.replacement == replacement,
           plan.selectionAfter == NSRange(location: local.location + replacement.utf16.count, length: 0) {
            return false
        }
        let followsParsedStyle = emphasisEditor.typing.enabled.isEmpty
            && emphasisEditor.typing.disabled.isEmpty
        let applied = performEmphasisEdit(plan, context: context, traits: traits, in: view)
        // Completing a delimiter run can promote a provisional italic span to
        // bold. Continue inheriting the parse unless the user chose an override.
        if applied, followsParsedStyle, !replacement.isEmpty,
           replacement.allSatisfy({ $0 == "*" || $0 == "_" }) {
            emphasisEditor.typing.adopt()
        }
        return applied
    }

    @discardableResult
    func performEmphasisEdit(_ plan: MarkdownEmphasisEditPlan, context: MarkdownEmphasisEditorState.Context,
                             traits: MarkdownEmphasisTraits, in view: NSTextView, coalescing: Bool = true,
                             actionName: String = "Typing") -> Bool {
        let offset = context.range.location
        let range = NSRange(location: offset + plan.replacementRange.location, length: plan.replacementRange.length)
        let selection = NSRange(location: offset + plan.selectionAfter.location, length: plan.selectionAfter.length)
        let beforeSelection = view.selectedRange()
        let now = Date.timeIntervalSinceReferenceDate
        var run = coalescing ? emphasisEditor.typingRun : nil
        if let current = run, current.caret != beforeSelection.location || beforeSelection.length > 0
            || now - current.timestamp > 0.5 || range.location < current.location
            || NSMaxRange(range) > current.location + current.length { run = nil }
        if run == nil, coalescing, view.undoManager != nil {
            run = MarkdownEmphasisEditorState.TypingRun(range: context.range,
                source: context.projection.source, selection: beforeSelection, typing: emphasisEditor.typing)
        }
        let isNewRun = run != nil && run !== emphasisEditor.typingRun
        let delta = plan.replacement.utf16.count - range.length
        let map: (Int) -> Int = { location in
            if location <= range.location { return location }
            if location >= NSMaxRange(range) { return location + delta }
            return range.location + min(location - range.location, plan.replacement.utf16.count)
        }
        var edit = SpanEdit(range: range, replacement: plan.replacement, selectionAfter: selection,
            actionName: actionName, mapLocation: map, inverseSelection: beforeSelection,
            emphasisTyping: emphasisEditor.typing)
        edit.registersUndo = run == nil
        emphasisEditor.applying = true
        defer { emphasisEditor.applying = false }
        guard performSpanEdit(edit, in: view) else { return false }
        if let run {
            run.length += delta
            run.caret = selection.location
            run.timestamp = now
            emphasisEditor.typingRun = run
            if isNewRun, let undo = view.undoManager {
                let ownsGroup = undo.groupingLevel == 0
                if ownsGroup { undo.beginUndoGrouping() }
                defer { if ownsGroup { undo.endUndoGrouping() } }
                undo.registerUndo(withTarget: self) { coordinator in
                    guard let view = coordinator.textView else { return }
                    coordinator.emphasisEditor.typingRun = nil
                    let range = NSRange(location: run.location, length: run.length)
                    guard NSMaxRange(range) <= (view.textStorage?.length ?? 0) else { return }
                    let inverse = SpanEdit(range: range, replacement: run.original, selectionAfter: run.selection,
                        actionName: "Typing", mapLocation: Self.paragraphPreservingMap(from: (view.string as NSString).substring(with: range), to: run.original, spanStart: run.location),
                        inverseSelection: view.selectedRange(), emphasisTyping: run.typing)
                    _ = coordinator.performSpanEdit(inverse, in: view)
                }
                undo.setActionName("Typing")
            }
        }
        emphasisEditor.typing.retainTypingTraits(traits)
        emphasisEditor.lastSelection = view.selectedRange()
        emphasisEditor.cache = nil
        return true
    }

    func copyEmphasisSelection(in view: NSTextView, to pasteboard: NSPasteboard) -> Bool {
        let selection = view.selectedRange()
        guard selection.length > 0, let context = emphasisContext(in: view),
              !context.projection.hiddenDelimiterRanges.isEmpty else { return false }
        let projection = context.projection
        let start = projection.visibleOffset(forSourceOffset: selection.location - context.range.location)
        let end = projection.visibleOffset(forSourceOffset: NSMaxRange(selection) - context.range.location)
        guard end > start else { return false }
        let markdown = projection.balancedMarkdown(forVisibleRange: NSRange(location: start, length: end - start))
        pasteboard.clearContents()
        return pasteboard.setString(markdown, forType: .string)
    }
}
