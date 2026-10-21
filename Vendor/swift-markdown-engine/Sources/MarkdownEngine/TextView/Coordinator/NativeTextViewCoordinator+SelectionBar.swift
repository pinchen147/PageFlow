import AppKit

extension NativeTextViewCoordinator {
    /// Shows or removes the selection bar to match the configuration.
    func reconcileSelectionBar(in scrollView: NSScrollView) {
        blockMover.install(in: scrollView)
        if imageControls == nil, let main = textView as? NativeTextView {
            imageControls = ImageControlsController(coordinator: self, textView: main, scrollView: scrollView)
        }
        let wanted = configuration.showsSelectionBar
        if wanted, selectionBar == nil, let main = textView {
            selectionBar = MarkdownSelectionBarController(coordinator: self, scrollView: scrollView)
            let colors: [NSAttributedString.Key: Any] = [
                .backgroundColor: ChromePalette.selectionBackground, .foregroundColor: ChromePalette.selectionText,
            ]
            main.selectedTextAttributes = colors
            tableEditingSession.editor.selectedTextAttributes = colors
            tableActions = TableActionsController(coordinator: self, scrollView: scrollView)
            tableChrome = TableChromeController(coordinator: self, scrollView: scrollView)
            tableHint = TableHintView()
            tableProxy = TableProxyScroller(coordinator: self, scrollView: scrollView)
        } else if !wanted, let bar = selectionBar {
            bar.uninstall()
            selectionBar = nil
            tableActions?.uninstall()
            tableActions = nil
            tableChrome?.uninstall()
            tableChrome = nil
            tableHint?.removeFromSuperview()
            tableHint = nil
            tableProxy?.uninstall()
            tableProxy = nil
            textView?.selectedTextAttributes = NSTextView().selectedTextAttributes
        }
        reconcileComments(in: scrollView)
    }

    /// Comments show with the selection bar, for a host that keeps them
    /// (an editor controller); a new controller brings its own threads.
    func reconcileComments(in scrollView: NSScrollView) {
        let store = MainActor.assumeIsolated { editorController?.commentStore }
        MainActor.assumeIsolated {
            if selectionBar != nil, let store {
                if let comments { comments.bind(store) } else {
                    comments = MarkdownCommentsController(coordinator: self, scrollView: scrollView, store: store)
                }
            } else if let comments {
                comments.uninstall()
                self.comments = nil
            }
        }
    }

    /// The formatting at the selection: the focused cell's text, else the
    /// document's, read from the cached parse (never a new parse).
    func currentFormatState() -> MarkdownFormatState? {
        guard let main = textView else { return nil }
        if let image = selectedImageTarget() {
            var state = MarkdownFormatState()
            state.context = .image(alignment: image.tokens.alignment, hasCrop: image.tokens.crop != nil, width: image.tokens.width)
            state.textStyle = nil
            state.isEditable = main.isEditable
            return state
        }
        let session = tableEditingSession
        if session.isRangeMode {
            var state = session.rangeFormatState()
            state.inTableCell = true
            return state
        }
        if session.isActive {
            let text = session.editor.string
            let tokens = MarkdownTokenizer.parseTokensViaAST(in: text, memoizing: false)
            var state = MarkdownFormatStateCalculator.state(
                text: text as NSString, tokens: tokens, codeTokens: tokens.filter { $0.kind == .inlineCode },
                selection: session.editor.selectedRange(), isEditable: main.isEditable
            )
            state.context = session.editor.selectedRange().length > 0 ? .cellText : .none
            state.inTableCell = true
            state.textStyle = nil
            state.listPressed = nil
            state.listChecked = nil
            state.showsIndentRows = false
            return state
        }
        let source = main.string
        let text = source as NSString
        let selection = main.selectedRange()
        // A short note parses on demand. A long one uses its cached parse, else
        // tokenizes only the blocks around the selection (a 5 MB tokenize is far
        // over the 100 ms stall bar), so a mark applied a moment ago reads pressed.
        guard let found = tokens(near: selection, in: source) else { return nil }
        var state = MarkdownFormatStateCalculator.state(text: text, tokens: found.tokens, codeTokens: found.codeTokens,
                                                        selection: selection, isEditable: main.isEditable)
        // A fence outside a local region is unknown; keep the last known code-block context.
        if found.isLocal, publishedFormatState.context == .codeBlock, state.context != .none { state.context = .codeBlock }
        return state
    }

