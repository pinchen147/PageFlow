import AppKit

/// Spreadsheet clipboard flavours for tables (owner decision, PR D): a grid
/// pasted from Numbers, Sheets or Excel (an HTML `<table>` or tab-separated
/// text) becomes a Markdown table, and a copied cell range also carries an
/// HTML table and tab-separated text so spreadsheets get a grid. Markdown
/// stays the plain-text flavour (doc 24, owner amendment of 2026-10-20).
enum TableClipboard {

    // MARK: - Tab-separated text

    /// The rows of tab-separated `text`, or nil when it has no tab. A field
    /// in double quotes may hold tabs, line breaks and doubled quotes (the
    /// spreadsheets' quoting); one final line break ends the last row.
    static func tsvRows(_ text: String) -> [[String]]? {
        guard text.contains("\t") else { return nil }
        let units = Array(text.utf16)
        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt16] = []
        var index = 0
        var atFieldStart = true
        func endField() {
            row.append(String(decoding: field, as: UTF16.self))
            field = []
            atFieldStart = true
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
        }
        while index < units.count {
            let unit = units[index]
            if atFieldStart, unit == 0x22, let close = closingQuote(in: units, from: index + 1) {
                // A quoted field: its quotes go, doubled quotes become one.
                var inner = index + 1
                while inner < close {
                    field.append(units[inner])
                    inner += units[inner] == 0x22 ? 2 : 1
                }
                index = close + 1
                atFieldStart = false
                continue
            }
            atFieldStart = false
            switch unit {
            case 0x09: endField()
            case 0x0D:
                if index + 1 < units.count, units[index + 1] == 0x0A { index += 1 }
                endRow()
            case 0x0A: endRow()
            default: field.append(unit)
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty || !atFieldStart { endRow() }
        return rows.isEmpty ? nil : rows
    }

    /// The quote that closes a quoted field opened before `start`: one not
    /// doubled, followed by a tab, a line break or the end.
    private static func closingQuote(in units: [UInt16], from start: Int) -> Int? {
        var index = start
        while index < units.count {
            if units[index] == 0x22 {
                if index + 1 < units.count, units[index + 1] == 0x22 { index += 2; continue }
                let next = index + 1 < units.count ? units[index + 1] : nil
                return next == nil || next == 0x09 || next == 0x0A || next == 0x0D ? index : nil
            }
            index += 1
        }
        return nil
    }

    /// Tab-separated text that reads as a spreadsheet grid in prose: at least
    /// two rows and two columns, every row as wide, and a first column that
    /// is not all empty (tab-indented lines are text, not a table).
    static func proseGrid(fromTSV text: String) -> [[String]]? {
        guard let rows = tsvRows(text), rows.count >= 2, let width = rows.first?.count, width >= 2,
              rows.allSatisfy({ $0.count == width }),
              rows.contains(where: { !$0[0].trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        return rows
    }

    /// `rows` of cell text as tab-separated text, quoting a field that holds
    /// a tab, a line break or a quote.
    static func tsv(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { value in
                guard value.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\"" }) else { return value }
                return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    // MARK: - HTML

    /// `rows` of cell text as an HTML table, the first row as header cells.
    static func html(_ rows: [[String]]) -> String {
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "\r\n", with: "<br>").replacingOccurrences(of: "\n", with: "<br>")
        }
        let body = rows.enumerated().map { index, row in
            let tag = index == 0 ? "th" : "td"
            return "<tr>" + row.map { "<\(tag)>" + escaped($0) + "</\(tag)>" }.joined() + "</tr>"
        }.joined()
        return "<meta charset=\"utf-8\"><table>" + body + "</table>"
    }

    private static let invisibleHTML = try! NSRegularExpression(
        pattern: #"<head\b.*?</head>|<style\b.*?</style>|<script\b.*?</script>|<!--.*?-->"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let anyTag = try! NSRegularExpression(pattern: #"<[^>]*>"#)

    /// Whether `html` holds one table and no other visible text, as a
    /// spreadsheet's copy does; a web page's table among prose does not count.
    static func isLoneTable(_ html: String) -> Bool {
        guard let start = html.range(of: "<table", options: .caseInsensitive),
              let end = html.range(of: "</table>", options: [.caseInsensitive, .backwards]),
              start.lowerBound < end.lowerBound else { return false }
        let outside = String(html[..<start.lowerBound]) + " " + String(html[end.upperBound...])
        var text = invisibleHTML.stringByReplacingMatches(in: outside, range: NSRange(location: 0, length: (outside as NSString).length),
                                                          withTemplate: " ")
        text = anyTag.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: " ")
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Markdown

    /// `rows` of cell text as a GFM pipe table: the first row is the header,
    /// short rows are padded, pipes are escaped and line breaks become `<br>`.
    static func markdownTable(_ rows: [[String]]) -> String? {
        guard let width = rows.map(\.count).max(), width > 0, !rows.isEmpty else { return nil }
        func line(_ row: [String]) -> String {
            let cells = (row + Array(repeating: "", count: width - row.count)).map { value -> String in
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                let encoded = MarkdownTableEditingSession.encodedCell(trimmed, selection: NSRange(location: 0, length: 0)).text
                return encoded.isEmpty ? " " : " " + encoded + " "
            }
            return "|" + cells.joined(separator: "|") + "|"
        }
        let delimiter = "|" + Array(repeating: " --- ", count: width).joined(separator: "|") + "|"
        return ([line(rows[0]), delimiter] + rows.dropFirst().map(line)).joined(separator: "\n")
    }

    /// A Markdown table for a paste into prose, from a spreadsheet's HTML
    /// table (checked before the plain text) or its tab-separated text. Nil
    /// when the pasteboard holds no such grid, or when its plain text is
    /// already a Markdown table (another Markdown editor's copy).
    static func proseTable(from board: NSPasteboard) -> String? {
        let plain = board.string(forType: .string)
        if let plain, isMarkdownTable(plain) { return nil }
        if let html = board.string(forType: .html), isLoneTable(html),
           let rows = MarkdownTableEditingSession.htmlTableCells(html), rows.count >= 2, (rows.map(\.count).max() ?? 0) >= 2 {
            return markdownTable(rows)
        }
        for text in [board.string(forType: .tabularText), plain].compactMap({ $0 }) {
            if let rows = proseGrid(fromTSV: text) { return markdownTable(rows) }
        }
        return nil
    }

    private static func isMarkdownTable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("|") else { return false }
        return MarkdownTableSource(source: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) != nil
    }
}
