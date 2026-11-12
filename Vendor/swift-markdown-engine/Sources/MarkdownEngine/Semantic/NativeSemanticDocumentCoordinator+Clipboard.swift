import AppKit

extension NativeSemanticDocumentCoordinator {
    func copySelection(to pasteboard: NSPasteboard, asMarkdown: Bool = false) -> Bool {
        if let block = activeSourceBlockSession {
            let source = block.committedSource() as NSString
            let selection = block.textView.selectedRange()
            guard selection.length > 0, NSMaxRange(selection) <= source.length else { return false }
            pasteboard.clearContents()
            return pasteboard.setString(source.substring(with: selection), forType: .string)
        }
        if let session = activeTableSession { return session.copySelection(to: pasteboard, asMarkdown: asMarkdown) }
        guard let storage = textView.textStorage else { return false }
        let selection = textView.selectedRange()
        guard selection.length > 0, NSMaxRange(selection) <= storage.length else { return false }
        let selected = storage.attributedSubstring(from: selection)
        do {
            let plain: String
            if asMarkdown, selected.containsAttachments(in: NSRange(location: 0, length: selected.length)) {
                var document = documentStorage.snapshot(attributedText: selected)
                document.blocks.removeAll { if case .metadata = $0.content { return true }; return false }
                plain = try SemanticMarkdownImport.export(document).source
            } else if asMarkdown { plain = try SemanticInlineCodec.encode(NativeSemanticAttributes.inlineText(selected)) }
            else { plain = renderedPlainText(selected) }
            pasteboard.clearContents()
            pasteboard.setString(plain, forType: .string)
            if !asMarkdown, let rich = try? selected.data(from: NSRange(location: 0, length: selected.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                pasteboard.setData(rich, forType: .rtf)
            }
            return true
        } catch { onExportFailure?(error); return false }
    }

    private func renderedPlainText(_ selected: NSAttributedString) -> String {
        let result = NSMutableString(string: selected.string)
        var replacements: [(NSRange, String)] = []
        selected.enumerateAttributes(in: NSRange(location: 0, length: selected.length)) { attributes, range, _ in
            let text: String?
            if let session = attributes[NativeSemanticAttributes.tableSession] as? NativeSemanticTableSession {
                text = session.snapshot().rows.map { $0.map(\.text).joined(separator: "\t") }.joined(separator: "\n")
            } else if let object = attributes[NativeSemanticAttributes.object] as? SemanticInlineObject {
                switch object {
                case .image(_, let alt, _): text = alt
                case .math(let source), .embed(let source), .opaque(let source): text = source
                }
            } else if let block = (attributes[NativeSemanticSourceBlockSession.attribute] as? NativeSemanticSourceBlockSession)?.content()
                        ?? attributes[NativeSemanticAttributes.blockPayload] as? SemanticMarkdownBlock.Content {
                switch block {
                case .math(let source), .opaque(let source): text = source
                case .code(_, let body, _): text = body
                case .separator: text = "—"
                default: text = nil
                }
            } else { text = nil }
            if let text {
                let part = (selected.string as NSString).substring(with: range)
                replacements.append((range, part.replacingOccurrences(of: "\u{FFFC}", with: text)))
            }
        }
        for (range, text) in replacements.reversed() { result.replaceCharacters(in: range, with: text) }
        return result as String
    }

    func paste(from pasteboard: NSPasteboard, asMarkdown: Bool = false) -> Bool {
        guard textView.isEditable, !hasActiveComposition else { return false }
        if let source = onPasteImage?(pasteboard), !source.isEmpty { return pasteText(source, asMarkdown: true) }
        guard let plain = pasteboard.string(forType: .string) else { return false }
        return pasteText(plain, asMarkdown: asMarkdown)
    }

    func pasteText(_ plain: String, asMarkdown: Bool = false) -> Bool {
        let plain = plain.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if let block = activeSourceBlockSession {
            guard textView.isEditable, block.textView.isEditable, !block.protectedInput else { return false }
            block.textView.insertText(plain, replacementRange: block.textView.selectedRange())
            return true
        }
        if let session = activeTableSession { return session.pasteText(plain, asMarkdown: asMarkdown) }
        guard textView.isEditable, !hasActiveComposition else { return false }
        do {
            let replacement: NSMutableAttributedString
            if asMarkdown {
                if let result = try pasteMarkdownDocument(plain) { return result }
                let decoded = try SemanticInlineCodec.decode(plain)
                replacement = NSMutableAttributedString(attributedString: NativeSemanticAttributes.attributedText(decoded,
                    font: textView.font ?? .systemFont(ofSize: 14)))
                NativeSemanticAttributes.renderObjects(in: replacement, configuration: configuration,
                    font: textView.font ?? .systemFont(ofSize: 16), maxWidth: textView.textContainer?.size.width ?? 600)
                let full = NSRange(location: 0, length: replacement.length)
                for key in [NativeSemanticAttributes.blockID, NativeSemanticAttributes.paragraphRole, NativeSemanticAttributes.blockLineEnding] {
                    if let value = textView.typingAttributes[key] { replacement.addAttribute(key, value: value, range: full) }
                }
            } else { replacement = NSMutableAttributedString(string: plain, attributes: safeTypingAttributes()) }
            return replaceVisible(textView.selectedRange(), with: replacement, actionName: "Paste")
        } catch { onExportFailure?(error); return false }
    }

    func safeTypingAttributes() -> [NSAttributedString.Key: Any] {
        var attributes = textView.typingAttributes
        for key in [NSAttributedString.Key.attachment, NativeSemanticAttributes.blockPayload,
                    NativeSemanticAttributes.tableSession, NativeSemanticSourceBlockSession.attribute, NativeSemanticAttributes.object, NativeSemanticAttributes.objectID] {
            attributes.removeValue(forKey: key)
        }
        if let role = attributes[NativeSemanticAttributes.paragraphRole] as? NativeSemanticParagraphRole {
            switch role {
            case .blank, .object:
                attributes[NativeSemanticAttributes.paragraphRole] = NativeSemanticParagraphRole.body
                attributes[NativeSemanticAttributes.blockID] = UUID()
                attributes[NativeSemanticAttributes.blockLineEnding] = ""
            default: break
            }
        }
        return attributes
    }

    func replaceVisibleRanges(ranges: [NSRange], with replacement: String,
                              expectedText: String, actionName: String) -> NSRange? {
        guard textView.string.utf16.elementsEqual(expectedText.utf16), !ranges.isEmpty,
              let storage = textView.textStorage else { return nil }
        let sorted = ranges.sorted { $0.location < $1.location }
        var end = 0
        for range in sorted {
            guard range.location >= end, (try? SemanticInlineText.validatedBounds(range, in: storage.string)) != nil else { return nil }
            end = NSMaxRange(range)
        }
        let result = NSMutableAttributedString(attributedString: storage)
        for range in sorted.reversed() {
            let attrs = range.location < result.length ? result.attributes(at: range.location, effectiveRange: nil) : safeTypingAttributes()
            result.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: attrs))
        }
        let selected = NSRange(location: sorted[0].location, length: replacement.utf16.count)
        return replaceVisible(NSRange(location: 0, length: storage.length), with: result,
                              actionName: actionName, selection: selected) ? selected : nil
    }
}
