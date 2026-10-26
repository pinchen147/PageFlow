import Foundation

/// Source coordinates shared by block parsing, tokenization and fenced-code styling.
struct FencedCode {
    struct Opening {
        let character: unichar
        let marker: NSRange
        let line: NSRange
        let info: NSRange
    }

    let opening: Opening
    let content: NSRange
    let closingMarker: NSRange?
    let closingLine: NSRange?
    /// The code token excludes the closed fence's trailing line ending.
    let range: NSRange

    var isClosed: Bool { closingMarker != nil }

    func language(in source: NSString) -> String? {
        let info = source.substring(with: opening.info).trimmingCharacters(in: .whitespaces)
        return info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
    }

    static func opening(in source: NSString, line: NSRange) -> Opening? {
        guard line.location >= 0, NSMaxRange(line) <= source.length else { return nil }
        let end = contentEnd(in: source, line: line)
        var cursor = line.location
        while cursor < end, source.character(at: cursor) == 0x20 { cursor += 1 }
        guard cursor - line.location <= 3, cursor < end else { return nil }
        let character = source.character(at: cursor)
        guard character == 0x60 || character == 0x7E else { return nil }
        let start = cursor
        while cursor < end, source.character(at: cursor) == character { cursor += 1 }
        guard cursor - start >= 3 else { return nil }
        if character == 0x60 {
            for index in cursor..<end where source.character(at: index) == 0x60 { return nil }
        }
        return Opening(character: character, marker: NSRange(location: start, length: cursor - start),
                       line: line, info: NSRange(location: cursor, length: end - cursor))
    }

    static func closingMarker(in source: NSString, line: NSRange, opening: Opening) -> NSRange? {
        let end = contentEnd(in: source, line: line)
        var cursor = line.location
        while cursor < end, source.character(at: cursor) == 0x20 { cursor += 1 }
        guard cursor - line.location <= 3 else { return nil }
        let start = cursor
        while cursor < end, source.character(at: cursor) == opening.character { cursor += 1 }
        guard cursor - start >= opening.marker.length else { return nil }
        let markerEnd = cursor
        while cursor < end, source.character(at: cursor) == 0x20 || source.character(at: cursor) == 0x09 {
            cursor += 1
        }
        guard cursor == end else { return nil }
        return NSRange(location: start, length: markerEnd - start)
    }

    static func scan(in source: NSString, range: NSRange) -> FencedCode? {
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= source.length else { return nil }
        let end = NSMaxRange(range)
        let firstLine = NSIntersectionRange(source.lineRange(for: NSRange(location: range.location, length: 0)), range)
        guard let opening = opening(in: source, line: firstLine) else { return nil }
        let contentStart = NSMaxRange(firstLine)
        var cursor = contentStart
        while cursor < end {
            let line = NSIntersectionRange(source.lineRange(for: NSRange(location: cursor, length: 0)), range)
            if let marker = closingMarker(in: source, line: line, opening: opening) {
                return FencedCode(opening: opening,
                                  content: NSRange(location: contentStart, length: cursor - contentStart),
                                  closingMarker: marker, closingLine: line,
                                  range: NSRange(location: range.location, length: contentEnd(in: source, line: line) - range.location))
            }
            cursor = NSMaxRange(line)
        }
        return FencedCode(opening: opening, content: NSRange(location: contentStart, length: end - contentStart),
                          closingMarker: nil, closingLine: nil, range: range)
    }

    private static func contentEnd(in source: NSString, line: NSRange) -> Int {
        var end = NSMaxRange(line)
        while end > line.location {
            let unit = source.character(at: end - 1)
            guard unit == 0x0A || unit == 0x0D else { break }
            end -= 1
        }
        return end
    }
}
