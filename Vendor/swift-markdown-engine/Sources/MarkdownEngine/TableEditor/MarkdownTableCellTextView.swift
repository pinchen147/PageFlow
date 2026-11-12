import AppKit

final class MarkdownTableCellTextView: NSTextView {
    weak var session: MarkdownTableEditingSession?
    private(set) var changingMarkedText = false
    var hasProtectedInput: Bool { changingMarkedText || hasMarkedText() }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // Composing over a cell range starts in its top-left cell, the range cleared.
        if session?.isRangeMode == true { session?.prepareRangeForComposition() }
        session?.beginCellEmphasisComposition(replacing: replacementRange.location == NSNotFound ? self.selectedRange() : replacementRange)
        changingMarkedText = true
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        changingMarkedText = false
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let session, session.isRangeMode, !hasMarkedText() {
            session.typeOverRange((string as? NSAttributedString)?.string ?? (string as? String) ?? "")
            return
        }
        let finishing = hasMarkedText()
        if !finishing, session?.insertCellEmphasisText((string as? NSAttributedString)?.string ?? (string as? String) ?? "", replacing: replacementRange) == true { return }
        if finishing { changingMarkedText = true }
        super.insertText(string, replacementRange: replacementRange)
        if finishing {
            changingMarkedText = false
            session?.finishCellEmphasisComposition()
            session?.commitInput()
            session?.finishDeferredInputWork()
        } else {
            session?.normalizeCommittedEmphasisCaret()
        }
    }

    override func unmarkText() {
        let finishing = hasMarkedText()
        if finishing { changingMarkedText = true }
        super.unmarkText()
        if finishing {
            changingMarkedText = false
            session?.finishCellEmphasisComposition()
            session?.commitInput()
            session?.finishDeferredInputWork()
        }
    }

    /// Drop provisional input without committing it (the caller suppresses the commit).
    func discardMarkedText() {
        inputContext?.discardMarkedText()
        unmarkText()
    }

    // MARK: - Ranges

    override func mouseDown(with event: NSEvent) {
        guard let session, session.isActive else { return super.mouseDown(with: event) }
        // ⌘-click on a link's text in the focused cell opens it.
        if event.clickCount == 1, event.modifierFlags.intersection([.command, .shift, .control, .option]) == .command,
           !session.isRangeMode, (string as NSString).length > 0 {
            let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            if let link = session.link(atEditorIndex: min(index, (string as NSString).length - 1)) {
                session.coordinator?.openTableLink(link)
                return
            }
        }
        if session.isRangeMode { session.setCellSelection(nil) }
        switch event.clickCount {
        case 1 where !event.modifierFlags.contains(.shift):
            // Our own drag loop: text inside this cell, a range across cells.
            setSelectedRange(NSRange(location: characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)), length: 0))
            session.trackSelection(from: event)
        case 3:
            session.setCellSelection(TableCellSelection(anchor: CellCoord(row: session.row, column: session.column),
                                                        head: CellCoord(row: session.row, column: session.column)))
        default:
            super.mouseDown(with: event)
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if session?.isRangeMode == true {
            if item.action == #selector(copy(_:)) { return true }
            if item.action == #selector(cut(_:)) { return isEditable && !hasProtectedInput }
        }
        return super.validateUserInterfaceItem(item)
    }

    @objc override func copy(_ sender: Any?) {
        if !copySelection(to: .general, cut: false) { super.copy(sender) }
    }

    @objc override func cut(_ sender: Any?) {
        if !copySelection(to: .general, cut: true) { super.cut(sender) }
    }

    /// Handles table-owned selections without invoking the native clipboard fallback.
    func copySelection(to board: NSPasteboard, cut: Bool) -> Bool {
        guard let session else { return false }
        if session.isRangeMode {
            session.copyRange(cut: cut, to: board)
            return true
        }
        return session.copyCellEmphasis(cut: cut, to: board)
    }

    @objc override func paste(_ sender: Any?) {
        if !pasteSelection(from: .general) { super.paste(sender) }
    }

    /// A range consumes Paste even when its edit is refused, matching native dispatch.
    func pasteSelection(from board: NSPasteboard) -> Bool {
        guard let session else { return false }
        if session.isRangeMode {
            session.pasteIntoRange(from: board)
            return true
        }
        return session.pasteGridAtCaret(from: board)
    }

    @objc override func selectAll(_ sender: Any?) {
        // ⌘A is the whole document in the reference editor, also from a cell.
        if let session, session.isActive { session.selectWholeDocument() } else { super.selectAll(sender) }
    }

    /// ⌘Return adds a line in the cell, like Return (the reference editor).
    override func keyDown(with event: NSEvent) {
        let command = session?.coordinator?.keyBindings.command(for: event)
        // F6: the selection bar, else the "…" button of this table.
        if command == .focusSelectionBar, session?.coordinator?.selectionBar?.focusBar() == true { return }
        if command == .focusSelectionBar, session?.coordinator?.tableActions?.focusButton() == true { return }
        // ⇧F10: Cell actions at the caret.
        if command == .tableCellActions, let session {
            session.showCellActions(at: nil, fromKeyboard: true)
            return
        }
        if event.keyCode == 36 || event.keyCode == 76,
           event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command, let session {
            session.insertLineBreak()
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let session else { return super.menu(for: event) }
        return session.contextMenu(for: event) { super.menu(for: event) }
    }

    /// NSTextView's own menu (spelling, Cut, Copy, Paste) for a glyph or the text selection.
    func standardMenu(for event: NSEvent) -> NSMenu? { super.menu(for: event) }
}
