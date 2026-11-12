import AppKit

/// An isolated visible-text editing gate. The mounted text view owns ordinary input.
@MainActor
final class NativeSemanticInlineEditor {
    private static let marksKey = NativeSemanticAttributes.marks
    private static let baseFontKey = NativeSemanticAttributes.baseFont
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
    }

    /// Mount an initial semantic value before native editing begins.
    func load(_ text: SemanticInlineText) {
        guard let textView, let storage = textView.textStorage else { return }
        let font = textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        storage.setAttributedString(NativeSemanticAttributes.attributedText(text, font: font))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.typingAttributes = [.font: font]
    }

    func snapshot() -> SemanticInlineText {
        guard let storage = textView?.textStorage else { return SemanticInlineText(text: "") }
        return NativeSemanticAttributes.inlineText(storage)
    }

    /// A mixed selection turns the requested mark on everywhere; an all-on selection turns it off.
    @discardableResult
    func toggle(_ mark: SemanticInlineMarks) -> Bool {
        guard let textView, textView.isEditable, !textView.hasMarkedText(),
              [SemanticInlineMarks.bold, .italic, .underline, .highlight, .strikethrough].contains(mark),
              textView.selectedRanges.count == 1,
              let storage = textView.textStorage else { return false }
        let range = textView.selectedRange()
        guard (try? SemanticInlineText.validatedBounds(range, in: storage.string)) != nil else {
            return false
        }

        if range.length == 0 {
            let attributes = textView.typingAttributes
            let current = Self.marks(in: attributes)
            let updated = current.contains(mark) ? current.subtracting(mark) : current.union(mark)
            textView.typingAttributes = Self.render(updated, over: attributes)
            return true
        }

        let before = capture(range, in: textView, storage: storage)
        let replacement = NSMutableAttributedString(attributedString: before.content)
        var allOn = true
        replacement.enumerateAttributes(in: NSRange(location: 0, length: replacement.length)) {
            attributes, _, _ in
            if !Self.marks(in: attributes).contains(mark) { allOn = false }
        }
        let turnOff = allOn
        replacement.enumerateAttributes(in: NSRange(location: 0, length: replacement.length)) {
            attributes, subrange, _ in
            let current = Self.marks(in: attributes)
            let updated = turnOff ? current.subtracting(mark) : current.union(mark)
            replacement.setAttributes(Self.render(updated, over: attributes), range: subrange)
        }

        textView.breakUndoCoalescing()
        let manager = textView.undoManager
        manager?.disableUndoRegistration()
        let admitted = textView.shouldChangeText(in: range, replacementString: nil)
        manager?.enableUndoRegistration()
        guard admitted else { return false }

        manager?.beginUndoGrouping()
        manager?.disableUndoRegistration()
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: replacement)
        storage.endEditing()
        textView.selectedRanges = before.selection
        let typing = Self.marks(in: before.typingAttributes)
        textView.typingAttributes = Self.render(
            turnOff ? typing.subtracting(mark) : typing.union(mark), over: before.typingAttributes)
        textView.didChangeText()
        manager?.enableUndoRegistration()
        registerInverse(before, manager: manager)
        manager?.setActionName(Self.actionName(mark))
        manager?.endUndoGrouping()
        textView.breakUndoCoalescing()
        return true
    }

    private struct EditState {
        let range: NSRange
        let content: NSAttributedString
        let selection: [NSValue]
        let typingAttributes: [NSAttributedString.Key: Any]
    }

    private func capture(_ range: NSRange, in textView: NSTextView, storage: NSTextStorage) -> EditState {
        EditState(range: range,
                  content: NSAttributedString(attributedString: storage.attributedSubstring(from: range)),
                  selection: textView.selectedRanges, typingAttributes: textView.typingAttributes)
    }

    private func registerInverse(_ state: EditState, manager: UndoManager?) {
        manager?.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated { editor.restore(state) }
        }
    }

    private func restore(_ state: EditState) {
        guard let textView, let storage = textView.textStorage,
              state.range.location <= storage.length,
              state.range.length <= storage.length - state.range.location else { return }
        let inverse = capture(state.range, in: textView, storage: storage)
        let manager = textView.undoManager
        manager?.disableUndoRegistration()
        storage.beginEditing()
        storage.replaceCharacters(in: state.range, with: state.content)
        storage.endEditing()
        textView.selectedRanges = state.selection
        textView.typingAttributes = state.typingAttributes
        textView.didChangeText()
        manager?.enableUndoRegistration()
        registerInverse(inverse, manager: manager)
    }

    private static func marks(in attributes: [NSAttributedString.Key: Any]) -> SemanticInlineMarks {
        SemanticInlineMarks(rawValue: (attributes[marksKey] as? NSNumber)?.intValue ?? 0)
    }

    private static func render(_ marks: SemanticInlineMarks,
                               over attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        NativeSemanticAttributes.render(marks, over: attributes)
    }

    private static func actionName(_ mark: SemanticInlineMarks) -> String {
        switch mark {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .underline: return "Underline"
        case .highlight: return "Highlight"
        case .strikethrough: return "Strikethrough"
        default: return "Format"
        }
    }
}
