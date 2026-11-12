import AppKit

/// Projects a full semantic document directly into its visible native editing storage.
@MainActor
final class NativeSemanticDocumentStorage {
    weak var textView: NSTextView?
    var configuration: MarkdownEditorConfiguration
    var baseFont: NSFont
    var onChange: (() -> Void)?
    private var imported: SemanticMarkdownDocument?
    private var tables: [UUID: NativeSemanticTableSession] = [:]
    private var sourceBlocks: [UUID: NativeSemanticSourceBlockSession] = [:]
    private let emptyBlockID = UUID()
    private struct MetadataAnchor {
        let block: SemanticMarkdownBlock
        let preceding: UUID?
        let following: UUID?
        let trailing: Bool
    }
    private var metadata: [MetadataAnchor] = []

    init(textView: NSTextView, configuration: MarkdownEditorConfiguration) {
        self.textView = textView
        self.configuration = configuration
        baseFont = textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
    }

    var hasActiveComposition: Bool { tables.values.contains { $0.hasActiveComposition } || sourceBlocks.values.contains { $0.protectedInput } }
    var onInputSettled: (() -> Void)?

    func tableSession(for blockID: UUID) -> NativeSemanticTableSession? { tables[blockID] }

    /// Initial import or a caller-owned attributed document transaction, never a source restyle.
    func load(_ document: SemanticMarkdownDocument, selectedRange: NSRange? = nil) {
        guard let textView, let storage = textView.textStorage else { return }
        imported = document
        metadata = document.blocks.enumerated().compactMap { index, block in
            guard case .metadata = block.content else { return nil }
            let preceding = document.blocks[..<index].last { if case .metadata = $0.content { return false }; return true }?.id
            let following = document.blocks.dropFirst(index + 1).first { if case .metadata = $0.content { return false }; return true }?.id
            return MetadataAnchor(block: block, preceding: preceding, following: following, trailing: following == nil)
        }
        let result = NSMutableAttributedString(string: "")
        for block in document.blocks {
            if case .metadata = block.content { continue }
            result.append(attributedBlock(block))
        }
        if storage.string.utf16.elementsEqual(result.string.utf16) {
            storage.beginEditing()
            result.enumerateAttributes(in: NSRange(location: 0, length: result.length)) { attributes, range, _ in
                storage.setAttributes(attributes, range: range)
            }
            storage.endEditing()
        } else { storage.setAttributedString(result) }
        let requested = selectedRange ?? NSRange(location: 0, length: 0)
        textView.setSelectedRange(NSRange(location: min(max(0, requested.location), storage.length),
                                          length: min(max(0, requested.length), max(0, storage.length - min(max(0, requested.location), storage.length)))))
        textView.typingAttributes = storage.length > 0
            ? storage.attributes(at: min(textView.selectedRange().location, storage.length - 1), effectiveRange: nil)
            : [.font: baseFont, NativeSemanticAttributes.blockID: emptyBlockID,
               NativeSemanticAttributes.paragraphRole: NativeSemanticParagraphRole.body]
    }

    /// Native history may restore identical text with coalesced paragraph IDs.
    /// Reattach provenance only when the entire ordered semantic document agrees;
    /// repeated equal paragraphs are never matched by their text independently.
    func restoreImportedIdentityIfUnchanged() {
        guard let imported, let textView else { return }
        let current = snapshot()
        guard current.isSemanticallyEquivalent(to: imported),
              current.blocks.map(\.id) != imported.blocks.map(\.id) else { return }
        let typingAttributes = textView.typingAttributes
        load(imported, selectedRange: textView.selectedRange())
        textView.typingAttributes = typingAttributes
    }

    func snapshot() -> SemanticMarkdownDocument {
        guard let storage = textView?.textStorage else { return emptyDocument() }
        return snapshot(attributedText: storage)
    }

