import AppKit

extension NativeSemanticDocumentCoordinator {
    public func textView(_ textView: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        let result = menu.copy() as? NSMenu ?? NSMenu()
        if let font = result.items.firstIndex(where: { $0.title == "Font" }) { result.removeItem(at: font) }
        func section(_ name: String, entries: [(String, MarkdownFormat)]) -> NSMenuItem {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            let children = NSMenu(title: name)
            children.autoenablesItems = false
            for (title, format) in entries {
                let child = NSMenuItem(title: title, action: #selector(applySemanticMenuFormat(_:)), keyEquivalent: "")
                child.target = self
                child.representedObject = format
                child.isEnabled = textView.isEditable && !textView.hasMarkedText() && !isWritingToolsActive
                children.addItem(child)
            }
            item.submenu = children
            return item
        }
        result.insertItem(section("Format", entries: [("Bold", .bold), ("Italic", .italic), ("Underline", .underline),
            ("Strikethrough", .strikethrough), ("Highlight", .highlight), ("Code", .code), ("Clear Formatting", .clearFormatting)]), at: 0)
        result.insertItem(section("Heading", entries: [("Text", .paragraph)] + (1...6).map { ("H\($0)", .heading(level: $0)) }), at: 1)
        result.insertItem(section("Lists", entries: [("Bullet", .bulletedList), ("Numbered", .numberedList),
            ("Checklist", .checklist), ("Indent", .indent), ("Outdent", .outdent)]), at: 2)
        result.insertItem(.separator(), at: 3)
        let copy = NSMenuItem(title: "Copy as Markdown", action: #selector(NativeSemanticTextView.copyAsMarkdown(_:)), keyEquivalent: "")
        copy.target = self.textView
        result.addItem(copy)
        let paste = NSMenuItem(title: "Paste as Markdown", action: #selector(NativeSemanticTextView.pasteAsMarkdown(_:)), keyEquivalent: "")
        paste.target = self.textView
        result.addItem(paste)
        if let storage = textView.textStorage, charIndex >= 0, charIndex < storage.length,
           storage.attribute(.attachment, at: charIndex, effectiveRange: nil) != nil {
            textView.setSelectedRange(NSRange(location: charIndex, length: 1))
            let source = NSMenuItem(title: "Edit Source", action: #selector(editObjectFromMenu(_:)), keyEquivalent: "")
            source.target = self
            result.insertItem(source, at: 0)
            if case .image? = storage.attribute(NativeSemanticAttributes.object, at: charIndex, effectiveRange: nil) as? SemanticInlineObject {
                for (title, action) in [("Crop Image", #selector(cropImageFromMenu(_:))), ("Edit Alt Text", #selector(editAltFromMenu(_:)))] {
                    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                    item.target = self
                    result.insertItem(item, at: 1)
                }
            }
        }
        return result
    }

    @objc private func applySemanticMenuFormat(_ sender: NSMenuItem) {
        if let format = sender.representedObject as? MarkdownFormat { _ = applyFormat(format) }
    }
    @objc private func editObjectFromMenu(_ sender: Any?) { editObject(at: textView.selectedRange().location) }
    @objc private func cropImageFromMenu(_ sender: Any?) { beginImageCrop() }
    @objc private func editAltFromMenu(_ sender: Any?) { editImageAltText() }
}
