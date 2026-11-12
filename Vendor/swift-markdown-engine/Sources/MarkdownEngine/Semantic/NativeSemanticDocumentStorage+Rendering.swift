import AppKit

extension NativeSemanticDocumentStorage {
    func blockAttachment(_ content: SemanticMarkdownBlock.Content) -> NSTextAttachment {
        let image: NSImage
        switch content {
        case .math(let latex):
            image = configuration.services.latex.render(latex: latex, fontSize: baseFont.pointSize,
                                                          theme: configuration.theme)?.image ?? fallbackImage("Math")
        case .code(let language, let source, _):
            image = configuration.services.diagram.render(source: source, language: language ?? "",
                maxWidth: availableWidth, fontSize: baseFont.pointSize, theme: configuration.theme)?.image
                ?? fallbackImage("Diagram: " + (language ?? "Code"))
        case .table(let table): image = tableImage(table)
        case .separator: image = fallbackImage("—")
        case .opaque: image = fallbackImage("Unsupported content")
        default: image = fallbackImage("Content")
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(origin: .zero, size: { if case .table = content { return tableAttachmentSize(image.size) }; return fitted(image.size) }())
        return attachment
    }

    /// The existing table renderer receives a derived transport value, never an editing buffer.
    private func tableImage(_ table: SemanticMarkdownTable) -> NSImage {
        func source(_ text: SemanticInlineText) -> String {
            if let encoded = try? SemanticInlineCodec.encode(text) { return encoded }
            return text.runs.map { run in
                if case .object = run.payload { return "[Content]" }
                return run.text.replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_")
            }.joined()
        }
        let values = table.rows.map { $0.map(source) }
        guard let header = values.first else { return fallbackImage("Table") }
        let alignments: [MarkdownStyler.TableAlignment] = table.alignments.map {
            switch $0 { case .left: return .left; case .center: return .center; case .right: return .right }
        }
        let parsed = MarkdownStyler.ParsedTable(header: header, alignments: alignments, rows: Array(values.dropFirst()))
        let layout = MarkdownTableLayout(table: parsed, font: baseFont, theme: configuration.theme,
            codeBackground: configuration.services.syntaxHighlighter.backgroundColor(), latex: configuration.services.latex,
            appearance: textView?.effectiveAppearance ?? NSAppearance(named: .aqua)!)
        return layout.image()
    }

    func refreshTableAttachment(_ blockID: UUID) {
        guard let storage = textView?.textStorage else { return }
        storage.enumerateAttribute(NativeSemanticAttributes.blockID, in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in
            guard value as? UUID == blockID,
                  let session = storage.attribute(NativeSemanticAttributes.tableSession, at: range.location, effectiveRange: nil) as? NativeSemanticTableSession,
                  let attachment = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment else { return }
            let image = session.geometry().image()
            attachment.image = image
            attachment.bounds = NSRect(origin: .zero, size: tableAttachmentSize(image.size))
            storage.edited(.editedAttributes, range: NSRange(location: range.location, length: 1), changeInLength: 0)
        }
    }

    private func tableAttachmentSize(_ size: NSSize) -> NSSize {
        NSSize(width: min(size.width, availableWidth), height: size.height + (size.width > availableWidth ? 14 : 0))
    }

    private var availableWidth: CGFloat { max(120, textView?.textContainer?.size.width ?? 600) }

    private func fitted(_ size: NSSize) -> NSSize {
        guard size.width > availableWidth else { return size }
        let factor = availableWidth / max(1, size.width)
        return NSSize(width: availableWidth, height: max(1, size.height * factor))
    }

    private func fallbackImage(_ label: String) -> NSImage {
        let font = NSFont.systemFont(ofSize: baseFont.pointSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: configuration.theme.bodyText]
        let measured = (label as NSString).size(withAttributes: attributes)
        let size = NSSize(width: max(48, min(400, measured.width + 16)), height: max(24, measured.height + 10))
        return NSImage(size: size, flipped: false) { rect in
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            (label as NSString).draw(at: NSPoint(x: 8, y: 5), withAttributes: attributes)
            return true
        }
    }
}
