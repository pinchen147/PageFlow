import AppKit

/// Semantic values travel with native attributed content; visual attributes remain derived.
@MainActor
enum NativeSemanticAttributes {
    static let marks = NSAttributedString.Key("MarkdownEngine.semanticInlineMarks")
    static let baseFont = NSAttributedString.Key("MarkdownEngine.semanticInlineBaseFont")
    static let code = NSAttributedString.Key("MarkdownEngine.semanticInlineCode")
    static let link = NSAttributedString.Key("MarkdownEngine.semanticInlineLink")
    static let object = NSAttributedString.Key("MarkdownEngine.semanticInlineObject")
    /// Native session identity is independent of the object's portable descriptor.
    static let objectID = NSAttributedString.Key("MarkdownEngine.semanticInlineObjectID")
    static let blockID = NSAttributedString.Key("MarkdownEngine.semanticBlockID")
    static let paragraphRole = NSAttributedString.Key("MarkdownEngine.semanticParagraphRole")
    static let blockPayload = NSAttributedString.Key("MarkdownEngine.semanticBlockPayload")
    static let blockLineEnding = NSAttributedString.Key("MarkdownEngine.semanticBlockLineEnding")
    static let tableSession = NSAttributedString.Key("MarkdownEngine.semanticTableSession")

    static func attributedText(_ text: SemanticInlineText, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for run in text.runs {
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            switch run.payload {
            case .text: break
            case .code:
                attributes[code] = true
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
            case .object(let descriptor):
                attributes[object] = descriptor
                attributes[objectID] = UUID()
                attributes[.attachment] = NSTextAttachment()
            }
            if let descriptor = run.link {
                attributes[link] = descriptor
                switch descriptor {
                case .url(let destination, _):
                    if let url = URL(string: destination),
                       ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { attributes[.link] = url }
                case .wiki(let target): attributes[.wikiLinkID] = target
                }
            }
            result.append(NSAttributedString(string: run.text, attributes: render(run.marks, over: attributes)))
        }
        return NSAttributedString(attributedString: result)
    }