    /// A caller can overlay displaced committed IME content on an immutable native copy.
    func snapshot(attributedText storage: NSAttributedString) -> SemanticMarkdownDocument {
        guard let imported else { return emptyDocument() }
        var blocks: [SemanticMarkdownBlock] = []
        let origins = Dictionary(uniqueKeysWithValues: imported.blocks.map { ($0.id, $0.origin) })
        storage.enumerateAttribute(NativeSemanticAttributes.blockID, in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in
            let id = (value as? UUID) ?? emptyBlockID
            let attributes = storage.attributes(at: range.location, effectiveRange: nil)
            let role = attributes[NativeSemanticAttributes.paragraphRole] as? NativeSemanticParagraphRole ?? .body
            let declaredEnding = attributes[NativeSemanticAttributes.blockLineEnding] as? String ?? ""
            let whole = (storage.string as NSString).substring(with: range)
            let ending = !declaredEnding.isEmpty && whole.hasSuffix(declaredEnding) ? declaredEnding : ""
            let bodyRange = NSRange(location: range.location, length: range.length - ending.utf16.count)
            let body = storage.attributedSubstring(from: bodyRange)
            let content: SemanticMarkdownBlock.Content
            switch role {
            case .body: content = .paragraph(NativeSemanticAttributes.inlineText(body))
            case .heading(let level): content = .heading(level: level, text: NativeSemanticAttributes.inlineText(body))
            case .code(let language, let closed): content = .code(language: language, body: body.string, isClosed: closed)
            case .blank: content = .blank(body.string)
            case .listItem: content = .list(listItems(in: body))
            case .quote: content = .quote(quoteLines(in: body))
            case .object:
                if let session = attributes[NativeSemanticSourceBlockSession.attribute] as? NativeSemanticSourceBlockSession {
                    content = session.content()
                } else if let session = attributes[NativeSemanticAttributes.tableSession] as? NativeSemanticTableSession {
                    content = .table(session.snapshot())
                } else if let payload = attributes[NativeSemanticAttributes.blockPayload] as? SemanticMarkdownBlock.Content {
                    content = payload
                } else { content = .paragraph(NativeSemanticAttributes.inlineText(body)) }
            }
            blocks.append(SemanticMarkdownBlock(id: id, content: content, origin: origins[id] ?? nil, lineEnding: ending, alignment: attributes[NSAttributedString.Key("MarkdownEngine.semanticAlignment")] as? MarkdownTextAlignment))
        }
        for anchor in metadata {
            let index: Int
            if anchor.trailing { index = blocks.count }
            else if let next = anchor.following, let position = blocks.firstIndex(where: { $0.id == next }) { index = position }
            else if let previous = anchor.preceding, let position = blocks.lastIndex(where: { $0.id == previous }) { index = position + 1 }
            else { index = blocks.count }
            blocks.insert(anchor.block, at: index)
        }
        return SemanticMarkdownDocument(blocks: blocks, sourceOrigin: imported.sourceOrigin, sourceMap: imported.sourceMap)
    }

    private func emptyDocument() -> SemanticMarkdownDocument {
            return SemanticMarkdownDocument(blocks: [], sourceOrigin: "", sourceMap: SemanticSourceMap(
                segments: [], sourceUTF16Count: 0, visibleUTF16Count: 0, sourceText: "", visibleText: ""))
    }