    /// Tokens for the selection's neighbourhood: the cached parse, a fresh
    /// parse of a short note, else a local tokenize of the surrounding blocks.
    func tokens(near selection: NSRange, in source: String) -> (tokens: [MarkdownToken], codeTokens: [MarkdownToken], isLocal: Bool)? {
        let text = source as NSString
        if let parsed = parsedDocumentIfCached(for: source)
            ?? (text.length <= NativeTextView.estimatedLayoutChainThreshold ? parsedDocument(for: source) : nil) {
            return (parsed.tokens, parsed.codeTokens, false)
        }
        guard selection.length <= 65_536, let region = Self.blockRegion(around: selection, in: text) else { return nil }
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text.substring(with: region), memoizing: false).map { token in
            MarkdownToken(kind: token.kind, range: Self.shift(token.range, by: region.location),
                          contentRange: Self.shift(token.contentRange, by: region.location),
                          markerRanges: token.markerRanges.map { Self.shift($0, by: region.location) })
        }
        return (tokens, tokens.filter { $0.kind == .codeBlock || $0.kind == .inlineCode }, true)
    }

    /// The `[text](url)` link that holds `selection`, as the link dialog edits it.
    func linkTarget(around selection: NSRange) -> MarkdownLinkPopover.Target? {
        guard let main = textView else { return nil }
        let source = main.string
        let text = source as NSString
        guard let found = tokens(near: selection, in: source) else { return nil }
        let window = NSRange(location: selection.location, length: selection.length)
        guard let link = MarkdownFormatStateCalculator.tokensIntersecting(window, in: found.tokens).first(where: {
            $0.kind == .link && $0.range.location <= selection.location && NSMaxRange(selection) <= NSMaxRange($0.range)
        }), link.markerRanges.count >= 4 else { return nil }
        let urlRange = NSRange(location: NSMaxRange(link.markerRanges[2]),
                               length: link.markerRanges[3].location - NSMaxRange(link.markerRanges[2]))
        return MarkdownLinkPopover.Target(range: link.range, text: text.substring(with: link.contentRange),
                                          url: InlineParser.decodedLinkDestination(in: text, range: urlRange), isExistingLink: true)
    }

    /// Writes the link dialog's result: `[text](url)` over the target, or the text alone to remove it.
    func writeLink(_ markdown: String, over range: NSRange, actionName: String) {
        guard let main = textView else { return }
        let undo = main.undoManager
        let ownsGroup = undo?.groupingLevel == 0
        if ownsGroup { undo?.beginUndoGrouping() }
        _ = replaceSourceRanges([range], with: markdown, expectedSource: main.string, actionName: actionName)
        if ownsGroup { undo?.endUndoGrouping() }
        main.setSelectedRange(NSRange(location: range.location + (markdown as NSString).length, length: 0))
        main.window?.makeFirstResponder(main)
        commitTextSync(for: main)
    }

    /// The blank-line-delimited blocks around `selection`, at most 32k characters each way.
    private static func blockRegion(around selection: NSRange, in text: NSString) -> NSRange? {
        let limit = 32_768
        var start = selection.location
        let floor = max(0, start - limit)
        while start > floor {
            if start >= 2, text.character(at: start - 1) == 0x0A, text.character(at: start - 2) == 0x0A { break }
            start -= 1
        }
        var end = NSMaxRange(selection)
        let ceiling = min(text.length, end + limit)
        while end < ceiling {
            if end + 1 < text.length, text.character(at: end) == 0x0A, text.character(at: end + 1) == 0x0A { break }
            end += 1
        }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    private static func shift(_ range: NSRange, by offset: Int) -> NSRange {
        NSRange(location: range.location + offset, length: range.length)
    }

    /// Hands a changed format state to the host, for the focused editor only.
    func publishFormatState(_ state: MarkdownFormatState) {
        guard state != publishedFormatState else { return }
        publishedFormatState = state
        onFormatStateChange?(state)
        // The host registers on its controller, often before this editor exists.
        MainActor.assumeIsolated { editorController?.onFormatStateChange?(state) }
    }
}
