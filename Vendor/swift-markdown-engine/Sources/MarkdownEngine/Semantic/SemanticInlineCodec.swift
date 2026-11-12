import Foundation

enum SemanticInlineCodec {
    enum HTMLPolicy { case rejectUnsupported, preserveOpaque }
    enum Failure: Error, Equatable {
        case unsupportedNode(String)
        case unsupportedHTML(String)
        case malformedHTML
        case unsupportedMarks
        case roundTripMismatch
    }

    static func decode(_ source: String, htmlPolicy: HTMLPolicy = .rejectUnsupported) throws -> SemanticInlineText {
        try decodeWithSourceMap(source, htmlPolicy: htmlPolicy).text
    }

    static func decodeWithSourceMap(_ source: String, htmlPolicy: HTMLPolicy = .rejectUnsupported,
                                    allowsEmphasisAcrossLineBreaks: Bool = false) throws -> (text: SemanticInlineText, map: SemanticSourceMap) {
        let html = try SemanticInlineCodecHTML.prepare(source, htmlPolicy: htmlPolicy)
        let ns = html.source as NSString
        let original = source as NSString
        var runs: [SemanticInlineRun] = []
        var segments: [SemanticSourceMap.Segment] = []
        var visible = 0
        var tags: [SemanticInlineCodecHTML.Tag] = []
        var depths: [String: Int] = [:]
        var active: SemanticInlineMarks = []

        func emit(_ run: SemanticInlineRun, source range: NSRange, kind: SemanticSourceMap.Kind) {
            guard !run.text.isEmpty else { return }
            runs.append(run)
            segments.append(.init(source: range, visible: NSRange(location: visible, length: run.text.utf16.count), kind: kind))
            visible += run.text.utf16.count
        }

        func literal(_ range: NSRange, marks: SemanticInlineMarks, link: SemanticInlineLink?,
                     code: Bool = false, entities: Bool = true, originalRange: Bool = false) {
            let text = originalRange ? original : ns
            func origin(_ r: NSRange) -> NSRange { originalRange ? r : html.originalRange(r) }
            func append(_ r: NSRange, value: String? = nil, kind: SemanticSourceMap.Kind = .literal) {
                guard r.length > 0 else { return }
                let value = value ?? text.substring(with: r)
                emit(.init(payload: code ? .code(value) : .text(value), marks: marks, link: link), source: origin(r), kind: kind)
            }
            guard entities else { append(range); return }
            var cursor = range.location
            var copied = cursor
            while cursor < NSMaxRange(range) {
                guard text.character(at: cursor) == 38 else { cursor += 1; continue }
                let end = text.range(of: ";", options: [], range: NSRange(
                    location: cursor + 1, length: min(32, NSMaxRange(range) - cursor - 1)))
                guard end.location != NSNotFound,
                      let value = SemanticInlineCodecHTML.entity(text.substring(with: NSRange(
                        location: cursor + 1, length: end.location - cursor - 1))) else { cursor += 1; continue }
                append(NSRange(location: copied, length: cursor - copied))
                append(NSRange(location: cursor, length: end.location + 1 - cursor), value: value, kind: .entity)
                cursor = end.location + 1
                copied = cursor
            }
            append(NSRange(location: copied, length: NSMaxRange(range) - copied))
        }

        func visit(_ nodes: [InlineNode], marks: SemanticInlineMarks, link: SemanticInlineLink? = nil) throws {
            for node in nodes {
                switch node {
                case .text(let range):
                    var start = range.location
                    for cursor in range.location..<NSMaxRange(range) {
                        guard html.tags[cursor] != nil || html.codes[cursor] != nil || html.opaque[cursor] != nil else { continue }
                        literal(NSRange(location: start, length: cursor - start), marks: marks.union(active), link: link)
                        if let opaque = html.opaque[cursor] {
                            emit(.init(object: .opaque(original.substring(with: opaque)), marks: marks.union(active), link: link),
                                 source: opaque, kind: .object)
                        } else if let code = html.codes[cursor] {
                            literal(code.body, marks: marks.union(active), link: link, code: true, originalRange: true)
                        } else if let tag = html.tags[cursor] {
                            if tag.isClosing {
                                guard tags.last?.name == tag.name else { throw Failure.malformedHTML }
                                tags.removeLast()
                                let depth = depths[tag.name, default: 0] - 1
                                depths[tag.name] = depth
                                if depth == 0 { active.subtract(tag.marks) }
                            } else {
                                tags.append(tag)
                                depths[tag.name, default: 0] += 1
                                active.formUnion(tag.marks)
                            }
                        }
                        start = cursor + 1
                    }
                    literal(NSRange(location: start, length: NSMaxRange(range) - start), marks: marks.union(active), link: link)
                case .escape(let range, let character, _):
                    emit(.init(text: ns.substring(with: character), marks: marks.union(active), link: link),
                         source: html.originalRange(range), kind: .escape)
                case .emphasis(let kind, _, _, let children):
                    let added: SemanticInlineMarks
                    switch kind {
                    case .bold: added = .bold
                    case .italic: added = .italic
                    case .boldItalic: added = [.bold, .italic]
                    }
                    try visit(children, marks: marks.union(added), link: link)
                case .strikethrough(_, _, let children): try visit(children, marks: marks.union(.strikethrough), link: link)
                case .highlight(_, _, let children): try visit(children, marks: marks.union(.highlight), link: link)
                case .underline(_, _, let children): try visit(children, marks: marks.union(.underline), link: link)
                case .code(_, let content):
                    literal(content, marks: marks.union(active), link: link, code: true, entities: false)
                case .link(let range, _, let url, _, let children):
                    let target = SemanticInlineLink.url(destination: decodedLiteral(ns.substring(with: url)),
                                                        title: title(in: ns, destination: url, full: range))
                    try visit(children, marks: marks, link: target)
                case .image(let range, let alt, let url, _):
                    emit(.init(object: .image(source: decodedLiteral(ns.substring(with: url)), alt: decodedLiteral(ns.substring(with: alt)),
                                              title: title(in: ns, destination: url, full: range)), marks: marks.union(active), link: link),
                         source: html.originalRange(range), kind: .object)
                case .wikiLink(_, let target, let alias, _):
                    let descriptor = SemanticInlineLink.wiki(target: decodedLiteral(ns.substring(with: target)))
                    literal(alias ?? target, marks: marks.union(active), link: descriptor)
                case .imageEmbed(let range, let target, _):
                    emit(.init(object: .embed(decodedLiteral(ns.substring(with: target))), marks: marks.union(active), link: link),
                         source: html.originalRange(range), kind: .object)
                case .inlineLatex(let range, let body, _):
                    emit(.init(object: .math(ns.substring(with: body)), marks: marks.union(active), link: link),
                         source: html.originalRange(range), kind: .object)
                }
            }
        }
        try visit(InlineParser.parse(html.source, allowsEmphasisAcrossLineBreaks: allowsEmphasisAcrossLineBreaks), marks: [])
        guard tags.isEmpty else { throw Failure.malformedHTML }
        let content = SemanticInlineText(runs: runs)
        var tiled: [SemanticSourceMap.Segment] = []
        var sourceCursor = 0
        var visibleCursor = 0
        for segment in segments.sorted(by: { $0.source.location < $1.source.location }) {
            if sourceCursor < segment.source.location {
                tiled.append(.init(source: NSRange(location: sourceCursor, length: segment.source.location - sourceCursor),
                                   visible: NSRange(location: visibleCursor, length: 0), kind: .delimiter))
            }
            tiled.append(segment)
            sourceCursor = NSMaxRange(segment.source)
            visibleCursor = NSMaxRange(segment.visible)
        }
        if sourceCursor < original.length {
            tiled.append(.init(source: NSRange(location: sourceCursor, length: original.length - sourceCursor),
                               visible: NSRange(location: visibleCursor, length: 0), kind: .delimiter))
        }
        return (content, SemanticSourceMap(segments: tiled, sourceUTF16Count: original.length, visibleUTF16Count: visible,
                                           sourceText: source, visibleText: content.text))
    }

