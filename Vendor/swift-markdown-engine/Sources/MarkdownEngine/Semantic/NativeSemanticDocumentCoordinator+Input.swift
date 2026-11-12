import AppKit

extension NativeSemanticDocumentCoordinator {
    func admitParagraphRoles() {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let string = storage.string as NSString
        var offset = 0
        var bodyID: UUID?
        var blankID: UUID?
        var usedIDs = Set<UUID>()
        func setMetadata(_ attributes: [NSAttributedString.Key: AnyHashable], range: NSRange) {
            for (key, value) in attributes {
                var changes: [NSRange] = []
                storage.enumerateAttribute(key, in: range) { existing, subrange, _ in
                    if (existing as? AnyHashable) != value { changes.append(subrange) }
                }
                for subrange in changes { storage.addAttribute(key, value: value.base, range: subrange) }
            }
        }
        storage.beginEditing()
        defer { storage.endEditing() }
        while offset < string.length {
            var start = 0, end = 0, contentEnd = 0
            string.getLineStart(&start, end: &end, contentsEnd: &contentEnd, for: NSRange(location: offset, length: 0))
            let range = NSRange(location: start, length: end - start)
            let text = string.substring(with: NSRange(location: start, length: contentEnd - start))
            let role = storage.attribute(NativeSemanticAttributes.paragraphRole, at: start, effectiveRange: nil) as? NativeSemanticParagraphRole ?? .body
            switch role {
            case .body, .blank:
                if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    bodyID = nil
                    let previous = (storage.attribute(NativeSemanticAttributes.blockID, at: start, effectiveRange: nil) as? UUID) ?? UUID()
                    let id = blankID ?? (usedIDs.contains(previous) ? UUID() : previous)
                    blankID = id
                    usedIDs.insert(id)
                    setMetadata([NativeSemanticAttributes.paragraphRole: NativeSemanticParagraphRole.blank,
                                           NativeSemanticAttributes.blockID: id,
                                           NativeSemanticAttributes.blockLineEnding: ""], range: range)
                } else {
                    blankID = nil
                    let previous = (storage.attribute(NativeSemanticAttributes.blockID, at: start, effectiveRange: nil) as? UUID) ?? UUID()
                    let id = bodyID ?? (usedIDs.contains(previous) ? UUID() : previous)
                    bodyID = id
                    usedIDs.insert(id)
                    let ending = string.substring(with: NSRange(location: contentEnd, length: end - contentEnd))
                    setMetadata([NativeSemanticAttributes.paragraphRole: NativeSemanticParagraphRole.body,
                                           NativeSemanticAttributes.blockID: id,
                                           NativeSemanticAttributes.blockLineEnding: ending], range: range)
                }
            default:
                bodyID = nil
                blankID = nil
                if let id = storage.attribute(NativeSemanticAttributes.blockID, at: start, effectiveRange: nil) as? UUID { usedIDs.insert(id) }
            }
            offset = end
        }
    }

    /// Return is a document edit: the new paragraph owns a new identity and role.
    func insertParagraphBreak() -> Bool {
        guard textView.isEditable, !textView.hasMarkedText(), !isWritingToolsActive,
              let storage = textView.textStorage else { return false }
        let selection = textView.selectedRange()
        guard selection.length == 0, storage.length > 0 else { return false }
        let anchor = min(selection.location, storage.length - 1)
        var blockRange = NSRange()
        guard let id = storage.attribute(NativeSemanticAttributes.blockID, at: anchor, longestEffectiveRange: &blockRange, in: NSRange(location: 0, length: storage.length)) as? UUID else { return false }
        var document = snapshot()
        guard let index = document.blocks.firstIndex(where: { $0.id == id }) else { return false }
        do {
            switch document.blocks[index].content {
            case .paragraph:
                let offset = min(selection.location - blockRange.location, document.blocks[index].content.visibleText.utf16.count)
                try SemanticMarkdownCommands.apply(.splitParagraph(block: id, at: offset), to: &document)
                _ = try SemanticMarkdownImport.export(document)
                install(document, selection: NSRange(location: selection.location + (offset > 0 ? 2 : 1), length: 0), actionName: "New Paragraph")
                textView.typingAttributes = safeTypingAttributes()
                return true
            case .heading(_, let inline):
                let offset = min(selection.location - blockRange.location, inline.utf16Count)
                let left = try inline.slice(in: NSRange(location: 0, length: offset))
                let right = try inline.slice(in: NSRange(location: offset, length: inline.utf16Count - offset))
                let ending = document.blocks[index].lineEnding
                if case .heading(let level, _) = document.blocks[index].content { document.blocks[index].content = .heading(level: level, text: left) }
                document.blocks[index].lineEnding = "\n"
                document.blocks.insert(.init(content: right.text.isEmpty ? .blank("\n") : .paragraph(right), lineEnding: ending), at: index + 1)
                _ = try SemanticMarkdownImport.export(document)
                install(document, selection: NSRange(location: selection.location + 1, length: 0), actionName: "New Paragraph")
                textView.typingAttributes = safeTypingAttributes()
                return true
            case .list(var items):
                var remaining = selection.location - blockRange.location
                guard let itemIndex = items.indices.first(where: { i in
                    let length = items[i].text.utf16Count + items[i].lineEnding.utf16.count
                    if remaining <= items[i].text.utf16Count { return true }
                    remaining -= length
                    return false
                }) else { return false }
                let item = items[itemIndex]
                if item.text.text.isEmpty {
                    var replacements: [SemanticMarkdownBlock] = []
                    if itemIndex > 0 { replacements.append(.init(content: .list(Array(items[..<itemIndex])))) }
                    replacements.append(.init(content: .blank("\n")))
                    if itemIndex + 1 < items.count { replacements.append(.init(content: .list(Array(items[(itemIndex + 1)...])))) }
                    document.blocks.replaceSubrange(index...index, with: replacements)
                    _ = try SemanticMarkdownImport.export(document)
                    install(document, selection: selection, actionName: "Exit List")
                    textView.typingAttributes = safeTypingAttributes()
                    return true
                }
                let left = try item.text.slice(in: NSRange(location: 0, length: remaining))
                let right = try item.text.slice(in: NSRange(location: remaining, length: item.text.utf16Count - remaining))
                items[itemIndex].text = left
                items[itemIndex].lineEnding = "\n"
                items.insert(.init(orderedStart: item.orderedStart.map { $0 + 1 }, indent: item.indent,
                    checked: item.checked.map { _ in false }, text: right,
                    lineEnding: right.text.isEmpty ? "\n" : item.lineEnding), at: itemIndex + 1)
                document.blocks[index].content = .list(items)
                _ = try SemanticMarkdownImport.export(document)
                install(document, selection: NSRange(location: selection.location + 1, length: 0), actionName: "New List Item")
                return true
            case .quote(var lines):
                var remaining = selection.location - blockRange.location
                guard let lineIndex = lines.indices.first(where: { i in
                    if remaining <= lines[i].text.utf16Count { return true }
                    remaining -= lines[i].text.utf16Count + lines[i].lineEnding.utf16.count
                    return false
                }) else { return false }
                let line = lines[lineIndex]
                if line.text.text.isEmpty { return applyFormat(.paragraph) }
                lines[lineIndex].text = try line.text.slice(in: NSRange(location: 0, length: remaining))
                lines[lineIndex].lineEnding = "\n"
                let right = try line.text.slice(in: NSRange(location: remaining, length: line.text.utf16Count - remaining))
                lines.insert(.init(depth: line.depth, text: right, lineEnding: right.text.isEmpty ? "\n" : line.lineEnding), at: lineIndex + 1)
                document.blocks[index].content = .quote(lines)
                _ = try SemanticMarkdownImport.export(document)
                install(document, selection: NSRange(location: selection.location + 1, length: 0), actionName: "New Quote Line")
                return true
            default: return false
            }
        } catch { onExportFailure?(error); return false }
    }

    /// Completion consumes only a newly typed block prefix, leaving native text and marks intact.
    func completeTypedBlockPrefix() {
        guard !textView.hasMarkedText(), let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        guard selection.length == 0, selection.location > 0 else { return }
        let paragraph = (storage.string as NSString).paragraphRange(for: selection)
        let prefixRange = NSRange(location: paragraph.location, length: selection.location - paragraph.location)
        let prefix = (storage.string as NSString).substring(with: prefixRange)
        let format: MarkdownFormat
        if prefix == "- " || prefix == "* " || prefix == "+ " { format = .bulletedList }
        else if prefix == "1. " { format = .numberedList }
        else if prefix == "> " { format = .quote }
        else if prefix.hasSuffix(" "), (1...6).contains(prefix.count - 1), prefix.dropLast().allSatisfy({ $0 == "#" }) {
            format = .heading(level: prefix.count - 1)
        } else { return }
        let role = storage.attribute(NativeSemanticAttributes.paragraphRole, at: paragraph.location, effectiveRange: nil) as? NativeSemanticParagraphRole
        guard role == .body || role == .blank else { return }
        documentUndoManager.beginUndoGrouping()
        defer { documentUndoManager.endUndoGrouping() }
        if replaceVisible(prefixRange, with: NSAttributedString(string: ""), actionName: "Complete Markdown") {
            _ = applyFormat(format)
        }
    }
}
