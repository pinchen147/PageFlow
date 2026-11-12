import AppKit

extension NativeSemanticDocumentCoordinator {
    var currentFormatState: MarkdownFormatState {
        if textView.window?.firstResponder is NativeSemanticCellMathSourceView {
            var state = MarkdownFormatState()
            state.context = .codeBlock
            state.isEditable = false
            return state
        }
        if let block = activeSourceBlockSession { return block.controller.formatState }
        var state = MarkdownFormatState()
        state.context = .text
        state.isEditable = textView.isEditable
        let view: NSTextView
        if let cell = textView.window?.firstResponder as? NSTextView,
           let session = cell.delegate as? NativeSemanticTableSession, session.grid?.superview === textView {
            view = cell
            state.context = .cellText
            state.inTableCell = true
        } else { view = textView }
        let range = view.selectedRange()
        var attributes = [view.typingAttributes]
        if range.length > 0, let storage = view.textStorage, NSMaxRange(range) <= storage.length {
            attributes = []
            storage.enumerateAttributes(in: range) { value, _, _ in attributes.append(value) }
        }
        func all(_ mark: SemanticInlineMarks) -> Bool {
            !attributes.isEmpty && attributes.allSatisfy {
                SemanticInlineMarks(rawValue: ($0[NativeSemanticAttributes.marks] as? NSNumber)?.intValue ?? 0).contains(mark)
            }
        }
        state.bold = all(.bold); state.italic = all(.italic); state.underline = all(.underline)
        state.highlight = all(.highlight); state.strikethrough = all(.strikethrough)
        state.code = attributes.allSatisfy { $0[NativeSemanticAttributes.code] as? Bool == true }
        state.link = attributes.allSatisfy { $0[NativeSemanticAttributes.link] != nil }
        if let role = attributes.first?[NativeSemanticAttributes.paragraphRole] as? NativeSemanticParagraphRole {
            switch role {
            case .heading(let level): state.textStyle = .heading(level)
            case .code: state.context = .codeBlock
            case .listItem(let start, _, let checked):
                state.listPressed = checked != nil ? .checklist : start != nil ? .numbered : .bulleted
                state.listChecked = state.listPressed
                state.showsIndentRows = true
            default: break
            }
        }
        return state
    }

