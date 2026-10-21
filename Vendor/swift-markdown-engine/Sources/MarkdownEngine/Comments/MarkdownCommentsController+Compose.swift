import AppKit

/// Writing a comment (doc 25 §1–§2): Comment in the selection bar or ⌥⌘M
/// opens the composer on the selection; Enter posts, Escape discards; Add
/// reaction posts an emoji thread at once.
extension MarkdownCommentsController {

    /// The range a comment would anchor to, if any.
    var commentableSelection: NSRange? { commentTarget?.range }

    /// Comment (bar, menu, ⌥⌘M over a selection): opens the composer.
    func beginComment() {
        guard let target = commentTarget else {
            return announce("Select some text or table cells to comment")
        }
        beginComment(on: target.range, table: false, cells: target.cells)
    }

    /// The table "…" menu's Comment: the whole table.
    func beginTableComment(_ range: NSRange) {
        coordinator?.tableEditingSession.retire()
        beginComment(on: range, table: true, cells: false)
    }

    private func beginComment(on selection: NSRange, table: Bool, cells: Bool) {
        guard let main = textView else { return }
        // A new selection takes over an empty draft; typed text is never dropped.
        if isEditorDirty { return refuseWhileWriting() }
        if store.draft != nil { closeComposer() }
        let made = MarkdownCommentAnchoring.anchor(for: selection, in: main.string as NSString)
        store.focusID = nil
        store.draft = MarkdownCommentStore.Draft(range: made.range, clamped: made.clamped, table: table, cells: cells)
        coordinator?.selectionBar?.update()
        // The selection is painted at rest gold while the composer is open.
        collapseSelection(after: selection)
        let composer = CommentComposerView(frame: NSRect(x: 0, y: 0, width: CommentCardView.width, height: 48))
        composer.showsClampNote = made.clamped
        composer.onPost = { [weak self] text in self?.postDraft(text) }
        composer.onDiscard = { [weak self] in self?.discardDraft(restoreFocus: true) }
        composer.onResize = { [weak self] in self?.composerResized() }
        composer.field.onChange = { [weak self, weak composer] text in
            self?.store.draft?.text = text
            composer?.send.isEnabled = !(composer?.field.isBlank ?? true)
            self?.composerResized()
        }
        self.composer = composer
        _ = measureWidth()
        if railSeated { seatComposer() } else { floatComposer() }
        refresh()
        focusComposer(composer, retries: 1)
    }

    /// the reference editor's re-anchor: a new selection while the draft is empty moves
    /// the draft (and its composer) to it; the text paints gold as before.
    func reanchorDraft(to target: CommentTarget) {
        guard let main = textView, var draft = store.draft else { return }
        let made = MarkdownCommentAnchoring.anchor(for: target.range, in: main.string as NSString)
        draft.range = made.range
        draft.clamped = made.clamped
        draft.cells = target.cells
        draft.table = false
        store.draft = draft
        composer?.showsClampNote = made.clamped
        collapseSelection(after: target.range)
        if composerFloats { placeFloatingComposer() }
        refresh()
    }

