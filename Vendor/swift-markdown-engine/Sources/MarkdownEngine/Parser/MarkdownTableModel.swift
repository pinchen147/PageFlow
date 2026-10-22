//
//  MarkdownTableModel.swift
//  MarkdownEngine
//
//  Source-backed GFM pipe table model.
//

import Foundation

enum MarkdownTableAlignment: Equatable {
    case left
    case center
    case right
}

struct MarkdownTableCell: Hashable {
    let row: Int
    let column: Int
}

struct MarkdownTableModel: Equatable {
    var header: [String]
    var alignments: [MarkdownTableAlignment]
    var rows: [[String]]

    var rowCount: Int { 1 + rows.count }
    var columnCount: Int { alignments.count }

    static func parse(_ source: String) -> MarkdownTableModel? {
        let lines = source
            .components(separatedBy: CharacterSet.newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2,
              let header = MarkdownTableScanner.cellStrings(in: lines[0]),
              let alignments = MarkdownTableScanner.alignments(in: lines[1]),
              !header.isEmpty,
              header.count == alignments.count else {
            return nil
        }

        let columnCount = header.count
        let bodyRows = lines.dropFirst(2).compactMap { MarkdownTableScanner.cellStrings(in: $0) }
        return MarkdownTableModel(
            header: padded(header, to: columnCount, with: ""),
            alignments: padded(alignments, to: columnCount, with: .left),
            rows: bodyRows.map { padded($0, to: columnCount, with: "") }
        )
    }

    func cell(row: Int, column: Int) -> String {
        guard row >= 0, row < rowCount, column >= 0, column < columnCount else { return "" }
        if row == 0 {
            return header[column]
        }
        return rows[row - 1][column]
    }

    mutating func setCell(row: Int, column: Int, text: String) {
        guard row >= 0, row < rowCount, column >= 0, column < columnCount else { return }
        if row == 0 {
            header[column] = text
        } else {
            rows[row - 1][column] = text
        }
    }

    mutating func clearCells(_ cells: Set<MarkdownTableCell>) {
        for cell in cells {
            setCell(row: cell.row, column: cell.column, text: "")
        }
    }

    mutating func insertBodyRow(after row: Int) -> Int {
        let bodyIndex = max(0, min(rows.count, row))
        rows.insert(Array(repeating: "", count: columnCount), at: bodyIndex)
        return bodyIndex + 1
    }

    mutating func insertColumn(after column: Int) -> Int {
        let insertion = max(0, min(column + 1, columnCount))
        header.insert("", at: insertion)
        alignments.insert(.left, at: insertion)
        for index in rows.indices {
            rows[index].insert("", at: insertion)
        }
        return insertion
    }

    /// Delete a body row. `row` is in model coords, so `row == 0` is the header
    /// and is never deleted. Returns the row to select afterward (clamped to the
    /// last surviving row, falling back to the header), or nil if rejected.
    @discardableResult
    mutating func deleteRow(_ row: Int) -> Int? {
        guard row >= 1, row < rowCount else { return nil }
        rows.remove(at: row - 1)
        return min(row, rowCount - 1)
    }

    /// Delete a column across the header, separator, and every body row.
    /// The grid retains its existing two-column minimum for column deletion.
    /// Returns the column to select afterward, or nil if rejected.
    @discardableResult
    mutating func deleteColumn(_ column: Int) -> Int? {
        guard column >= 0, column < columnCount, columnCount > 2 else { return nil }
        header.remove(at: column)
        alignments.remove(at: column)
        for index in rows.indices {
            rows[index].remove(at: column)
        }
        return min(column, columnCount - 1)
    }

    /// Set a column's alignment (drives the serialized delimiter row).
    mutating func setAlignment(_ alignment: MarkdownTableAlignment, forColumn column: Int) {
        guard column >= 0, column < columnCount else { return }
        alignments[column] = alignment
    }

    func serialized() -> String {
        let lines = [
            serializedRow(header),
            serializedSeparator()
        ] + rows.map(serializedRow)
        return lines.joined(separator: "\n")
    }

    private func serializedRow(_ cells: [String]) -> String {
        "| " + cells.map(Self.escapeCell).joined(separator: " | ") + " |"
    }

    private func serializedSeparator() -> String {
        let cells = alignments.map { alignment in
            switch alignment {
            case .left:
                return "---"
            case .center:
                return ":---:"
            case .right:
                return "---:"
            }
        }
        return "| " + cells.joined(separator: " | ") + " |"
    }

    private static func escapeCell(_ text: String) -> String {
        var output = ""
        var previousWasBackslash = false
        for character in text {
            if character == "|" && !previousWasBackslash {
                output.append("\\")
            }
            output.append(character)
            previousWasBackslash = character == "\\" && !previousWasBackslash
        }
        return output
    }

    private static func padded<T>(_ values: [T], to count: Int, with fill: T) -> [T] {
        if values.count == count { return values }
        if values.count > count { return Array(values.prefix(count)) }
        return values + Array(repeating: fill, count: count - values.count)
    }
}