    @discardableResult
    func applyFormat(_ format: MarkdownFormat) -> Bool {
        guard !(textView.window?.firstResponder is NativeSemanticCellMathSourceView) else { return false }
        guard textView.isEditable, !hasActiveComposition, !isWritingToolsActive else { return false }
        if let block = activeSourceBlockSession {
            block.coordinator.apply(format)
            return true
        }
        if let session = activeTableSession { return session.applyFormat(format) }
        if format == .toggleChecked, textView.selectedRange().length == 0 { return toggleChecklist(at: textView.selectedRange().location) }
        switch format {
        case .bold: return inlineEditor.toggle(.bold)
        case .italic: return inlineEditor.toggle(.italic)
        case .underline: return inlineEditor.toggle(.underline)
        case .highlight: return inlineEditor.toggle(.highlight)
        case .strikethrough: return inlineEditor.toggle(.strikethrough)
        case .code, .clearFormatting, .link:
            return applyInlineFormat(format)
        default: break
        }
        let selected = selectedBlockIDs()
        if selected.isEmpty {
            if format == .table || format == .divider {
                var document = snapshot()
                let content: SemanticMarkdownBlock.Content = format == .divider ? .separator : .table(.init(
                    rows: Array(repeating: Array(repeating: .init(text: ""), count: 3), count: 3), alignments: [.left, .left, .left]))
                document.blocks.append(.init(content: content, lineEnding: "\n"))
                install(document, selection: .init(location: 0, length: 0), actionName: "Insert Block")
                return true
            }
            var attributes = safeTypingAttributes()
            let role: NativeSemanticParagraphRole
            switch format {
            case .heading(let level) where (1...6).contains(level): role = .heading(level: level)
            case .paragraph: role = .body
            case .bulletedList: role = .listItem(orderedStart: nil, indent: 0, checked: nil)
            case .numberedList: role = .listItem(orderedStart: 1, indent: 0, checked: nil)
            case .checklist: role = .listItem(orderedStart: nil, indent: 0, checked: false)
            case .quote: role = .quote(depth: 1)
            default: return false
            }
            attributes[NativeSemanticAttributes.paragraphRole] = role
            attributes[.paragraphStyle] = NativeSemanticAttributes.paragraphStyle(for: role, font: textView.font ?? .systemFont(ofSize: 16))
            attributes[NativeSemanticAttributes.blockID] = UUID()
            textView.typingAttributes = attributes
            return true
        }
        var document = snapshot()
        do {
            for index in document.blocks.indices where selected.contains(document.blocks[index].id) {
                let block = document.blocks[index]
                let inline: SemanticInlineText
                switch block.content {
                case .paragraph(let value), .heading(_, let value): inline = value
                case .list(let items):
                    inline = .init(runs: items.enumerated().flatMap { index, item in
                        item.text.runs + (index + 1 < items.count ? [.init(text: item.lineEnding.isEmpty ? "\n" : item.lineEnding)] : [])
                    })
                    document.blocks[index].lineEnding = items.last?.lineEnding ?? block.lineEnding
                case .quote(let lines):
                    inline = .init(runs: lines.enumerated().flatMap { index, line in
                        line.text.runs + (index + 1 < lines.count ? [.init(text: line.lineEnding.isEmpty ? "\n" : line.lineEnding)] : [])
                    })
                    document.blocks[index].lineEnding = lines.last?.lineEnding ?? block.lineEnding
                case .blank: inline = .init(text: "")
                case .code(_, let body, _): inline = .init(text: body)
                default: throw SemanticMarkdownCommands.Failure.protectedStructure
                }
                switch format {
                case .paragraph: document.blocks[index].content = .paragraph(inline)
                case .heading(let level):
                    guard (1...6).contains(level) else { return false }
                    document.blocks[index].content = .heading(level: level, text: inline)
                case .bulletedList, .numberedList, .checklist:
                    let start: Int? = format == .numberedList ? 1 : nil
                    let checked: Bool? = format == .checklist ? false : nil
                    if case .list(let items) = block.content,
                       items.allSatisfy({ ($0.orderedStart != nil) == (start != nil) && ($0.checked != nil) == (checked != nil) }) {
                        document.blocks[index].content = .paragraph(inline)
                        document.blocks[index].lineEnding = items.last?.lineEnding ?? block.lineEnding
                    } else {
                        document.blocks[index].content = .list([.init(orderedStart: start, indent: 0, checked: checked,
                            text: inline, lineEnding: block.lineEnding)])
                        document.blocks[index].lineEnding = ""
                    }
                case .indent, .outdent, .toggleChecked:
                    guard case .list(var items) = block.content else { return false }
                    for item in items.indices {
                        if format == .toggleChecked {
                            if let checked = items[item].checked { items[item].checked = !checked }
                        } else { items[item].indent = max(0, items[item].indent + (format == .indent ? 2 : -2)) }
                    }
                    document.blocks[index].content = .list(items)
                case .quote:
                    if case .quote = block.content { document.blocks[index].content = .paragraph(inline) }
                    else {
                        document.blocks[index].content = .quote([.init(depth: 1, text: inline, lineEnding: block.lineEnding)])
                        document.blocks[index].lineEnding = ""
                    }
                case .codeBlock:
                    if case .code = block.content { document.blocks[index].content = .paragraph(inline) }
                    else { document.blocks[index].content = .code(language: nil, body: inline.text, isClosed: true) }
                case .divider, .table, .moveLines: break
                case .align(let alignment):
                    document.blocks[index].alignment = alignment
                    if document.blocks[index].lineEnding.isEmpty { document.blocks[index].lineEnding = "\n" }
                    if index > 0, document.blocks[index - 1].lineEnding.isEmpty { document.blocks[index - 1].lineEnding = "\n" }
                default: return false
                }
            }
            if format == .divider || format == .table {
                let position = document.blocks.lastIndex { selected.contains($0.id) }! + 1
                let content: SemanticMarkdownBlock.Content = format == .divider ? .separator : .table(.init(
                    rows: Array(repeating: Array(repeating: .init(text: ""), count: 3), count: 3),
                    alignments: [.left, .left, .left]))
                if position > 0, document.blocks[position - 1].lineEnding.isEmpty { document.blocks[position - 1].lineEnding = "\n" }
                document.blocks.insert(.init(content: content, lineEnding: "\n"), at: position)
            }
            if case .moveLines(let up) = format {
                guard let first = document.blocks.firstIndex(where: { selected.contains($0.id) }),
                      let last = document.blocks.lastIndex(where: { selected.contains($0.id) }),
                      up ? first > 0 : last + 1 < document.blocks.count else { return false }
                if up { let previous = document.blocks.remove(at: first - 1); document.blocks.insert(previous, at: last) }
                else { let next = document.blocks.remove(at: last + 1); document.blocks.insert(next, at: first) }
            }
            _ = try SemanticMarkdownImport.export(document)
            install(document, selection: textView.selectedRange(), actionName: "Format")
            return true
        } catch { onExportFailure?(error); return false }
    }

    func selectedBlockIDs() -> Set<UUID> {
        guard let storage = textView.textStorage, storage.length > 0 else { return [] }
        let selection = textView.selectedRange()
        let range = selection.length > 0 ? selection : NSRange(location: min(selection.location, storage.length - 1), length: 1)
        var result = Set<UUID>()
        storage.enumerateAttribute(NativeSemanticAttributes.blockID, in: range) { value, _, _ in
            if let id = value as? UUID { result.insert(id) }
        }
        return result
    }

