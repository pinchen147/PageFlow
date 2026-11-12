import Foundation

extension SemanticInlineCodec {
    static func decodedLiteral(_ source: String) -> String {
        let ns = source as NSString
        let units = Array(source.utf16)
        var decoded: [UInt16] = []
        var cursor = 0
        while cursor < units.count {
            if units[cursor] == 92, cursor + 1 < units.count {
                let next = units[cursor + 1]
                if (33...47).contains(next) || (58...64).contains(next) ||
                    (91...96).contains(next) || (123...126).contains(next) {
                    decoded.append(next)
                    cursor += 2
                    continue
                }
            }
            if units[cursor] == 38 {
                let end = ns.range(of: ";", options: [], range: NSRange(location: cursor + 1,
                    length: min(32, units.count - cursor - 1)))
                if end.location != NSNotFound,
                   let value = SemanticInlineCodecHTML.entity(ns.substring(with: NSRange(
                    location: cursor + 1, length: end.location - cursor - 1))) {
                    decoded.append(contentsOf: value.utf16)
                    cursor = end.location + 1
                    continue
                }
            }
            decoded.append(units[cursor])
            cursor += 1
        }
        return String(decoding: decoded, as: UTF16.self)
    }

    static func title(in source: NSString, destination: NSRange, full: NSRange) -> String? {
        let start = NSMaxRange(destination)
        let end = NSMaxRange(full) - 1
        guard start < end else { return nil }
        var suffix = source.substring(with: NSRange(location: start, length: end - start))
        if suffix.hasPrefix(">") { suffix.removeFirst() }
        suffix = suffix.trimmingCharacters(in: .whitespaces)
        guard suffix.count >= 2, let quote = suffix.first, ["\"", "'", "("].contains(quote) else { return nil }
        return decodedLiteral(String(suffix.dropFirst().dropLast()))
    }

    static func serialized(_ content: SemanticInlineText, html: Bool) throws -> String {
        var result = ""
        var index = 0
        while index < content.runs.count {
            let run = content.runs[index]
            if case .url(let destination, let title) = run.link {
                var label = ""
                var end = index
                while end < content.runs.count, content.runs[end].link == run.link {
                    label += try marked(content.runs[end], html: html)
                    end += 1
                }
                result += "[" + label + "](" + destinationSource(destination) + titleSource(title) + ")"
                index = end
            } else if case .wiki(let target) = run.link {
                guard case .text(let label) = run.payload else { throw Failure.unsupportedNode("wiki label payload") }
                let body = "[[" + SemanticInlineCodecHTML.escapeLiteral(target) + "|" +
                    SemanticInlineCodecHTML.escapeLiteral(label) + "]]"
                result += wrapped(body, marks: run.marks, html: html)
                index += 1
            } else {
                result += try marked(run, html: html)
                index += 1
            }
        }
        return result
    }

    private static func marked(_ run: SemanticInlineRun, html: Bool) throws -> String {
        let body: String
        switch run.payload {
        case .text(let value): body = html ? SemanticInlineCodecHTML.escapeLiteral(value, preservesLineBreaks: true) : escapedMarkdown(value, preservesLineBreaks: true)
        case .code(let value):
            if html {
                body = "<code>" + SemanticInlineCodecHTML.escapeLiteral(value) + "</code>"
            } else {
                var longest = 0
                var current = 0
                for unit in value.utf16 {
                    current = unit == 96 ? current + 1 : 0
                    longest = max(longest, current)
                }
                let fence = String(repeating: "`", count: longest + 1)
                let allSpaces = !value.isEmpty && value.allSatisfy { $0 == " " }
                let padding = value.hasPrefix("`") || value.hasSuffix("`") ||
                    (!allSpaces && value.hasPrefix(" ") && value.hasSuffix(" "))
                body = fence + (padding ? " " : "") + value + (padding ? " " : "") + fence
            }
        case .object(.image(let source, let alt, let title)):
            body = "![" + escapedMarkdown(alt) + "](" + destinationSource(source) + titleSource(title) + ")"
        case .object(.math(let value)): body = "$" + value + "$"
        case .object(.embed(let value)): body = "![[" + SemanticInlineCodecHTML.escapeLiteral(value) + "]]"
        case .object(.opaque(let source)): body = source
        }
        return wrapped(body, marks: run.marks, html: html)
    }

    private static func wrapped(_ body: String, marks: SemanticInlineMarks, html: Bool) -> String {
        var text = body
        if html {
            for (mark, name) in SemanticInlineCodecHTML.markTags.reversed() where marks.contains(mark) {
                text = "<\(name)>" + text + "</\(name)>"
            }
        } else {
            let wrappers: [(SemanticInlineMarks, String, String)] = [
                (.italic, "*", "*"), (.bold, "**", "**"), (.strikethrough, "~~", "~~"),
                (.highlight, "==", "=="), (.underline, "<u>", "</u>")
            ]
            for (mark, open, close) in wrappers where marks.contains(mark) { text = open + text + close }
        }
        return text
    }

    private static func destinationSource(_ value: String) -> String {
        "<" + escapedMarkdown(value).replacingOccurrences(of: " ", with: "&#32;") + ">"
    }

    private static func titleSource(_ value: String?) -> String {
        value.map { " \"" + escapedMarkdown($0) + "\"" } ?? ""
    }

    private static func escapedMarkdown(_ text: String, preservesLineBreaks: Bool = false) -> String {
        text.unicodeScalars.map { scalar -> String in
            switch scalar.value {
            case let value where preservesLineBreaks && (value == 10 || value == 13): return String(scalar)
            case 38: return "&amp;"
            case 60: return "&lt;"
            case 62: return "&gt;"
            case 33...47, 58...64, 91...96, 123...126: return "\\" + String(scalar)
            case 0...31, 127: return "&#\(scalar.value);"
            default: return String(scalar)
            }
        }.joined()
    }
}
