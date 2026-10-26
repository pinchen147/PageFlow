import Foundation

/// A table's literal source spans. Display models never participate in writes.
struct MarkdownTableSource {
    let source: String
    let range: NSRange
    let rows: [MarkdownTableScanner.Row]
    let columnCount: Int

    init?(source: String, range: NSRange) {
        let text = source as NSString
        guard range.location >= 0, range.length > 0,
              NSMaxRange(range) <= text.length else { return nil }
        var rows: [MarkdownTableScanner.Row] = []
        var cursor = range.location
        while cursor < NSMaxRange(range) {
            let line = NSIntersectionRange(text.lineRange(for: NSRange(location: cursor, length: 0)), range)
            guard line.length > 0, let row = MarkdownTableScanner.scan(inLine: line, of: text) else { return nil }
            rows.append(row)
            cursor = NSMaxRange(line)
        }
        guard rows.count >= 2,
              MarkdownTableScanner.isTableStart(
                header: text.substring(with: rows[0].contentRange),
                separator: text.substring(with: rows[1].contentRange)
              ) else { return nil }
        self.source = source
        self.range = range
        self.rows = rows
        columnCount = rows[0].cells.count
    }

    /// Logical rows: the header plus body rows. The delimiter row is `rows[1]`.
    var rowCount: Int { rows.count - 1 }
}
