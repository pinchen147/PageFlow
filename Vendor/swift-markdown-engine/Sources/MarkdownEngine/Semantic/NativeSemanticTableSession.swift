import AppKit

/// Topology owns cell identity. Once mounted, a cell's retained native storage owns its text.
@MainActor
final class NativeSemanticTableSession: NSObject, NSTextViewDelegate {
    var topology: SemanticMarkdownTable
    private weak var history: UndoManager?
    var configuration: MarkdownEditorConfiguration {
        didSet {
            geometryCache = nil
            for editor in editors.values { refreshEditorAppearance(editor) }
        }
    }
    var geometryCache: MarkdownTableLayout?
    let geometryCellCache = MarkdownTableLayout.CellCache()
    private var editors: [UUID: NativeSemanticCellTextView] = [:]
    private(set) var activeCellID: UUID?
    var isEditable = true {
        didSet {
            for editor in editors.values {
                editor.isEditable = isEditable
                for source in editor.mathEditors.values { source.refreshAppearance() }
            }
        }
    }
    var widthKey: String?
    var onColumnWidthsChange: (([CGFloat?]) -> Void)?
    var columnWidths: [CGFloat?] = [] { didSet { if oldValue != columnWidths { geometryCache = nil } } }
    var horizontalOffset: CGFloat = 0
    var wideOverlay: WideTableOverlay?
    weak var presentationHost: NSView?
    var chrome: TableChromeView?
    var grid: MarkdownTableGridView?
    var cellScroll: NSScrollView?
    var cellSelection: TableCellSelection?
    var presentationFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    var hasActiveComposition: Bool { editors.values.contains { $0.hasMarkedText() || $0.isCommittingComposition || $0.hasWritingToolsSnapshot || $0.hasProtectedMathSourceInput } }
    var onInputSettled: (() -> Void)?
    var onFocus: ((NSView) -> Void)?
    var onSelectionChange: (() -> Void)?
    var onChange: (() -> Void)?
    var onKeyEquivalent: ((NSEvent, NSTextView) -> Bool)?

