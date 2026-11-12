import Foundation

/// A lexical importer for the codec's finite tag dialect; it never renders HTML.
enum SemanticInlineCodecHTML {
    struct Tag {
        let name: String
        let marks: SemanticInlineMarks
        let isClosing: Bool
    }

    struct Code {
        let opening: NSRange
        let body: NSRange
        let closing: NSRange
    }

    struct Prepared {
        let source: String
        let tags: [Int: Tag]
        let codes: [Int: Code]
        let opaque: [Int: NSRange]
        let origins: [NSRange]

        func originalRange(_ range: NSRange) -> NSRange {
            guard range.length > 0 else {
                return NSRange(location: range.location < origins.count ? origins[range.location].location :
                    origins.last.map(NSMaxRange) ?? 0, length: 0)
            }
            let start = origins[range.location].location
            return NSRange(location: start, length: NSMaxRange(origins[NSMaxRange(range) - 1]) - start)
        }
    }

    static let markTags: [(SemanticInlineMarks, String)] = [
        (.bold, "strong"), (.italic, "em"), (.underline, "u"),
        (.strikethrough, "s"), (.highlight, "mark")
    ]

    /// Opaque Markdown leaves and link destinations are never interpreted as HTML.
    static func prepare(_ source: String, htmlPolicy: SemanticInlineCodec.HTMLPolicy) throws -> Prepared {
        let ns = source as NSString
        if ns.range(of: "<").location == NSNotFound {
            return Prepared(source: source, tags: [:], codes: [:], opaque: [:],
                            origins: (0..<ns.length).map { NSRange(location: $0, length: 1) })
        }
        var protected: [NSRange] = []
        func collect(_ nodes: [InlineNode]) {
            for node in nodes {
                switch node {
                case .code(let r, _), .image(let r, _, _, _), .wikiLink(let r, _, _, _),
                     .imageEmbed(let r, _, _), .inlineLatex(let r, _, _), .escape(let r, _, _):
                    protected.append(r)
                case .link(let r, let label, _, _, let children):
                    protected.append(NSRange(location: NSMaxRange(label), length: NSMaxRange(r) - NSMaxRange(label)))
                    collect(children)
                case .emphasis(_, _, _, let children), .strikethrough(_, _, let children),
                     .highlight(_, _, let children), .underline(_, _, let children): collect(children)
                case .text: break
                }
            }
        }
        collect(InlineParser.parse(source))
        protected.sort { $0.location < $1.location }
        let lexical = SemanticInlineCodecHTMLLexer.Index(ns, protected: protected)
        var protectedIndex = 0
        var output = ""
        var origins: [NSRange] = []
        var tags: [Int: Tag] = [:]
        var codes: [Int: Code] = [:]
        var opaque: [Int: NSRange] = [:]
        var cursor = 0
        func copy(_ range: NSRange) {
            output += ns.substring(with: range)
            origins += (range.location..<NSMaxRange(range)).map { NSRange(location: $0, length: 1) }
        }
        while cursor < ns.length {
            while protectedIndex < protected.count, NSMaxRange(protected[protectedIndex]) <= cursor { protectedIndex += 1 }
            if protectedIndex < protected.count, NSLocationInRange(cursor, protected[protectedIndex]) {
                let end = NSMaxRange(protected[protectedIndex])
                copy(NSRange(location: cursor, length: end - cursor))
                cursor = end
                continue
            }
            if ns.character(at: cursor) == 60, !isEscaped(cursor, in: ns),
               let token = lexical.tokens[cursor] {
                let raw = ns.substring(with: NSRange(location: cursor + 1, length: token.range.length - 2))
                if raw.lowercased() == "code" {
                    let start = NSMaxRange(token.range)
                    let close = ns.range(of: "</code>", options: .caseInsensitive,
                                         range: NSRange(location: start, length: ns.length - start))
                    guard close.location != NSNotFound else { throw SemanticInlineCodec.Failure.malformedHTML }
                    codes[origins.count] = Code(opening: token.range,
                                               body: NSRange(location: start, length: close.location - start), closing: close)
                    output.append("\u{1}")
                    origins.append(NSRange(location: cursor, length: NSMaxRange(close) - cursor))
                    cursor = NSMaxRange(close)
                    continue
                }
                let name = (token.closing ? String(raw.dropFirst()) : raw).lowercased()
                if let (marks, _) = markTags.first(where: { $0.1 == name }) {
                    tags[origins.count] = Tag(name: name, marks: marks, isClosing: token.closing)
                    output.append("\u{1}")
                    origins.append(token.range)
                    cursor = NSMaxRange(token.range)
                } else {
                    guard htmlPolicy == .preserveOpaque else { throw SemanticInlineCodec.Failure.unsupportedHTML(raw) }
                    let range = lexical.elementRange(starting: token)
                    opaque[origins.count] = range
                    output.append("\u{1}")
                    origins.append(range)
                    cursor = NSMaxRange(range)
                }
            } else {
                let start = cursor
                cursor += 1
                while cursor < ns.length, ns.character(at: cursor) != 60,
                      !(protectedIndex < protected.count && protected[protectedIndex].location == cursor) { cursor += 1 }
                copy(NSRange(location: start, length: cursor - start))
            }
        }
        return Prepared(source: output, tags: tags, codes: codes, opaque: opaque, origins: origins)
    }

    static func escapeLiteral(_ text: String, preservesLineBreaks: Bool = false) -> String {
        text.unicodeScalars.map { scalar in
            switch scalar.value {
            case let value where preservesLineBreaks && (value == 10 || value == 13): return String(scalar)
            case 0...127: return "&#\(scalar.value);"
            default: return String(scalar)
            }
        }.joined()
    }

    static func decodeEntities(_ source: String) -> String {
        let ns = source as NSString
        var output = ""
        var cursor = 0
        var copiedThrough = 0
        while cursor < ns.length {
            guard ns.character(at: cursor) == 38 else { cursor += 1; continue }
            let remaining = NSRange(location: cursor + 1, length: min(32, ns.length - cursor - 1))
            let semicolon = ns.range(of: ";", options: [], range: remaining)
            guard semicolon.location != NSNotFound, semicolon.location - cursor <= 32 else {
                cursor += 1
                continue
            }
            let body = ns.substring(with: NSRange(location: cursor + 1, length: semicolon.location - cursor - 1))
            guard let decoded = entity(body) else { cursor += 1; continue }
            output += ns.substring(with: NSRange(location: copiedThrough, length: cursor - copiedThrough))
            output += decoded
            cursor = semicolon.location + 1
            copiedThrough = cursor
        }
        output += ns.substring(with: NSRange(location: copiedThrough, length: ns.length - copiedThrough))
        return output
    }

    static func entity(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let hex = body.hasPrefix("#x") || body.hasPrefix("#X")
            let digits = body.dropFirst(hex ? 2 : 1)
            guard !digits.isEmpty,
                  digits.allSatisfy({ hex ? $0.isHexDigit : $0.isASCII && $0.isNumber }),
                  let value = UInt32(digits, radix: hex ? 16 : 10),
                  let scalar = Unicode.Scalar(value) else { return nil }
            return String(scalar)
        }
        return namedEntities[body]
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "ndash": "–", "mdash": "—",
        "laquo": "«", "raquo": "»", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}"
    ]

    private static func isEscaped(_ offset: Int, in source: NSString) -> Bool {
        var cursor = offset
        var count = 0
        while cursor > 0, source.character(at: cursor - 1) == 92 {
            count += 1
            cursor -= 1
        }
        return count % 2 == 1
    }
}
