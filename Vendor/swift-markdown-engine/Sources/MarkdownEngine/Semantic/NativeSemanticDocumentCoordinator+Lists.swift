import AppKit

extension NativeSemanticDocumentCoordinator {
    @discardableResult
    func toggleChecklist(at location: Int) -> Bool {
        guard textView.isEditable, !hasActiveComposition, !isWritingToolsActive,
              let storage = textView.textStorage, location >= 0, location < storage.length else { return false }
        var range = NSRange()
        guard let id = storage.attribute(NativeSemanticAttributes.blockID, at: location, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)) as? UUID else { return false }
        var document = snapshot()
        guard let blockIndex = document.blocks.firstIndex(where: { $0.id == id }),
              case .list(var items) = document.blocks[blockIndex].content else { return false }
        var offset = location - range.location
        for index in items.indices {
            let length = items[index].text.utf16Count + items[index].lineEnding.utf16.count
            if offset < length || (index == items.count - 1 && offset == length) {
                guard let checked = items[index].checked else { return false }
                items[index].checked = !checked
                document.blocks[blockIndex].content = .list(items)
                do {
                    _ = try SemanticMarkdownImport.export(document)
                    install(document, selection: textView.selectedRange(), actionName: "Toggle Checklist")
                    return true
                } catch { onExportFailure?(error); return false }
            }
            offset -= length
        }
        return false
    }

    func routeChecklistClick(_ event: NSEvent) -> Bool {
        let point = textView.convert(event.locationInWindow, from: nil)
        let location = textView.characterIndexForInsertion(at: point)
        guard let storage = textView.textStorage, location < storage.length,
              case .listItem(_, _, .some)? = storage.attribute(NativeSemanticAttributes.paragraphRole, at: location, effectiveRange: nil) as? NativeSemanticParagraphRole,
              let window = textView.window else { return false }
        let line = (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
        let screen = textView.firstRect(forCharacterRange: NSRange(location: line.location, length: 0), actualRange: nil)
        let caret = textView.convert(window.convertFromScreen(screen), from: nil)
        let width = (textView.font?.pointSize ?? 16) * 2
        let marker = NSRect(x: caret.minX - width, y: caret.minY, width: width, height: max(16, caret.height))
        return marker.contains(point) && toggleChecklist(at: line.location)
    }
}
