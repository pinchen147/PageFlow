import Foundation

/// Shared table-source grammar used by the legacy cell editor and semantic import/export.
enum SemanticTableCellCodec {
    static let lineBreakTag = try! NSRegularExpression(pattern: #"<br\s*/?>"#, options: [.caseInsensitive])

    static func decode(_ source: String) throws -> SemanticInlineText {
        try decodeWithSourceMap(source).text
    }

    static func decodeWithSourceMap(_ source: String) throws -> (text: SemanticInlineText, map: SemanticSourceMap) {
        let projection = decodedSourceMapping(source)
        let semantic = try SemanticInlineCodec.decodeWithSourceMap(projection.text, htmlPolicy: .preserveOpaque,
                                                                   allowsEmphasisAcrossLineBreaks: true)
        var segments: [SemanticSourceMap.Segment] = []
        var projectionIndex = 0
        for segment in semantic.map.segments {
            if segment.kind == .literal, segment.source.length == segment.visible.length {
                while projectionIndex < projection.segments.count,
                      NSMaxRange(projection.segments[projectionIndex].visible) <= segment.source.location { projectionIndex += 1 }
                var index = projectionIndex
                while index < projection.segments.count {
                    let raw = projection.segments[index]
                    if raw.visible.location >= NSMaxRange(segment.source) { break }
                    let overlap = NSIntersectionRange(raw.visible, segment.source)
                    if overlap.length > 0 {
                        let start = projection.decodedToSource[overlap.location]
                        let end = projection.decodedToSource[NSMaxRange(overlap)]
                        segments.append(.init(source: NSRange(location: start, length: end - start),
                            visible: NSRange(location: segment.visible.location + overlap.location - segment.source.location,
                                             length: overlap.length), kind: raw.kind))
                    }
                    index += 1
                }
            } else {
                let start = projection.decodedToSource[segment.source.location]
                let end = projection.decodedToSource[NSMaxRange(segment.source)]
                segments.append(.init(source: NSRange(location: start, length: end - start),
                                      visible: segment.visible, kind: segment.kind))
            }
        }
        return (semantic.text, SemanticSourceMap(segments: segments, sourceUTF16Count: source.utf16.count,
            visibleUTF16Count: semantic.text.utf16Count, sourceText: source, visibleText: semantic.text.text))
    }

    static func encode(_ content: SemanticInlineText, lineBreak: String = "<br>") throws -> String {
        let candidate = encodedSource(try SemanticInlineCodec.encode(content), selection: NSRange(location: 0, length: 0),
                                      lineBreak: lineBreak).text
        if let decoded = try? decode(candidate), decoded == content { return candidate }
        let fallback = encodedSource(try SemanticInlineCodec.serialized(content, html: true),
                                     selection: NSRange(location: 0, length: 0), lineBreak: lineBreak).text
        guard try decode(fallback) == content else { throw SemanticInlineCodec.Failure.roundTripMismatch }
        return fallback
    }

    static func decodedSource(_ source: String, selection: NSRange = NSRange(location: 0, length: 0)) -> (text: String, selection: NSRange) {
        let mapping = decodedSourceMapping(source)
        let start = mapping.sourceToDecoded[min(selection.location, mapping.sourceToDecoded.count - 1)]
        let end = mapping.sourceToDecoded[min(NSMaxRange(selection), mapping.sourceToDecoded.count - 1)]
        return (mapping.text, NSRange(location: start, length: max(0, end - start)))
    }

    static func decodedSourceMapping(_ source: String) -> (text: String, sourceToDecoded: [Int], decodedToSource: [Int], segments: [SemanticSourceMap.Segment]) {
        let input = source as NSString
        var output: [UInt16] = []
        var offsets = Array(repeating: 0, count: input.length + 1)
        var sourceBoundaries = [0]
        var segments: [SemanticSourceMap.Segment] = []
        func record(_ source: NSRange, decoded: Int, length: Int, kind: SemanticSourceMap.Kind) {
            if kind == .literal, let last = segments.last, last.kind == .literal,
               NSMaxRange(last.source) == source.location, NSMaxRange(last.visible) == decoded {
                segments[segments.count - 1] = .init(source: NSRange(location: last.source.location,
                    length: last.source.length + source.length), visible: NSRange(location: last.visible.location,
                    length: last.visible.length + length), kind: .literal)
            } else {
                segments.append(.init(source: source, visible: NSRange(location: decoded, length: length), kind: kind))
            }
        }
        var index = 0
        var slashes = 0
        let tags = lineBreakTag.matches(in: source, range: NSRange(location: 0, length: input.length))
        var nextTag = 0
        while index < input.length {
            offsets[index] = output.count
            while nextTag < tags.count, tags[nextTag].range.location < index { nextTag += 1 }
            if nextTag < tags.count, tags[nextTag].range.location == index, slashes % 2 == 0 {
                let tag = tags[nextTag].range
                for inner in index..<NSMaxRange(tag) { offsets[inner] = output.count }
                record(tag, decoded: output.count, length: 1, kind: .lineEnding)
                output.append(10)
                index = NSMaxRange(tag)
                sourceBoundaries.append(index)
                slashes = 0
                continue
            }
            let unit = input.character(at: index)
            // `\|` shows as `|`; encoding escapes it again.
            if unit == 92, slashes % 2 == 0, index + 1 < input.length, input.character(at: index + 1) == 124 {
                offsets[index + 1] = output.count
                record(NSRange(location: index, length: 2), decoded: output.count, length: 1, kind: .escape)
                output.append(124)
                index += 2
                sourceBoundaries.append(index)
                slashes = 0
                continue
            }
            record(NSRange(location: index, length: 1), decoded: output.count, length: 1, kind: .literal)
            output.append(unit)
            slashes = unit == 92 ? slashes + 1 : 0
            index += 1
            sourceBoundaries.append(index)
        }
        offsets[input.length] = output.count
        return (String(decoding: output, as: UTF16.self), offsets, sourceBoundaries, segments)
    }

    /// Encode only the edited cell, retaining existing escapes. Map the native
    /// UTF-16 selection through inserted escaping and inline line breaks. A
    /// typed `<br>` tag is escaped (`\<br>`) so it stays text.
    static func encodedSource(_ text: String, selection: NSRange, lineBreak: String = "<br>") -> (text: String, selection: NSRange) {
        let input = Array(text.utf16)
        let typedTags = Set(lineBreakTag.matches(in: text, range: NSRange(location: 0, length: input.count))
            .map(\.range.location))
        var output: [UInt16] = []
        var offsets = Array(repeating: 0, count: input.count + 1)
        var slashes = 0
        var index = 0
        while index < input.count {
            offsets[index] = output.count
            let unit = input[index]
            if unit == 13 || unit == 10 {
                output.append(contentsOf: Array(lineBreak.utf16))
                if unit == 13, index + 1 < input.count, input[index + 1] == 10 {
                    index += 1
                    offsets[index] = output.count
                }
            } else {
                if unit == 124 && slashes % 2 == 0 { output.append(92) }
                if unit == 60 && slashes % 2 == 0 && typedTags.contains(index) { output.append(92) }
                output.append(unit)
            }
            slashes = unit == 92 ? slashes + 1 : 0
            index += 1
        }
        offsets[input.count] = output.count
        let start = offsets[min(selection.location, input.count)]
        let end = offsets[min(NSMaxRange(selection), input.count)]
        return (String(decoding: output, as: UTF16.self), NSRange(location: start, length: max(0, end - start)))
    }
}
