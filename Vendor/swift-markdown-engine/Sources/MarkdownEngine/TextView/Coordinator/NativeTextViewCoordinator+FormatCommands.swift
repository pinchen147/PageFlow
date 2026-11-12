import AppKit

extension NativeTextViewCoordinator {
    /// The one entry point for host and menu format commands.
    func apply(_ format: MarkdownFormat) {
        // In a table cell, an alignment aligns the cell's column (Justify does nothing).
        if case .align(let alignment) = format, tableEditingSession.isActive {
            tableEditingSession.alignColumns(alignment)
            return
        }
        // A selected image, or the image on the caret's line, aligns itself
        // through its token; it is never wrapped, and it cannot be justified.
        if case .align(let alignment) = format, let image = alignableImage() {
            if let value = ImageAltTokens.Alignment(rawValue: alignment.rawValue) {
                // Not object-selected: keep the caret or text selection where it is.
                _ = editImage(image, actionName: "Align Image", preservingSelection: objectSelection == nil) {
                    $0.alignment = value
                }
            }
            return
        }
        // Text formats do not apply to an image selected as a whole: wrapping its
        // token in markers would stop it rendering and show its Markdown.
        if objectSelection != nil { return }
        switch format {
        case .bold: applyInlineStyle(.bold)
        case .italic: applyInlineStyle(.italic)
        case .underline: applyInlineStyle(.underline)
        case .strikethrough: applyInlineStyle(.strikethrough)
        case .highlight: applyInlineStyle(.highlight)
        case .paragraph:
            applySourceFormat("Text") { MarkdownSourceFormatting.setBlock(level: 0, in: $0, selection: $1) }
        case .heading(let level):
            applySourceFormat("Heading \(level)") { MarkdownSourceFormatting.setBlock(level: level, in: $0, selection: $1) }
        case .checklist:
            applySourceFormat("Checklist") { MarkdownSourceFormatting.toggle(.task, in: $0, selection: $1) }
        case .indent:
            applySourceFormat("Indent") { MarkdownSourceFormatting.indentListItems(outdent: false, in: $0, selection: $1) }
        case .outdent:
            applySourceFormat("Outdent") { MarkdownSourceFormatting.indentListItems(outdent: true, in: $0, selection: $1) }
        case .bulletedList:
            applySourceFormat("Bulleted List") { MarkdownSourceFormatting.toggle(.bullet, in: $0, selection: $1) }
        case .numberedList:
            applySourceFormat("Numbered List") { MarkdownSourceFormatting.toggle(.number, in: $0, selection: $1) }
        case .quote:
            applySourceFormat("Quote") { MarkdownSourceFormatting.toggle(.quote, in: $0, selection: $1) }
        case .code:
            applySourceFormat("Code") { MarkdownSourceFormatting.toggleCode(in: $0, selection: $1) }
        case .codeBlock:
            applySourceFormat("Code Block") { MarkdownSourceFormatting.toggleCodeBlock(in: $0, selection: $1) }
        case .toggleChecked:
            applySourceFormat("Check") { MarkdownSourceFormatting.toggleTaskChecked(in: $0, selection: $1) }
        case .divider:
            applySourceFormat("Insert Divider") { MarkdownSourceFormatting.insertDivider(in: $0, selection: $1) }
        case .table:
            insertTable()
        case .link:
            // With the selection bar, Link is the reference editor's link dialog.
            if let bar = selectionBar {
                bar.showLinkEditor()
                return
            }
            applySourceFormat("Link") { MarkdownSourceFormatting.insertLink(in: $0, selection: $1) }
        case .align(let alignment):
            let names: [MarkdownTextAlignment: String] = [.left: "Align Left", .center: "Center",
                                                          .right: "Align Right", .justify: "Justify"]
            applySourceFormat(names[alignment] ?? "Align") {
                MarkdownSourceFormatting.setAlignment(alignment, in: $0, selection: $1)
            }
        case .clearFormatting:
            applySourceFormat("Clear Formatting") { MarkdownSourceFormatting.clearInlineFormatting(in: $0, selection: $1) }
        case .moveLines(let up):
            applySourceFormat(up ? "Move Line Up" : "Move Line Down") {
                MarkdownSourceFormatting.moveLines(up: up, in: $0, selection: $1)
            }
        }
    }

