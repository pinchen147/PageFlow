import AppKit

extension NativeTextViewCoordinator {
    /// The one entry point for host and menu format commands.
    func apply(_ format: MarkdownFormat) {
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
            applySourceFormat("Insert Table") { MarkdownSourceFormatting.insertTable(in: $0, selection: $1) }
            // the reference editor puts the caret in the first header cell.
            if let tv = textView { enterTableCell(for: tv.selectedRange(), in: tv) }
        case .link:
            // With the selection bar, Link is the reference editor's link dialog.
            if let bar = selectionBar {
                bar.showLinkEditor()
                return
            }
            applySourceFormat("Link") { MarkdownSourceFormatting.insertLink(in: $0, selection: $1) }
        }
    }

    /// Applies a computed source edit as one undoable transaction.
    private func applySourceFormat(
        _ actionName: String,
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
            reflowsParagraphChain: true
        ), in: tv)
        commitTextSync(for: tv)   // a command publishes at once, like the inline styles
    }
}