    init(table: SemanticMarkdownTable, undoManager: UndoManager?, configuration: MarkdownEditorConfiguration) {
        topology = table
        history = undoManager
        self.configuration = configuration
        super.init()
        if let undoManager {
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                NotificationCenter.default.addObserver(self, selector: #selector(historyDidReplay(_:)), name: name, object: undoManager)
            }
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func historyDidReplay(_ notification: Notification) {
        for editor in editors.values {
            editor.refreshMathObjects()
            refreshEditorAppearance(editor)
        }
    }

    func undoManager(for view: NSTextView) -> UndoManager? { history }

    func editor(for cellID: UUID) -> NSTextView? {
        guard let cell = topology.identifiedRows.flatMap(\.cells).first(where: { $0.id == cellID }) else { return nil }
        if let editor = editors[cellID] { return editor }
        let editor = NativeSemanticCellTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
        editor.session = self
        editor.cellID = cellID
        editor.delegate = self
        editor.isRichText = true
        editor.isEditable = isEditable
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = MarkdownTableLayout.cellFont(for: presentationFont)
        editor.textColor = configuration.theme.bodyText
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textStorage?.setAttributedString(attributedCell(cell.text, font: MarkdownTableLayout.cellFont(for: presentationFont),
                                                               alignment: alignment(for: cellID)))
        editors[cellID] = editor
        refreshEditorAppearance(editor)
        return editor
    }

    func snapshot() -> SemanticMarkdownTable {
        var value = topology
        for row in value.identifiedRows.indices {
            for column in value.identifiedRows[row].cells.indices {
                let id = value.identifiedRows[row].cells[column].id
                if let editor = editors[id] {
                    value.identifiedRows[row].cells[column].text = NativeSemanticAttributes.inlineText(editor.committedSnapshot())
                }
            }
        }
        return value
    }

    /// Called by an already admitted document transaction, including its inverse.
    func adopt(_ table: SemanticMarkdownTable) {
        geometryCache = nil
        topology = table
        for cell in table.identifiedRows.flatMap(\.cells) {
            guard let editor = editors[cell.id], let storage = editor.textStorage, !editor.hasMarkedText(), !editor.hasWritingToolsSnapshot else { continue }
            let selection = editor.selectedRange()
            let updated = NSMutableAttributedString(attributedString: attributedCell(cell.text,
                font: MarkdownTableLayout.cellFont(for: presentationFont), alignment: alignment(for: cell.id)))
            editor.preserveMathIdentities(in: updated, matching: cell.text)
            if !storage.isEqual(to: updated) { storage.setAttributedString(updated) }
            let location = min(selection.location, storage.length)
            editor.setSelectedRange(NSRange(location: location, length: min(selection.length, storage.length - location)))
            refreshEditorAppearance(editor)
        }
    }

    @available(macOS 15.0, *)
    func textViewWritingToolsWillBegin(_ textView: NSTextView) {
        (textView as? NativeSemanticCellTextView)?.beginWritingTools()
    }

    @available(macOS 15.0, *)
    func textViewWritingToolsDidEnd(_ textView: NSTextView) {
        (textView as? NativeSemanticCellTextView)?.finishWritingTools()
        textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        onInputSettled?()
    }

    func textViewDidChangeSelection(_ notification: Notification) { onSelectionChange?() }

    func textDidChange(_ notification: Notification) {
        if let editor = notification.object as? NativeSemanticCellTextView { refreshEditorAppearance(editor) }
        geometryCache = nil
        refreshPresentation()
        onChange?()
    }

    func refreshEditorAppearance(_ editor: NativeSemanticCellTextView) {
        let theme = configuration.theme
        for source in editor.mathEditors.values { source.refreshAppearance() }
        editor.insertionPointColor = theme.bodyText
        var linkAttributes = editor.linkTextAttributes ?? [:]
        linkAttributes[.foregroundColor] = theme.link
        editor.linkTextAttributes = linkAttributes
        guard !editor.hasMarkedText(), !editor.hasWritingToolsSnapshot, !editor.isCommittingComposition,
              let storage = editor.textStorage else { return }
        let registrationEnabled = history?.isUndoRegistrationEnabled == true
        if registrationEnabled { history?.disableUndoRegistration() }
        defer { if registrationEnabled { history?.enableUndoRegistration() } }
        if storage.length == 0 { editor.textColor = theme.bodyText }
        var changes: [(NSRange, NSColor)] = []
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
            let color = attributes[NativeSemanticAttributes.link] == nil ? theme.bodyText : theme.link
            if (attributes[.foregroundColor] as? NSColor) != color { changes.append((range, color)) }
        }
        if !changes.isEmpty {
            storage.beginEditing()
            for (range, color) in changes { storage.addAttribute(.foregroundColor, value: color, range: range) }
            storage.endEditing()
        }
        var typing = editor.typingAttributes
        typing[.foregroundColor] = typing[NativeSemanticAttributes.link] == nil ? theme.bodyText : theme.link
        if typing[.font] == nil { typing[.font] = MarkdownTableLayout.cellFont(for: presentationFont) }
        editor.typingAttributes = typing
    }

    private func alignment(for cellID: UUID) -> MarkdownTableAlignment {
        for row in topology.identifiedRows {
            if let column = row.cells.firstIndex(where: { $0.id == cellID }), topology.alignments.indices.contains(column) { return topology.alignments[column] }
        }
        return .left
    }

    private func attributedCell(_ value: SemanticInlineText, font: NSFont, alignment: MarkdownTableAlignment = .left) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: NativeSemanticAttributes.attributedText(value, font: font))
        result.addAttribute(.foregroundColor, value: configuration.theme.bodyText, range: NSRange(location: 0, length: result.length))
        result.enumerateAttribute(NativeSemanticAttributes.link, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            if value != nil { result.addAttribute(.foregroundColor, value: configuration.theme.link, range: range) }
        }
        NativeSemanticAttributes.renderObjects(in: result, configuration: configuration, font: font, maxWidth: 400)
        let paragraph = NSMutableParagraphStyle()
        let lineHeight = font.pointSize * MarkdownTableLayout.lineHeightMultiple
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.alignment = alignment == .center ? .center : alignment == .right ? .right : .left
        result.addAttributes([.paragraphStyle: paragraph,
            .baselineOffset: MarkdownTableLayout.baselineOffset(for: font, lineHeight: lineHeight)], range: NSRange(location: 0, length: result.length))
        return NSAttributedString(attributedString: result)
    }

    func focus(_ cellID: UUID) { activeCellID = cellID; if let view = editor(for: cellID) { onFocus?(view) } }

    @discardableResult
    func moveRow(_ rowID: UUID, to destination: Int) -> Bool {
        guard let index = topology.identifiedRows.firstIndex(where: { $0.id == rowID }), index > 0,
              destination > 0, destination < topology.identifiedRows.count, destination != index else { return false }
        var next = snapshot()
        let moved = next.identifiedRows.remove(at: index)
        next.identifiedRows.insert(moved, at: destination)
        return replaceTopology(next, name: "Move Row")
    }

    @discardableResult
    func deleteRow(_ rowID: UUID) -> Bool {
        guard let index = topology.identifiedRows.firstIndex(where: { $0.id == rowID }), index > 0 else { return false }
        var next = snapshot()
        next.identifiedRows.remove(at: index)
        return replaceTopology(next, name: "Delete Row")
    }

    /// Retained cell views deliberately outlive removal while native history references them.
    func replaceTopology(_ next: SemanticMarkdownTable, name: String) -> Bool {
        guard isEditable, !hasActiveComposition else { return false }
        for editor in editors.values { editor.breakUndoCoalescing() }
        history?.beginUndoGrouping()
        let previous = snapshot()
        let oldCoordinate = editedCoordinate ?? cellSelection?.topLeft
        var nextFocus = activeCellID
        if let focused = nextFocus, !next.identifiedRows.flatMap(\.cells).contains(where: { $0.id == focused }) {
            if let oldCoordinate, !next.identifiedRows.isEmpty, !next.alignments.isEmpty {
                nextFocus = next.identifiedRows[min(oldCoordinate.row, next.identifiedRows.count - 1)]
                    .cells[min(oldCoordinate.column, next.alignments.count - 1)].id
            } else { nextFocus = nil }
        }
        let selection = cellSelection.map { value -> TableCellSelection in
            func clamp(_ cell: CellCoord) -> CellCoord {
                .init(row: min(cell.row, max(0, next.identifiedRows.count - 1)), column: min(cell.column, max(0, next.alignments.count - 1)))
            }
            return .init(anchor: clamp(value.anchor), head: clamp(value.head))
        }
        restore(topology: next, inverse: previous, focus: nextFocus, selection: selection)
        history?.setActionName(name)
        history?.endUndoGrouping()
        return true
    }

    private func restore(topology next: SemanticMarkdownTable, inverse: SemanticMarkdownTable, focus: UUID?,
                         selection: TableCellSelection?, nativeCells: [UUID: NSAttributedString]? = nil) {
        // Semantic table values intentionally omit native object identities.
        // History must retain the attributed inverse too: source-editor Undo
        // still addresses those formula IDs after a cell is cleared/restored.
        let inverseNativeCells = editors.mapValues { $0.committedSnapshot() }
        let previousFocus = activeCellID
        let previousSelection = cellSelection
        let responder = grid?.window?.firstResponder
        let ownedFocus = responder === grid || activeCellID.flatMap { editor(for: $0) }.map { responder === $0 } == true
        adopt(next)
        if let nativeCells {
            for cell in next.identifiedRows.flatMap(\.cells) {
                guard let content = nativeCells[cell.id], let editor = editors[cell.id],
                      let storage = editor.textStorage else { continue }
                guard content.string.utf16.elementsEqual(storage.string.utf16) else { continue }
                // The fresh adoption owns current theme/font/geometry. Restore
                // only opaque identities at matching native object positions.
                content.enumerateAttribute(NativeSemanticAttributes.objectID,
                    in: NSRange(location: 0, length: content.length)) { value, range, _ in
                    guard let id = value as? UUID,
                          let expected = content.attribute(NativeSemanticAttributes.object, at: range.location, effectiveRange: nil) as? SemanticInlineObject,
                          let actual = storage.attribute(NativeSemanticAttributes.object, at: range.location, effectiveRange: nil) as? SemanticInlineObject,
                          expected == actual else { return }
                    storage.addAttribute(NativeSemanticAttributes.objectID, value: id, range: range)
                }
                editor.refreshMathObjects()
                refreshEditorAppearance(editor)
            }
        }
        activeCellID = focus
        cellSelection = selection
        history?.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated {
                session.restore(topology: inverse, inverse: next, focus: previousFocus,
                                selection: previousSelection, nativeCells: inverseNativeCells)
            }
        }
        refreshPresentation()
        if ownedFocus, let grid {
            grid.window?.makeFirstResponder(cellSelection != nil ? grid : activeCellID.flatMap { editor(for: $0) })
        }
        onChange?()
    }
}

