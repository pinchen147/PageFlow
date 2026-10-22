//
//  MarkdownTableScanner.swift
//  MarkdownEngine
//
//  Shared source-preserving pipe-table line scanner.
//

import Foundation

enum MarkdownTableScanner {
    struct Cell: Equatable {
        /// Original padding and escapes, excluding the structural pipes.
        let rawRange: NSRange
        /// Empty cells retain a zero-length insertion range; absent cells have no entry.
        let contentRange: NSRange
    }

    struct Row: Equatable {
        let lineRange: NSRange
        let contentRange: NSRange
        let lineEndingRange: NSRange
        let leadingPipeRange: NSRange?
        let trailingPipeRange: NSRange?
        let cells: [Cell]
    }

    /// All ranges are absolute UTF-16 offsets into `source`. No source is normalized,
    /// unescaped, padded, or discarded, including cells beyond a table's header width.
    static func scan(inLine line: NSRange, of source: NSString) -> Row? {
        guard line.location >= 0, line.length >= 0, line.location <= source.length,
              line.length <= source.length - line.location else { return nil }
        let lineEnd = NSMaxRange(line)
        var contentEnd = lineEnd
        if contentEnd > line.location, source.character(at: contentEnd - 1) == 0x0A {
            contentEnd -= 1
        }
        if contentEnd > line.location, source.character(at: contentEnd - 1) == 0x0D {
            contentEnd -= 1
        }
        let content = NSRange(location: line.location, length: contentEnd - line.location)
        let bounds = trimmed(line.location, contentEnd, source)
        guard bounds.length > 0 else { return nil }

        var delimiters: [Int] = []
        var escaped = false
        for index in bounds.location..<NSMaxRange(bounds) {
            let character = source.character(at: index)
            if escaped {
                escaped = false
            } else if character == backslash {
                escaped = true
            } else if character == pipe {
                delimiters.append(index)
            }
        }
        guard !delimiters.isEmpty else { return nil }
        let leading = delimiters.first == bounds.location ? delimiters.removeFirst() : nil
        let trailing = delimiters.last == NSMaxRange(bounds) - 1 ? delimiters.removeLast() : nil
        var cellStart = leading.map { $0 + 1 } ?? line.location
        let cellEnd = trailing ?? contentEnd
        var cells: [Cell] = []
        for delimiter in delimiters {
            cells.append(Cell(
                rawRange: NSRange(location: cellStart, length: delimiter - cellStart),
                contentRange: trimmed(cellStart, delimiter, source)
            ))
            cellStart = delimiter + 1
        }
        cells.append(Cell(
            rawRange: NSRange(location: cellStart, length: cellEnd - cellStart),
            contentRange: trimmed(cellStart, cellEnd, source)
        ))
        return Row(
            lineRange: line, contentRange: content,
            lineEndingRange: NSRange(location: contentEnd, length: lineEnd - contentEnd),
            leadingPipeRange: leading.map { NSRange(location: $0, length: 1) },
            trailingPipeRange: trailing.map { NSRange(location: $0, length: 1) },
            cells: cells
        )
    }

    static func isTableRow(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        let source = line as NSString
        return scan(inLine: NSRange(location: 0, length: source.length), of: source) != nil
    }

    static func isTableStart(header: String, separator: String) -> Bool {
        guard let cells = cellStrings(in: header), let alignments = alignments(in: separator) else { return false }
        return cells.count == alignments.count
    }

    static func isTableSeparator(_ line: String) -> Bool {
        alignments(in: line) != nil
    }

    static func cellStrings(in line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        let source = line as NSString
        guard let row = scan(inLine: NSRange(location: 0, length: source.length), of: source) else { return nil }
        return row.cells.map { unescapePipes(source.substring(with: $0.contentRange)) }
    }

    static func alignments(in line: String) -> [MarkdownTableAlignment]? {
        // A borderless row opening with `- ` is a GFM list item, not a delimiter row.
        let leading = line.drop { $0 == " " || $0 == "\t" }
        if leading.hasPrefix("- ") || leading.hasPrefix("-\t") { return nil }
        guard let cells = cellStrings(in: line) else { return nil }
        var alignments: [MarkdownTableAlignment] = []
        for cell in cells {
            guard isSeparatorCell(cell) else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.right)
            default: alignments.append(.left)
            }
        }
        return alignments
    }

    /// Includes explicit empty cells so their column positions and insertion points survive.
    static func cellContentRanges(inLine line: NSRange, of source: NSString) -> [NSRange] {
        scan(inLine: line, of: source)?.cells.map(\.contentRange) ?? []
    }

    private static let pipe: unichar = 0x7C
    private static let backslash: unichar = 0x5C

    private static func isSpace(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func trimmed(_ start: Int, _ end: Int, _ source: NSString) -> NSRange {
        var lower = start, upper = end
        while lower < upper, isSpace(source.character(at: lower)) { lower += 1 }
        while upper > lower, isSpace(source.character(at: upper - 1)) { upper -= 1 }
        return NSRange(location: lower, length: upper - lower)
    }

    /// Rendering keeps the historical pipe-unescaping behavior; source ranges stay literal.
    private static func unescapePipes(_ content: String) -> String {
        var output = ""
        var escaped = false
        for character in content {
            if escaped {
                if character != "|" { output.append("\\") }
                output.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                output.append(character)
            }
        }
        if escaped { output.append("\\") }
        return output
    }

    /// A GFM delimiter cell: `:?-+:?` (one hyphen is enough).
    private static func isSeparatorCell(_ cell: String) -> Bool {
        var body = Substring(cell)
        if body.hasPrefix(":") { body = body.dropFirst() }
        if body.hasSuffix(":") { body = body.dropLast() }
        return !body.isEmpty && body.allSatisfy { $0 == "-" }
    }
}