    private func attributedBlock(_ block: SemanticMarkdownBlock) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        func append(_ inline: SemanticInlineText, role: NativeSemanticParagraphRole, ending: String = "", font: NSFont? = nil) {
            let text = NSMutableAttributedString(attributedString: NativeSemanticAttributes.attributedText(inline, font: font ?? baseFont))
            text.addAttribute(.foregroundColor, value: configuration.theme.bodyText, range: NSRange(location: 0, length: text.length))
            text.enumerateAttribute(NativeSemanticAttributes.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                if value != nil { text.addAttribute(.foregroundColor, value: configuration.theme.link, range: range) }
            }
            NativeSemanticAttributes.renderObjects(in: text, configuration: configuration, font: font ?? baseFont,
                                                    maxWidth: max(120, textView?.textContainer?.size.width ?? 600))
            text.append(NSAttributedString(string: ending, attributes: [.font: font ?? baseFont]))
            text.addAttribute(NativeSemanticAttributes.paragraphRole, value: role, range: NSRange(location: 0, length: text.length))
            text.addAttribute(.paragraphStyle, value: NativeSemanticAttributes.paragraphStyle(for: role, font: font ?? baseFont),
                              range: NSRange(location: 0, length: text.length))
            result.append(text)
        }
        switch block.content {
        case .paragraph(let text): append(text, role: .body)
        case .heading(let level, let text):
            let size = baseFont.pointSize * configuration.headings.fontMultiplier(for: level)
            append(text, role: .heading(level: level), font: .boldSystemFont(ofSize: size))
        case .list(let items):
            for item in items { append(item.text, role: .listItem(orderedStart: item.orderedStart, indent: item.indent, checked: item.checked), ending: item.lineEnding) }
        case .quote(let lines):
            for line in lines { append(line.text, role: .quote(depth: line.depth), ending: line.lineEnding) }
        case .blank(let whitespace): append(SemanticInlineText(text: whitespace), role: .blank)
        case .metadata: break
        default:
            var attributes: [NSAttributedString.Key: Any] = [
                NativeSemanticAttributes.paragraphRole: NativeSemanticParagraphRole.object,
                NativeSemanticAttributes.blockPayload: block.content,
                .attachment: blockAttachment(block.content)
            ]
            switch block.content {
            case .math, .code:
                var isolated = SemanticMarkdownDocument(blocks: [block], sourceOrigin: imported?.sourceOrigin ?? "", sourceMap: emptyDocument().sourceMap)
                isolated.blocks[0].lineEnding = ""
                let source = (try? SemanticMarkdownImport.export(isolated).source) ?? ""
                let session = sourceBlocks[block.id] ?? NativeSemanticSourceBlockSession(id: block.id, source: source,
                    configuration: configuration, font: baseFont, undoManager: textView?.undoManager)
                session.adopt(source: source)
                session.updateConfiguration(configuration, font: baseFont)
                session.onChange = { [weak self, weak session] in session?.scheduleMeasure(); self?.onChange?() }
                session.onInputSettled = { [weak self] in self?.onInputSettled?() }
                session.onResize = { [weak self] height in self?.resizeSourceBlock(block.id, height: height) }
                sourceBlocks[block.id] = session
                let attachment = NSTextAttachment()
                attachment.bounds = NSRect(x: 0, y: 0, width: max(120, textView?.textContainer?.size.width ?? 600), height: session.height)
                attributes[.attachment] = attachment
                attributes[NativeSemanticSourceBlockSession.attribute] = session
            default: break
            }
            if case .table(let table) = block.content {
                let session = tables[block.id] ?? NativeSemanticTableSession(
                    table: table, undoManager: textView?.undoManager, configuration: configuration)
                session.onInputSettled = { [weak self] in self?.onInputSettled?() }
                session.configuration = configuration
                session.adopt(table)
                session.onChange = { [weak self] in
                    self?.refreshTableAttachment(block.id)
                    self?.onChange?()
                }
                tables[block.id] = session
                attributes[NativeSemanticAttributes.tableSession] = session
            }
            result.append(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
        }
        if !block.lineEnding.isEmpty {
            let role = result.length > 0 ? result.attribute(NativeSemanticAttributes.paragraphRole, at: result.length - 1, effectiveRange: nil) : NativeSemanticParagraphRole.body
            result.append(NSAttributedString(string: block.lineEnding, attributes: [
                .font: baseFont, NativeSemanticAttributes.paragraphRole: role ?? NativeSemanticParagraphRole.body]))
        }
        if let alignment = block.alignment {
            let style = NSMutableParagraphStyle()
            style.alignment = alignment.nsTextAlignment
            result.addAttributes([.paragraphStyle: style,
                                  NSAttributedString.Key("MarkdownEngine.semanticAlignment"): alignment],
                                 range: NSRange(location: 0, length: result.length))
        }
        result.addAttributes([NativeSemanticAttributes.blockID: block.id,
                              NativeSemanticAttributes.blockLineEnding: block.lineEnding], range: NSRange(location: 0, length: result.length))
        return result
    }

    func detachSourceBlocks() {
        sourceBlocks.values.forEach { $0.detach() }
    }

    private func resizeSourceBlock(_ id: UUID, height: CGFloat) {
        guard let storage = textView?.textStorage else { return }
        storage.enumerateAttribute(NativeSemanticAttributes.blockID, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value as? UUID == id, let attachment = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment else { return }
            attachment.bounds.size.height = height
            storage.edited(.editedAttributes, range: NSRange(location: range.location, length: 1), changeInLength: 0)
        }
    }

    private func lines(in body: NSAttributedString) -> [(NSAttributedString, String, [NSAttributedString.Key: Any])] {
        var result: [(NSAttributedString, String, [NSAttributedString.Key: Any])] = []
        let text = body.string as NSString
        var offset = 0
        while offset < text.length {
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: offset, length: 0))
            result.append((body.attributedSubstring(from: NSRange(location: start, length: contentsEnd - start)),
                           text.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd)),
                           body.attributes(at: start, effectiveRange: nil)))
            offset = end
        }
        return result
    }

    private func listItems(in body: NSAttributedString) -> [SemanticMarkdownListItem] {
        lines(in: body).map { text, ending, attributes in
            let role = attributes[NativeSemanticAttributes.paragraphRole] as? NativeSemanticParagraphRole
            if let role, case .listItem(let ordered, let indent, let checked) = role {
                return SemanticMarkdownListItem(orderedStart: ordered, indent: indent, checked: checked,
                                                text: NativeSemanticAttributes.inlineText(text), lineEnding: ending)
            }
            return SemanticMarkdownListItem(orderedStart: nil, indent: 0, checked: nil,
                                            text: NativeSemanticAttributes.inlineText(text), lineEnding: ending)
        }
    }

    private func quoteLines(in body: NSAttributedString) -> [SemanticMarkdownQuoteLine] {
        lines(in: body).map { text, ending, attributes in
            let role = attributes[NativeSemanticAttributes.paragraphRole] as? NativeSemanticParagraphRole
            let depth: Int
            if let role, case .quote(let value) = role { depth = value } else { depth = 1 }
            return SemanticMarkdownQuoteLine(depth: depth, text: NativeSemanticAttributes.inlineText(text), lineEnding: ending)
        }
    }
}