@MainActor
final class NativeSemanticCellTextView: NSTextView {
    weak var session: NativeSemanticTableSession?
    var cellID = UUID()
    var mathEditors: [UUID: NativeSemanticCellMathEditor] = [:]
    var isCommittingComposition = false
    private var suppressTypedCompletion = false
    private var writingToolsSnapshot: NSAttributedString?
    var hasWritingToolsSnapshot: Bool { writingToolsSnapshot != nil }

    func beginWritingTools() {
        guard writingToolsSnapshot == nil else { return }
        writingToolsSnapshot = committedSnapshot()
    }

    func finishWritingTools() { writingToolsSnapshot = nil }
    private var displacedComposition: NSAttributedString?

    func committedSnapshot() -> NSAttributedString {
        if let writingToolsSnapshot { return writingToolsSnapshot }
        guard let storage = textStorage else { return NSAttributedString(string: "") }
        let result = NSMutableAttributedString(attributedString: storage)
        let marked = markedRange()
        if hasMarkedText(), let displacedComposition, marked.location != NSNotFound,
           marked.location <= result.length, marked.length <= result.length - marked.location {
            result.replaceCharacters(in: marked, with: displacedComposition)
        }
        return normalizedMathSnapshot(result)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            if revealMathSource(at: index) || (index > 0 && revealMathSource(at: index - 1)) { return }
        }
        super.mouseDown(with: event)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if !hasMarkedText(), let storage = textStorage {
            let replaced = replacementRange.location == NSNotFound ? self.selectedRange() : replacementRange
            if replaced.location >= 0, replaced.location <= storage.length,
               replaced.length >= 0, replaced.length <= storage.length - replaced.location {
                displacedComposition = NSAttributedString(attributedString: storage.attributedSubstring(from: replaced))
            }
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let wasComposing = hasMarkedText()
        isCommittingComposition = wasComposing
        super.insertText(insertString, replacementRange: replacementRange)
        isCommittingComposition = false
        if !wasComposing, !suppressTypedCompletion, let typed = insertString as? String, typed.count == 1,
           "*_~=$\u{0060}".contains(typed), let edit = typed == "$" ? typedMathReplacement() : NativeSemanticDocumentCoordinator.typedInlineReplacement(in: self) {
            let typing = typingAttributes
            super.insertText(edit.text, replacementRange: edit.range)
            typingAttributes = typing
        }
        if !hasMarkedText() {
            displacedComposition = nil
            session?.refreshEditorAppearance(self)
            if wasComposing { session?.onInputSettled?() }
        }
    }

    override func unmarkText() {
        super.unmarkText()
        displacedComposition = nil
        session?.textDidChange(Notification(name: NSText.didChangeNotification, object: self))
        if !isCommittingComposition { session?.onInputSettled?() }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { session?.focus(cellID) }
        return accepted
    }

    override func paste(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), !hasWritingToolsSnapshot, let text = NSPasteboard.general.string(forType: .string) else { return }
        insertLiteral(text)
    }

    func insertLiteral(_ text: String) {
        guard isEditable, !hasMarkedText(), !hasWritingToolsSnapshot else { return }
        suppressTypedCompletion = true
        defer { suppressTypedCompletion = false }
        insertText(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"), replacementRange: selectedRange())
    }

    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }

    override func insertTab(_ sender: Any?) {
        if session?.navigate(from: cellID, backwards: false) != true { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if session?.navigate(from: cellID, backwards: true) != true { super.insertBacktab(sender) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, session?.onKeyEquivalent?(event, self) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