    static func inlineText(_ storage: NSAttributedString) -> SemanticInlineText {
        var runs: [SemanticInlineRun] = []
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
            let value = (storage.string as NSString).substring(with: range)
            let selectedMarks = marks(in: attributes)
            let target = attributes[link] as? SemanticInlineLink
            func appendText(_ text: String) {
                guard !text.isEmpty else { return }
                runs.append(SemanticInlineRun(payload: attributes[code] as? Bool == true ? .code(text) : .text(text),
                                              marks: selectedMarks, link: target))
            }
            if let descriptor = attributes[object] as? SemanticInlineObject, attributes[.attachment] is NSTextAttachment {
                for (index, part) in value.components(separatedBy: "\u{FFFC}").enumerated() {
                    if index > 0 { runs.append(SemanticInlineRun(object: descriptor, marks: selectedMarks, link: target)) }
                    appendText(part)
                }
            } else { appendText(value) }
        }
        return SemanticInlineText(runs: runs)
    }

    static func renderObjects(in text: NSMutableAttributedString, configuration: MarkdownEditorConfiguration,
                              font: NSFont, maxWidth: CGFloat) {
        text.enumerateAttribute(object, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let descriptor = value as? SemanticInlineObject else { return }
            var rendered: NSImage?
            var requestedWidth: CGFloat?
            let label: String
            switch descriptor {
            case .math(let source):
                rendered = configuration.services.latex.render(latex: source, fontSize: font.pointSize, theme: configuration.theme)?.image
                label = "Math"
            case .image(let source, let alt, _):
                rendered = configuration.services.images.image(for: EmbeddedImageRequest(name: source))
                let tokens = ImageAltTokens.parse(alt)
                requestedWidth = tokens.width
                if let original = rendered, let crop = tokens.crop {
                    let size = tokens.croppedSize(of: original.size)
                    rendered = NSImage(size: size, flipped: false) { rect in
                        MarkdownTextLayoutFragment.drawBlockImage(original, in: rect, crop: crop, cornerRadius: 0)
                        return true
                    }
                }
                let paragraph = NSMutableParagraphStyle()
                switch tokens.alignment {
                case .left: paragraph.alignment = .left
                case .center: paragraph.alignment = .center
                case .right: paragraph.alignment = .right
                }
                text.addAttribute(.paragraphStyle, value: paragraph, range: range)
                label = tokens.displayDescription.isEmpty ? "Image" : "Image: " + tokens.displayDescription
            case .embed(let source):
                let reference = ImageEmbedReference(content: source)
                rendered = configuration.services.images.image(for: reference?.providerRequest ?? EmbeddedImageRequest(name: source))
                requestedWidth = reference?.requestedWidth
                if let original = rendered, let crop = reference?.crop {
                    let size = CGSize(width: original.size.width * crop.width, height: original.size.height * crop.height)
                    rendered = NSImage(size: size, flipped: false) { rect in
                        MarkdownTextLayoutFragment.drawBlockImage(original, in: rect, crop: crop, cornerRadius: 0)
                        return true
                    }
                }
                let paragraph = NSMutableParagraphStyle()
                switch reference?.alignment ?? .left {
                case .left: paragraph.alignment = .left
                case .center: paragraph.alignment = .center
                case .right: paragraph.alignment = .right
                }
                text.addAttribute(.paragraphStyle, value: paragraph, range: range)
                label = "Embed"
            case .opaque: rendered = nil; label = "Unsupported content"
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: configuration.theme.bodyText]
            let image = rendered ?? NSImage(size: NSSize(width: max(48, min(400, (label as NSString).size(withAttributes: attributes).width + 16)),
                                                         height: max(24, font.pointSize + 12)), flipped: false) { rect in
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
                (label as NSString).draw(at: NSPoint(x: 8, y: 5), withAttributes: attributes)
                return true
            }
            let attachment = NSTextAttachment()
            attachment.image = image
            let targetWidth = min(maxWidth, requestedWidth ?? image.size.width)
            let factor = max(0.01, targetWidth / max(1, image.size.width))
            attachment.bounds = NSRect(origin: .zero, size: NSSize(width: max(1, image.size.width * factor),
                                                                    height: max(1, image.size.height * factor)))
            text.addAttribute(.attachment, value: attachment, range: range)
        }
    }

    static func marks(in attributes: [NSAttributedString.Key: Any]) -> SemanticInlineMarks {
        SemanticInlineMarks(rawValue: (attributes[marks] as? NSNumber)?.intValue ?? 0)
    }

    static func render(_ selected: SemanticInlineMarks,
                       over attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var result = attributes
        result[marks] = NSNumber(value: selected.rawValue)
        let previous = marks(in: attributes)
        if !selected.intersection([.bold, .italic]).isEmpty || !previous.intersection([.bold, .italic]).isEmpty {
            let base = (attributes[baseFont] as? NSFont) ?? (attributes[.font] as? NSFont) ?? .systemFont(ofSize: NSFont.systemFontSize)
            var font = base
            if selected.contains(.bold) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if selected.contains(.italic) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            result[.font] = font
            result[baseFont] = selected.intersection([.bold, .italic]).isEmpty ? nil : base
        }
        if selected.contains(.underline) { result[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        else if previous.contains(.underline) { result[.underlineStyle] = nil }
        if selected.contains(.strikethrough) { result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        else if previous.contains(.strikethrough) { result[.strikethroughStyle] = nil }
        if selected.contains(.highlight) { result[.backgroundColor] = NSColor.systemYellow }
        else if previous.contains(.highlight) { result[.backgroundColor] = nil }
        return result
    }
}

enum NativeSemanticParagraphRole: Hashable {
    case body
    case heading(level: Int)
    case listItem(orderedStart: Int?, indent: Int, checked: Bool?)
    case quote(depth: Int)
    case code(language: String?, closed: Bool)
    case blank
    case object
}
