import Foundation

/// Source containers for both grips and drop slots. The rendering parser groups
/// marker lines; dragging additionally keeps their continued children together.
enum BlockDragIndex {
    private enum ChildPrefix { case quote, indentation(Int) }
    static func grouped(_ blocks: [Block], in text: NSString) -> [Block] {
        var pending = blocks
        var result: [Block] = []
        var index = 0
        while index < pending.count {
            guard !Task.isCancelled else { return [] }
            let first = pending[index]
            guard first.kind == .list || first.kind == .blockquote else {
                result.append(first)
                index += 1
                continue
            }
            let end = containerEnd(from: first, in: text)
            guard !Task.isCancelled else { return [] }
            result.append(Block(kind: first.kind, range: NSRange(location: first.range.location,
                                                                 length: end - first.range.location)))
            while index < pending.count, NSMaxRange(pending[index].range) <= end { index += 1 }
            if index < pending.count, pending[index].range.location < end {
                // A child closing fence can look like a fresh opener to the
                // flat renderer. Recover only its leftover top-level suffix.
                let remainder = NSRange(location: end, length: NSMaxRange(pending[index].range) - end)
                let recovered = BlockParser.parse(text.substring(with: remainder), memoizing: false).map {
                    Block(kind: $0.kind, range: NSRange(location: end + $0.range.location, length: $0.range.length))
                }
                pending.replaceSubrange(index...index, with: recovered)
            }
        }
        return result
    }

    private static func containerEnd(from block: Block, in text: NSString) -> Int {
        let firstLine = text.lineRange(for: NSRange(location: block.range.location, length: 0))
        let firstBody = text.substring(with: firstLine).trimmingCharacters(in: .newlines)
        let rootIndent = indentation(firstBody)
        var childIndent = listContentColumn(firstBody)
        var offset = block.range.location
        var end = offset
        var allowsLazy = false
        var fence: FencedCode.Opening?
        var fencePrefix: [ChildPrefix] = []
        var blankRunEnd = 0
        var previous = ""
        var isTable = false
        while offset < text.length {
            guard !Task.isCancelled else { return block.range.location }
            let line = text.lineRange(for: NSRange(location: offset, length: 0))
            let raw = text.substring(with: line).trimmingCharacters(in: .newlines)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let body: String
            if block.kind == .blockquote {
                if indentation(raw) <= 3, trimmed.hasPrefix(">") {
                    body = droppingQuoteMarker(trimmed)
                } else {
                    guard !trimmed.isEmpty, allowsLazy, isParagraph(raw) else { break }
                    body = raw
                }
            } else if indentation(raw) == rootIndent, BlockParser.isListItem(raw) {
                // A sibling item also terminates an unclosed child fence.
                childIndent = listContentColumn(raw)
                body = droppingListMarker(raw)
                fence = nil
                previous = ""
                isTable = false
            } else if trimmed.isEmpty {
                // Keep interior blank lines, but leave trailing separators out
                // of the source container and its preview.
                var lookahead = max(blankRunEnd, NSMaxRange(line))
                while lookahead < text.length {
                    guard !Task.isCancelled else { return block.range.location }
                    let next = text.lineRange(for: NSRange(location: lookahead, length: 0))
                    let value = text.substring(with: next).trimmingCharacters(in: .newlines)
                    if !value.trimmingCharacters(in: .whitespaces).isEmpty { break }
                    lookahead = NSMaxRange(next)
                }
                blankRunEnd = lookahead
                guard lookahead < text.length else { break }
                let next = text.lineRange(for: NSRange(location: lookahead, length: 0))
                let value = text.substring(with: next).trimmingCharacters(in: .newlines)
                guard indentation(value) >= childIndent
                    || (indentation(value) == rootIndent && BlockParser.isListItem(value)) else { break }
                body = ""
            } else if indentation(raw) >= childIndent {
                body = droppingIndent(raw, columns: childIndent)
            } else {
                guard allowsLazy, isParagraph(raw) else { break }
                body = raw
            }

            // Literal code retains its markers. Only outer container syntax was
            // removed above; '- ```' inside a fence must never become its end.
            let child: String
            if fence != nil, let literal = applying(fencePrefix, to: body) {
                child = literal
            } else {
                fence = nil
                let content = droppingChildMarkers(body)
                child = content.body
                fencePrefix = content.prefix
            }
            let source = child as NSString
            let range = NSRange(location: 0, length: source.length)
            if let opening = fence {
                if FencedCode.closingMarker(in: source, line: range, opening: opening) != nil { fence = nil }
                allowsLazy = false
            } else if let opening = FencedCode.opening(in: source, line: range) {
                fence = opening
                allowsLazy = false
            } else {
                isTable = MarkdownTableScanner.isTableStart(header: previous, separator: child)
                    || (isTable && MarkdownTableScanner.isTableRow(child))
                // A Setext underline closes the preceding paragraph as a heading.
                // In isolation '=' looks like prose, but it cannot authorize a
                // subsequent unmarked line as a lazy container continuation.
                let endsHeading = allowsLazy && isSetextUnderline(child)
                allowsLazy = !isTable && !endsHeading && isParagraph(child)
            }
            previous = child
            end = NSMaxRange(line)
            offset = end
        }
        return max(NSMaxRange(firstLine), end)
    }