    func install(_ document: SemanticMarkdownDocument, selection: NSRange, actionName: String) {
        textView.preservingSemanticViewport {
            installPreservingHistory(document, selection: selection, actionName: actionName)
        }
    }

    private func installPreservingHistory(_ document: SemanticMarkdownDocument, selection: NSRange, actionName: String) {
        let previous = snapshot()
        let previousSelection = textView.selectedRange()
        documentUndoManager.registerUndo(withTarget: self) { owner in
            MainActor.assumeIsolated { owner.install(previous, selection: previousSelection, actionName: actionName) }
        }
        documentUndoManager.setActionName(actionName)
        documentStorage.load(document, selectedRange: selection)
        committedContentChanged()
    }

    private func applyInlineFormat(_ format: MarkdownFormat) -> Bool {
        guard let storage = textView.textStorage else { return false }
        var range = textView.selectedRange()
        if range.length == 0, format == .clearFormatting {
            range = (storage.string as NSString).paragraphRange(for: range)
        }
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return false }
        let selected = storage.attributedSubstring(from: range)
        let inline = NativeSemanticAttributes.inlineText(selected)
        let allCode = inline.runs.allSatisfy { if case .code = $0.payload { return true }; return false }
        let updated = SemanticInlineText(runs: inline.runs.map { run in
            switch format {
            case .clearFormatting:
                if case .object = run.payload { return run }
                return SemanticInlineRun(text: run.text)
            case .code:
                if case .object = run.payload { return run }
                return SemanticInlineRun(payload: allCode ? .text(run.text) : .code(run.text), marks: run.marks, link: run.link)
            case .link: return SemanticInlineRun(payload: run.payload, marks: run.marks, link: .url(destination: "https://", title: nil))
            default: return run
            }
        })
        let replacement = NSMutableAttributedString(attributedString: NativeSemanticAttributes.attributedText(updated, font: textView.font ?? .systemFont(ofSize: 14)))
        selected.enumerateAttributes(in: NSRange(location: 0, length: selected.length)) { attrs, part, _ in
            for key in [NativeSemanticAttributes.blockID, NativeSemanticAttributes.paragraphRole, NativeSemanticAttributes.blockLineEnding, NSAttributedString.Key("MarkdownEngine.semanticAlignment"), .paragraphStyle] {
                if let value = attrs[key] { replacement.addAttribute(key, value: value, range: part) }
            }
        }
        NativeSemanticAttributes.renderObjects(in: replacement, configuration: configuration,
            font: textView.font ?? .systemFont(ofSize: 16), maxWidth: textView.textContainer?.size.width ?? 600)
        return replaceVisible(range, with: replacement, actionName: "Format", selection: textView.selectedRange())
    }

    @discardableResult
    func replaceVisible(_ range: NSRange, with replacement: NSAttributedString, actionName: String,
                        selection: NSRange? = nil) -> Bool {
        textView.preservingSemanticViewport {
            replaceVisiblePreservingHistory(range, with: replacement, actionName: actionName, selection: selection)
        }
    }

    private func replaceVisiblePreservingHistory(_ range: NSRange, with replacement: NSAttributedString,
                                                 actionName: String, selection: NSRange?) -> Bool {
        guard textView.isEditable, !hasActiveComposition, let storage = textView.textStorage,
              range.location >= 0, range.length >= 0, NSMaxRange(range) <= storage.length else { return false }
        let before = NSAttributedString(attributedString: storage)
        let previousSelection = textView.selectedRange()
        documentUndoManager.disableUndoRegistration()
        let admitted = textView.shouldChangeText(in: range, replacementString: replacement.string)
        documentUndoManager.enableUndoRegistration()
        guard admitted else { return false }
        documentUndoManager.disableUndoRegistration()
        storage.replaceCharacters(in: range, with: replacement)
        textView.setSelectedRange(selection ?? NSRange(location: range.location + replacement.length, length: 0))
        textView.didChangeText()
        documentUndoManager.enableUndoRegistration()
        registerStorageUndo(before, selection: previousSelection, actionName: actionName)
        return true
    }

    private func registerStorageUndo(_ content: NSAttributedString, selection: NSRange, actionName: String) {
        documentUndoManager.registerUndo(withTarget: self) { owner in
            MainActor.assumeIsolated {
                owner.textView.preservingSemanticViewport {
                    owner.restoreStorage(content, selection: selection, actionName: actionName)
                }
            }
        }
        documentUndoManager.setActionName(actionName)
    }

    private func restoreStorage(_ content: NSAttributedString, selection: NSRange, actionName: String) {
        guard let storage = textView.textStorage else { return }
        let inverse = NSAttributedString(attributedString: storage)
        let inverseSelection = textView.selectedRange()
        storage.setAttributedString(content)
        textView.setSelectedRange(selection)
        registerStorageUndo(inverse, selection: inverseSelection, actionName: actionName)
        committedContentChanged()
    }
}