    static func encode(_ content: SemanticInlineText) throws -> String {
        guard content.runs.allSatisfy({ $0.marks.subtracting(.all).isEmpty }) else { throw Failure.unsupportedMarks }
        let policy: HTMLPolicy = content.runs.contains {
            if case .object(.opaque) = $0.payload { return true }
            return false
        } ? .preserveOpaque : .rejectUnsupported
        let markdown = try serialized(content, html: false)
        if let reparsed = try? decode(markdown, htmlPolicy: policy), reparsed == content { return markdown }
        let fallback = try serialized(content, html: true)
        if let reparsed = try? decode(fallback, htmlPolicy: policy), reparsed == content { return fallback }
        // A literal inline value can contain paragraph separators that the inline
        // parser cannot keep inside marks. Preserve that value with entities only
        // after both physical-line representations have failed validation.
        let boundedMarkdown = markdown.replacingOccurrences(of: "\r", with: "&#13;")
            .replacingOccurrences(of: "\n", with: "&#10;")
        if let reparsed = try? decode(boundedMarkdown, htmlPolicy: policy), reparsed == content { return boundedMarkdown }
        let boundedFallback = fallback.replacingOccurrences(of: "\r", with: "&#13;")
            .replacingOccurrences(of: "\n", with: "&#10;")
        guard try decode(boundedFallback, htmlPolicy: policy) == content else { throw Failure.roundTripMismatch }
        return boundedFallback
    }
}