    private static func isSetextUnderline(_ line: String) -> Bool {
        guard indentation(line) <= 3 else { return false }
        let marker = line.trimmingCharacters(in: .whitespaces)
        guard let first = marker.first, first == "=" || first == "-" else { return false }
        return marker.allSatisfy { $0 == first }
    }

    private static func isParagraph(_ line: String) -> Bool {
        BlockParser.parse(line, memoizing: false).first?.kind == .paragraph
    }

    private static func indentation(_ line: String) -> Int {
        var column = 0
        for character in line {
            if character == " " { column += 1 }
            else if character == "\t" { column += 4 - column % 4 }
            else { break }
        }
        return column
    }

    private static func listContentColumn(_ line: String) -> Int {
        let indent = indentation(line)
        let body = line.drop(while: { $0 == " " || $0 == "\t" })
        let marker = body.prefix(while: { $0 != " " && $0 != "\t" })
        let markerEnd = indent + marker.count
        var column = markerEnd
        for character in body.dropFirst(marker.count) {
            if character == " " { column += 1 }
            else if character == "\t" { column += 4 - column % 4 }
            else { break }
        }
        let padding = column - markerEnd
        return markerEnd + (padding <= 4 ? padding : 1)
    }

    private static func droppingIndent(_ line: String, columns: Int) -> String {
        var column = 0
        var cursor = line.startIndex
        while cursor < line.endIndex, column < columns {
            let character = line[cursor]
            if character == " " { column += 1 }
            else if character == "\t" { column += 4 - column % 4 }
            else { break }
            cursor = line.index(after: cursor)
        }
        return String(repeating: " ", count: max(0, column - columns)) + line[cursor...]
    }

    private static func droppingListMarker(_ line: String) -> String {
        let body = line.drop(while: { $0 == " " || $0 == "\t" })
        let marker = body.prefix(while: { $0 != " " && $0 != "\t" })
        return String(body.dropFirst(marker.count).drop(while: { $0 == " " || $0 == "\t" }))
    }

    private static func droppingQuoteMarker(_ line: String) -> String {
        var body = line.dropFirst()
        if body.first == " " || body.first == "\t" { body = body.dropFirst() }
        return String(body)
    }

    private static func droppingChildMarkers(_ line: String) -> (body: String, prefix: [ChildPrefix]) {
        var body = line
        var prefix: [ChildPrefix] = []
        while true {
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            if indentation(body) <= 3, trimmed.hasPrefix(">") {
                prefix.append(.quote)
                body = droppingQuoteMarker(trimmed)
            } else if BlockParser.isListItem(body) {
                prefix.append(.indentation(listContentColumn(body)))
                body = droppingListMarker(body)
            } else { return (body, prefix) }
        }
    }

    private static func applying(_ prefix: [ChildPrefix], to line: String) -> String? {
        var body = line
        for step in prefix {
            switch step {
            case .quote:
                let trimmed = body.trimmingCharacters(in: .whitespaces)
                guard indentation(body) <= 3, trimmed.hasPrefix(">") else { return nil }
                body = droppingQuoteMarker(trimmed)
            case .indentation(let columns):
                if body.trimmingCharacters(in: .whitespaces).isEmpty { body = "" }
                else {
                    guard indentation(body) >= columns else { return nil }
                    body = droppingIndent(body, columns: columns)
                }
            }
        }
        return body
    }
}
