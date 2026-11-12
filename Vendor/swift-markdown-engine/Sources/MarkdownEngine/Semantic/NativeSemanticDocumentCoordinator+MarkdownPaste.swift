import AppKit

extension NativeSemanticDocumentCoordinator {
    func pasteMarkdownDocument(_ source: String) throws -> Bool? {
        let imported = try SemanticMarkdownImport.decode(source)
        if imported.blocks.count == 1, case .paragraph = imported.blocks[0].content { return nil }
        guard !hasActiveComposition, let storage = textView.textStorage else { return false }
        let selection = textView.selectedRange()
        var document = snapshot()
        let selected = selectedBlockIDs()
        let first = document.blocks.firstIndex { selected.contains($0.id) } ?? document.blocks.count
        let last = document.blocks.lastIndex { selected.contains($0.id) } ?? first
        var insertion = imported.blocks.map { SemanticMarkdownBlock(content: $0.content, lineEnding: $0.lineEnding, alignment: $0.alignment) }
        var nativeStart = selection.location
        var prefix: SemanticInlineText?
        var suffix: SemanticInlineText?
        if storage.length > 0, first < document.blocks.count {
            var startRange = NSRange(), endRange = NSRange()
            _ = storage.attribute(NativeSemanticAttributes.blockID, at: min(selection.location, storage.length - 1), longestEffectiveRange: &startRange, in: NSRange(location: 0, length: storage.length))
            _ = storage.attribute(NativeSemanticAttributes.blockID, at: min(max(selection.location, NSMaxRange(selection) - 1), storage.length - 1), longestEffectiveRange: &endRange, in: NSRange(location: 0, length: storage.length))
            nativeStart = startRange.location
            let before = NSRange(location: startRange.location, length: max(0, selection.location - startRange.location))
            let after = NSRange(location: NSMaxRange(selection), length: max(0, NSMaxRange(endRange) - NSMaxRange(selection)))
            if before.length > 0 { prefix = NativeSemanticAttributes.inlineText(storage.attributedSubstring(from: before)) }
            if after.length > 0 { suffix = NativeSemanticAttributes.inlineText(storage.attributedSubstring(from: after)) }
        }
        if let prefix, !prefix.text.isEmpty {
            insertion.insert(contentsOf: [.init(content: .paragraph(prefix), lineEnding: "\n"), .init(content: .blank("\n"))], at: 0)
        }
        if let end = insertion.indices.last, insertion[end].lineEnding.isEmpty {
            switch insertion[end].content {
            case .list, .quote, .blank: break
            default: insertion[end].lineEnding = "\n"
            }
        }
        let caret = nativeStart + insertion.reduce(0) { $0 + $1.content.visibleText.utf16.count + $1.lineEnding.utf16.count }
        if let suffix, !suffix.text.isEmpty {
            insertion.append(.init(content: .blank("\n")))
            insertion.append(.init(content: .paragraph(suffix)))
        }
        if first < document.blocks.count { document.blocks.replaceSubrange(first...last, with: insertion) }
        else { document.blocks.append(contentsOf: insertion) }
        _ = try SemanticMarkdownImport.export(document)
        install(document, selection: NSRange(location: caret, length: 0), actionName: "Paste Markdown")
        return true
    }
}