    /// The field takes focus after layout; if focus leaves within 250 ms it
    /// is pulled back once (the reference editor).
    private func focusComposer(_ composer: CommentComposerView, retries: Int) {
        DispatchQueue.main.async { [weak self, weak composer] in
            guard let self, let composer, composer.window != nil else { return }
            composer.field.focus()
            guard retries > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak composer] in
                guard let self, let composer, self.composer === composer, !composer.field.hasFocus,
                      composer.window?.firstResponder === self.textView else { return }
                composer.field.focus()
            }
        }
    }

    private func composerResized() {
        if composerFloats { placeFloatingComposer() } else { setNeedsRefresh() }
    }

    /// The composer sits in the rail as the draft card.
    func seatComposer() {
        guard let composer else { return }
        let hadFocus = composer.field.hasFocus
        composerFloats = false
        rail.composer = composer
        if hadFocus { composer.field.focus() }
    }

    /// The composer floats at the editor's right (no rail yet, or narrow):
    /// 248 wide, 12 from the edge, level with the selection, kept inside.
    func floatComposer() {
        guard let composer, let scrollView else { return }
        let hadFocus = composer.field.hasFocus
        composerFloats = true
        if rail.composer === composer { rail.composer = nil }
        if composer.superview !== scrollView { scrollView.addSubview(composer, positioned: .above, relativeTo: nil) }
        placeFloatingComposer()
        if hadFocus { composer.field.focus() }
    }

    func placeFloatingComposer() {
        guard let composer, composerFloats, let scrollView, let main = textView else { return }
        let width: CGFloat = 248
        let height = composer.fittingHeight(forWidth: width)
        let railHeight = scrollView.bounds.height - scrollView.contentInsets.top
        var y: CGFloat = 8
        if let draft = store.draft, let rect = imageRect(draft.range, in: main)
            ?? segmentRects(for: NSRange(location: draft.range.location, length: min(1, draft.range.length)), in: main).first {
            let inScroll = main.convert(rect, to: scrollView)
            y = (scrollView.isFlipped ? inScroll.minY : scrollView.bounds.height - inScroll.maxY) - scrollView.contentInsets.top
        }
        let top = min(max(8, y), railHeight - 240, max(8, railHeight - height - 8)) + scrollView.contentInsets.top
        let topDown = NSRect(x: scrollView.bounds.width - 12 - width, y: top, width: width, height: height)
        composer.frame = scrollView.isFlipped ? topDown
            : NSRect(x: topDown.minX, y: scrollView.bounds.height - topDown.maxY, width: width, height: height)
    }

    /// Enter or Send: the thread posts at once (no server), the composer
    /// closes, the highlight sweeps in, the caret goes after the text.
    func postDraft(_ body: String) {
        guard let main = textView, let draft = store.draft else { return }
        let text = main.string as NSString
        let made = MarkdownCommentAnchoring.anchor(for: draft.range, in: text)
        let thread = MarkdownCommentThread(anchor: made.anchor, table: draft.table, cells: draft.cells, root: MarkdownComment(body: body))
        closeComposer()
        arriving = thread.id
        store.add(thread, range: made.range)
        announce("Comment posted")
        returnToText(caret: NSMaxRange(made.range))
    }

    /// Escape (or a click away from an empty draft): drops it, no question.
    func discardDraft(restoreFocus: Bool) {
        guard let draft = store.draft else { return }
        closeComposer()
        refresh()
        if restoreFocus { returnToText(caret: NSMaxRange(draft.range)) }
    }

    func closeComposer() {
        store.draft = nil
        composer?.removeFromSuperview()
        if rail.composer != nil { rail.composer = nil }
        composer = nil
        composerFloats = false
    }

    func returnToText(caret: Int) {
        guard let main = textView else { return }
        // Inside a table the cell keeps the keyboard; the document's caret stays where it was.
        if let session = coordinator?.tableEditingSession, session.isActive {
            main.window?.makeFirstResponder(session.editor)
            return
        }
        main.window?.makeFirstResponder(main)
        main.setSelectedRange(NSRange(location: min(caret, (main.string as NSString).length), length: 0))
    }

    /// The selection goes once the composer takes over (its text is painted gold instead).
    private func collapseSelection(after selection: NSRange) {
        guard let main = textView else { return }
        if let session = coordinator?.tableEditingSession, session.isActive {
            session.setCellSelection(nil)
            let editor = session.editor
            editor.setSelectedRange(NSRange(location: NSMaxRange(editor.selectedRange()), length: 0))
            return
        }
        main.setSelectedRange(NSRange(location: NSMaxRange(selection), length: 0))
    }

    // MARK: - ⌥⌘M

    /// Comment on the selection, or open the comment at the caret, cycling
    /// through several there (shortest anchor first).
    func commandComment() {
        guard let main = textView else { return }
        if commentableSelection != nil { return beginComment() }
        let caret = main.selectedRange().location
        let under = store.threads(at: caret)
        guard !under.isEmpty else { return announce("Select some text or table cells to comment") }
        guard !isEditorDirty else { return refuseWhileWriting() }
        var next = under[0].id
        if let cycle, cycle.location == caret, let index = under.firstIndex(where: { $0.id == cycle.id }) {
            next = under[(index + 1) % under.count].id
        }
        cycle = (caret, next)
        open(next, focusCard: true)
    }
}
