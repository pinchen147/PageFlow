import AppKit

extension NativeSemanticCellTextView {
    var hasProtectedMathSourceInput: Bool { mathEditors.values.contains { $0.hasProtectedInput } }

    func typedMathReplacement() -> (range: NSRange, text: NSAttributedString)? {
        guard !hasMarkedText(), !hasWritingToolsSnapshot, let session, let storage = textStorage else { return nil }
        let caret = selectedRange()
        guard caret.length == 0, caret.location >= 3, caret.location <= storage.length else { return nil }
        let text = storage.string as NSString
        guard text.character(at: caret.location - 1) == 36 else { return nil }
        let line = text.paragraphRange(for: NSRange(location: caret.location - 1, length: 0))
        let opening = text.range(of: "$", options: .backwards,
            range: NSRange(location: line.location, length: caret.location - 1 - line.location))
        guard opening.location != NSNotFound, caret.location - opening.location > 2 else { return nil }
        var slash = opening.location
        while slash > line.location, text.character(at: slash - 1) == 92 { slash -= 1 }
        guard (opening.location - slash) % 2 == 0 else { return nil }
        let range = NSRange(location: opening.location, length: caret.location - opening.location)
        let candidate = storage.attributedSubstring(from: range)
        var literal = true
        candidate.enumerateAttributes(in: NSRange(location: 0, length: candidate.length)) { attrs, _, _ in
            if attrs[.attachment] != nil || attrs[NativeSemanticAttributes.link] != nil || attrs[NativeSemanticAttributes.code] as? Bool == true { literal = false }
        }
        guard literal, let decoded = try? SemanticInlineCodec.decode(candidate.string), decoded.runs.count == 1,
              case .object(.math) = decoded.runs[0].payload else { return nil }
        let attributes = candidate.attributes(at: 0, effectiveRange: nil)
        let inline = SemanticInlineText(runs: [.init(payload: decoded.runs[0].payload,
                                                    marks: NativeSemanticAttributes.marks(in: attributes))])
        let font = (attributes[.font] as? NSFont) ?? MarkdownTableLayout.cellFont(for: session.presentationFont)
        let result = NSMutableAttributedString(attributedString: NativeSemanticAttributes.attributedText(inline, font: font))
        for key in [NSAttributedString.Key.paragraphStyle, .baselineOffset, .foregroundColor] {
            if let value = attributes[key] { result.addAttribute(key, value: value, range: NSRange(location: 0, length: result.length)) }
        }
        NativeSemanticAttributes.renderObjects(in: result, configuration: session.configuration, font: font, maxWidth: max(80, bounds.width))
        return (range, result)
    }

    @discardableResult
    func revealMathSource(at index: Int) -> Bool {
        guard isEditable, !hasMarkedText(), !hasWritingToolsSnapshot, !hasProtectedMathSourceInput,
              let storage = textStorage,
              index >= 0, index < storage.length,
              case .math(let source)? = storage.attribute(NativeSemanticAttributes.object, at: index, effectiveRange: nil) as? SemanticInlineObject,
              let id = storage.attribute(NativeSemanticAttributes.objectID, at: index, effectiveRange: nil) as? UUID else { return false }
        for editor in mathEditors.values where editor.objectID != id { editor.dismiss(restoreFocus: false) }
        let editor = mathEditors[id] ?? NativeSemanticCellMathEditor(source: source, objectID: id, cell: self)
        mathEditors[id] = editor
        setSelectedRange(NSRange(location: index, length: 1))
        editor.show()
        return true
    }

    func normalizedMathSnapshot(_ content: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: content)
        content.enumerateAttribute(NativeSemanticAttributes.objectID, in: NSRange(location: 0, length: content.length)) { value, range, _ in
            guard let id = value as? UUID, let editor = mathEditors[id],
                  case .math? = content.attribute(NativeSemanticAttributes.object, at: range.location, effectiveRange: nil) as? SemanticInlineObject else { return }
            result.addAttribute(NativeSemanticAttributes.object, value: SemanticInlineObject.math(editor.committedSource), range: range)
        }
        return result
    }

    func refreshMathObjects() {
        guard !hasMarkedText(), !hasWritingToolsSnapshot, let session, let storage = textStorage else { return }
        var updates: [(NSRange, [NSAttributedString.Key: Any])] = []
        storage.enumerateAttribute(NativeSemanticAttributes.objectID, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let id = value as? UUID, let editor = mathEditors[id], !editor.hasProtectedInput,
                  case .math? = storage.attribute(NativeSemanticAttributes.object, at: range.location, effectiveRange: nil) as? SemanticInlineObject else { return }
            let rendered = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
            rendered.addAttribute(NativeSemanticAttributes.object, value: SemanticInlineObject.math(editor.committedSource),
                                  range: NSRange(location: 0, length: rendered.length))
            NativeSemanticAttributes.renderObjects(in: rendered, configuration: session.configuration,
                font: MarkdownTableLayout.cellFont(for: session.presentationFont), maxWidth: max(80, bounds.width))
            updates.append((range, rendered.attributes(at: 0, effectiveRange: nil)))
        }
        guard !updates.isEmpty else { return }
        storage.beginEditing()
        for (range, attributes) in updates { storage.addAttributes(attributes, range: range) }
        storage.endEditing()
    }

    /// Identity is transferred by ordered object occurrence only when the entire
    /// cell's semantic content agrees; equal formula strings are never searched.
    func preserveMathIdentities(in replacement: NSMutableAttributedString, matching value: SemanticInlineText) {
        let before = committedSnapshot()
        guard NativeSemanticAttributes.inlineText(before) == value else {
            for editor in mathEditors.values { editor.dismiss(restoreFocus: false) }
            return
        }
        var ids: [UUID] = []
        before.enumerateAttribute(NativeSemanticAttributes.objectID, in: NSRange(location: 0, length: before.length)) { value, _, _ in
            if let id = value as? UUID { ids.append(id) }
        }
        var ranges: [NSRange] = []
        replacement.enumerateAttribute(NativeSemanticAttributes.objectID, in: NSRange(location: 0, length: replacement.length)) { value, range, _ in
            if value is UUID { ranges.append(range) }
        }
        guard ids.count == ranges.count else { return }
        for (id, range) in zip(ids, ranges) { replacement.addAttribute(NativeSemanticAttributes.objectID, value: id, range: range) }
    }
}
