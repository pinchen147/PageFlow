import AppKit

extension NativeSemanticDocumentStorage {
    func applyCodePresentation(to text: NSMutableAttributedString, range: NSRange, language: String?, live: Bool = false) {
        guard range.location >= 0, NSMaxRange(range) <= text.length else { return }
        let highlighter = configuration.services.syntaxHighlighter
        text.addAttributes([.font: highlighter.codeFont(size: baseFont.pointSize),
                            .foregroundColor: configuration.theme.bodyText,
                            .backgroundColor: highlighter.backgroundColor()], range: range)
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = configuration.codeBlock.horizontalIndent
        paragraph.headIndent = configuration.codeBlock.horizontalIndent
        paragraph.tailIndent = -configuration.codeBlock.horizontalIndent
        text.addAttribute(.paragraphStyle, value: paragraph, range: range)
        guard !live || range.length <= 16_384 else { return }
        let source = (text.string as NSString).substring(with: range)
        guard let highlighted = highlighter.highlight(code: source, language: language),
              highlighted.string.utf16.elementsEqual(source.utf16) else { return }
        highlighted.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: highlighted.length)) { value, local, _ in
            if let value { text.addAttribute(.foregroundColor, value: value,
                range: NSRange(location: range.location + local.location, length: local.length)) }
        }
    }
}

extension NativeSemanticDocumentCoordinator {
    func refreshCurrentCodeHighlighting() {
        guard let storage = textView.textStorage, storage.length > 0, !hasActiveComposition else { return }
        let location = min(textView.selectedRange().location, storage.length - 1)
        guard case .code(let language, _)? = storage.attribute(NativeSemanticAttributes.paragraphRole, at: location, effectiveRange: nil) as? NativeSemanticParagraphRole else { return }
        var range = NSRange()
        _ = storage.attribute(NativeSemanticAttributes.blockID, at: location,
                              longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length))
        storage.beginEditing()
        documentStorage.applyCodePresentation(to: storage, range: range, language: language, live: true)
        storage.endEditing()
    }
}
