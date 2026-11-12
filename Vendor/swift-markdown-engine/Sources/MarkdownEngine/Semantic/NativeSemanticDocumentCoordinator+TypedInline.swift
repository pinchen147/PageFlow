import AppKit

extension NativeSemanticDocumentCoordinator {
    func completeTypedInlineSyntax() {
        guard !hasActiveComposition, !isWritingToolsActive,
              let edit = Self.typedInlineReplacement(in: textView) else { return }
        let typing = safeTypingAttributes()
        if replaceVisible(edit.range, with: edit.text, actionName: "Complete Markdown") { textView.typingAttributes = typing }
    }

    static func typedInlineReplacement(in textView: NSTextView) -> (range: NSRange, text: NSAttributedString)? {
        guard !textView.hasMarkedText(), let storage = textView.textStorage else { return nil }
        let caret = textView.selectedRange()
        guard caret.length == 0, caret.location > 0 else { return nil }
        let string = storage.string as NSString
        let line = string.paragraphRange(for: NSRange(location: caret.location - 1, length: 0))
        let prefix = string.substring(with: NSRange(location: line.location, length: caret.location - line.location)) as NSString
        let role = storage.attribute(NativeSemanticAttributes.paragraphRole, at: caret.location - 1, effectiveRange: nil) as? NativeSemanticParagraphRole
        if case .code? = role { return nil }
        for delimiter in ["***", "___", "**", "__", "~~", "==", "`", "*", "_"] {
            let length = delimiter.utf16.count
            guard prefix.length > length * 2, prefix.hasSuffix(delimiter) else { continue }
            let opening = prefix.range(of: delimiter, options: .backwards, range: NSRange(location: 0, length: prefix.length - length))
            guard opening.location != NSNotFound, opening.location + length < prefix.length - length else { continue }
            if opening.location > 0 {
                let previous = prefix.character(at: opening.location - 1)
                if previous == 92 || previous == (delimiter as NSString).character(at: 0) { continue }
            }
            let range = NSRange(location: line.location + opening.location, length: prefix.length - opening.location)
            let selected = storage.attributedSubstring(from: range)
            var literal = true
            selected.enumerateAttributes(in: NSRange(location: 0, length: selected.length)) { attributes, _, _ in
                if (attributes[NativeSemanticAttributes.marks] as? NSNumber)?.intValue ?? 0 != 0 ||
                    attributes[NativeSemanticAttributes.code] as? Bool == true ||
                    attributes[NativeSemanticAttributes.link] != nil || attributes[.attachment] != nil { literal = false }
            }
            guard literal, let decoded = try? SemanticInlineCodec.decode(selected.string), decoded.text != selected.string else { continue }
            let replacement = NSMutableAttributedString(attributedString: NativeSemanticAttributes.attributedText(decoded,
                font: textView.font ?? .systemFont(ofSize: 16)))
            for key in [NativeSemanticAttributes.blockID, NativeSemanticAttributes.paragraphRole,
                        NativeSemanticAttributes.blockLineEnding, NSAttributedString.Key("MarkdownEngine.semanticAlignment"), .paragraphStyle, .foregroundColor] {
                if let value = selected.attribute(key, at: 0, effectiveRange: nil) {
                    replacement.addAttribute(key, value: value, range: NSRange(location: 0, length: replacement.length))
                }
            }
            return (range, replacement)
        }
        return nil
    }
}