    /// Insert Table (doc 24 §5.1.5): an empty 3 × 3 table, the caret in its
    /// first header cell, equal view-only column widths, one Undo step, and
    /// the announcement "Inserted Table".
    private func insertTable() {
        guard let tv = textView else { return }
        let undo = tv.undoManager
        let ownsGroup = undo?.groupingLevel == 0 && undo?.isUndoing == false && undo?.isRedoing == false
        if ownsGroup { undo?.beginUndoGrouping() }
        defer { if ownsGroup { undo?.endUndoGrouping() } }
        let length = (tv.string as NSString).length
        applySourceFormat("Insert Table") { MarkdownSourceFormatting.insertTable(in: $0, selection: $1) }
        guard (tv.string as NSString).length > length else { return }
        let caret = tv.selectedRange().location
        if let token = parsedDocument(for: tv.string).tokens.first(where: { $0.kind == .table && NSLocationInRange(caret, $0.range) }) {
            let width = tv.enclosingScrollView?.contentView.bounds.width ?? tv.bounds.width
            tableEditingSession.applyNewTableWidths(toTableAt: token.range, editorWidth: width)
        }
        // the reference editor puts the caret in the first header cell.
        enterTableCell(for: tv.selectedRange(), in: tv)
        undo?.setActionName("Insert Table")
        MarkdownTableEditingSession.announce("Inserted Table")
    }

    private func alignableImage() -> ImageCommandTarget? {
        if let selected = selectedImageTarget() { return selected }
        // Read the caret's line itself: it may not be rendered or selectable yet.
        // A caret or selection within one image line (after a resize the token
        // stays selected as text) is that image.
        guard let tv = textView else { return nil }
        let text = tv.string as NSString
        let selection = tv.selectedRange()
        let line = text.paragraphRange(for: NSRange(location: selection.location, length: 0))
        let end = Self.contentEnd(of: line, in: text)
        guard NSMaxRange(selection) <= end else { return nil }
        var first = line.location
        while first < end, [0x20, 0x09].contains(text.character(at: first)) { first += 1 }
        guard first + 1 < end, text.character(at: first) == 0x21 else { return nil }
        return imageTarget(for: ObjectSelection(token: NSRange(location: first, length: end - first), anchor: first))
    }

    /// Applies a computed source edit as one undoable transaction.
    func applySourceFormat(
        _ actionName: String,
        inverseSelection: NSRange? = nil,
        _ makeEdit: (NSString, NSRange) -> MarkdownSourceEdit?
    ) {
        guard let tv = textView, tv.isEditable, !tv.hasMarkedText(), !isWritingToolsActive,
              !tableEditingSession.isActive, let storage = tv.textStorage,
              let edit = makeEdit(storage.mutableString, tv.selectedRange()) else { return }
        let previous = storage.mutableString.substring(with: edit.range)
        let undo = tv.undoManager
        let ownsGroup = undo?.groupingLevel == 0 && undo?.isUndoing == false && undo?.isRedoing == false
        if ownsGroup { undo?.beginUndoGrouping() }
        defer { if ownsGroup { undo?.endUndoGrouping() } }
        performSpanEdit(SpanEdit(
            range: edit.range, replacement: edit.replacement, selectionAfter: edit.selection,
            actionName: actionName,
            mapLocation: Self.paragraphPreservingMap(from: previous, to: edit.replacement, spanStart: edit.range.location),
            inverseSelection: inverseSelection,
            reflowsParagraphChain: true
        ), in: tv)
        commitTextSync(for: tv)   // a command publishes at once, like the inline styles
    }
}
