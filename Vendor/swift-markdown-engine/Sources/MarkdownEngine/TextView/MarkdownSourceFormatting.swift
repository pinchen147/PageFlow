//
//  MarkdownSourceFormatting.swift
//  MarkdownEngine
//
//  Pure source transforms for the line and wrap format commands (lists,
//  quote, inline code, link). Each computes one edit; the coordinator applies
//  it as a single undoable source transaction.
//

import Foundation

/// Replace `range` with `replacement`, then select `selection`.
struct MarkdownSourceEdit: Equatable {
    let range: NSRange
    let replacement: String
    let selection: NSRange
}

enum MarkdownSourceFormatting {

    enum LineMarker {
        case bullet
        case number
        case quote
        /// `- [ ] `, a checklist item.
        case task
    }

    // MARK: - Line markers

    /// Toggles `marker` on every line the selection touches: off when every
    /// non-blank line already carries it, otherwise on. Turning a list on
    /// replaces the other list kind's marker; numbers count up from 1. A list
    /// goes inside a quote and replaces a heading's marks; on an empty line
    /// it starts an empty item, as the reference editor's toolbar does.
    static func toggle(_ marker: LineMarker, in text: NSString, selection: NSRange) -> MarkdownSourceEdit? {
        let span = lineSpan(of: selection, in: text)
        let lines = splitLines(text.substring(with: span))
        let filled = lines.filter { !$0.content.trimmingCharacters(in: .whitespaces).isEmpty }
        if filled.isEmpty, marker != .quote {
            guard let line = lines.first else { return nil }
            let prefix = splitIndent(line.content).indent + (marker == .bullet ? "- " : marker == .task ? "- [ ] " : "1. ")
            let caret = NSRange(location: span.location + prefix.utf16.count, length: 0)
            return MarkdownSourceEdit(range: NSRange(location: span.location, length: line.content.utf16.count),
                                      replacement: prefix, selection: caret)
        }
        let removing = !filled.isEmpty && filled.allSatisfy { has(marker, marker == .quote ? $0.content : listBody($0.content).body) }

        var number = 0
        let rebuiltLines = lines.map { line -> (prefix: String, body: String, terminator: String) in
            let blank = line.content.trimmingCharacters(in: .whitespaces).isEmpty
            switch (marker, removing) {
            case (.quote, true):
                return ("", dropQuote(line.content), line.terminator)
            case (.quote, false):
                return blank ? (">", "", line.terminator) : ("> ", line.content, line.terminator)
            case (_, true):
                guard !blank else { return ("", line.content, line.terminator) }
                let (quote, body) = listBody(line.content)
                return (quote, dropListMarker(body), line.terminator)
            case (_, false):
                guard !blank else { return ("", line.content, line.terminator) }
                number += 1
                let (quote, listed) = listBody(line.content)
                let (indent, body) = splitIndent(dropListMarker(dropHeading(listed)))
                let prefix: String
                switch marker {
                case .bullet: prefix = "- "
                case .task: prefix = "- [ ] "
                default: prefix = "\(number). "
                }
                return (quote + indent + prefix, body, line.terminator)
            }
        }
        let rebuilt = rebuiltLines.map { $0.prefix + $0.body + $0.terminator }.joined()
        guard rebuilt != text.substring(with: span) else { return nil }
        // One line selects its text after the marker, so typing replaces it.
        let selection = rebuiltLines.count == 1
            ? NSRange(location: span.location + rebuiltLines[0].prefix.utf16.count,
                      length: rebuiltLines[0].body.utf16.count)
            : contentSelection(of: rebuilt, at: span.location)
        return MarkdownSourceEdit(range: span, replacement: rebuilt, selection: selection)
    }

    private static func has(_ marker: LineMarker, _ line: String) -> Bool {
        let body = splitIndent(line).body
        switch marker {
        case .quote: return line.hasPrefix(">")
        case .bullet: return (body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ")) && taskMarkerLength(body) == nil
        case .number: return numberMarkerLength(body) != nil
        case .task: return taskMarkerLength(body) != nil
        }
    }

    /// The length of a `- [ ] ` / `* [x] ` marker at the start of `body`.
    private static func taskMarkerLength(_ body: String) -> Int? {
        let units = Array(body.utf16)
        guard units.count >= 5, [0x2D, 0x2A, 0x2B].contains(units[0]), units[1] == 0x20, units[2] == 0x5B,
              [0x20, 0x78, 0x58].contains(units[3]), units[4] == 0x5D else { return nil }
        if units.count == 5 { return 5 }
        return units[5] == 0x20 ? 6 : nil
    }

    /// A line's quote marks (kept when a list is toggled) and the rest.
    private static func listBody(_ line: String) -> (quote: String, body: String) {
        let quote = line.prefix { $0 == ">" || $0 == " " }
        guard quote.contains(">") else { return ("", line) }
        let marks = quote.hasSuffix(" ") ? String(quote) : String(quote) + " "
        return (marks, String(line.dropFirst(quote.count)))
    }

    /// `# Plan` → `Plan`: a heading turned into a list item keeps its text.
    private static func dropHeading(_ line: String) -> String {
        let (indent, body) = splitIndent(line)
        let hashes = body.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count), body.dropFirst(hashes.count).first == " " else { return line }
        return indent + body.dropFirst(hashes.count + 1)
    }

    private static func dropQuote(_ line: String) -> String {
        guard line.hasPrefix(">") else { return line }
        let rest = line.dropFirst()
        return String(rest.hasPrefix(" ") ? rest.dropFirst() : rest)
    }

    private static func dropListMarker(_ line: String) -> String {
        let (indent, body) = splitIndent(line)
        if let length = taskMarkerLength(body) {
            return indent + body.dropFirst(length)
        }
        if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
            return indent + body.dropFirst(2)
        }
        if let length = numberMarkerLength(body) {
            return indent + body.dropFirst(length)
        }
        return line
    }

    /// The length of a `12. ` / `3) ` marker at the start of `body`.
    private static func numberMarkerLength(_ body: String) -> Int? {
        let digits = body.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let rest = body.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return digits.count + 2
    }

    private static func splitIndent(_ line: String) -> (indent: String, body: String) {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        return (String(indent), String(line.dropFirst(indent.count)))
    }

    // MARK: - Blocks

    /// the reference editor's `setBlock`: every line the selection touches becomes a
    /// heading of `level` (0: normal text). A list or quote line keeps its
    /// marker and takes the heading inside it. Blank lines stay blank.
    static func setBlock(level: Int, in text: NSString, selection: NSRange) -> MarkdownSourceEdit? {
        let span = lineSpan(of: selection, in: text)
        let lines = splitLines(text.substring(with: span))
        var offset = span.location
        var cumulative = 0
        var rebuilt = ""
        var newStart: Int?
        var newEnd: Int?
        for line in lines {
            let content = line.content as NSString
            let lineLength = content.length + (line.terminator as NSString).length
            let bodyStart = leadingMarkerLength(line.content)
            var hashes = 0
            while bodyStart + hashes < content.length, content.character(at: bodyStart + hashes) == 0x23 { hashes += 1 }
            var oldPrefix = 0
            if hashes > 0, hashes <= 6,
               bodyStart + hashes == content.length || [0x20, 0x09].contains(content.character(at: bodyStart + hashes)) {
                oldPrefix = hashes
                while bodyStart + oldPrefix < content.length, [0x20, 0x09].contains(content.character(at: bodyStart + oldPrefix)) { oldPrefix += 1 }
            }
            let body = content.substring(from: bodyStart + oldPrefix)
            let blank = body.trimmingCharacters(in: .whitespaces).isEmpty && oldPrefix == 0
            let newPrefix = blank || level == 0 ? "" : String(repeating: "#", count: level) + " "
            let delta = (newPrefix as NSString).length - oldPrefix
            let prefixStart = offset + bodyStart
            let prefixEnd = prefixStart + oldPrefix
            // Where an offset in this line lands: before the old heading marker it
            // only shifts with earlier lines; inside it, it moves to the body's start.
            func map(_ position: Int) -> Int {
                if position < prefixStart { return position + cumulative }
                if position < prefixEnd { return prefixStart + cumulative + (newPrefix as NSString).length }
                return position + cumulative + delta
            }
            if newStart == nil, selection.location < offset + lineLength { newStart = map(selection.location) }
            if newEnd == nil, NSMaxRange(selection) <= offset + content.length { newEnd = map(NSMaxRange(selection)) }
            rebuilt += content.substring(to: bodyStart) + newPrefix + body + line.terminator
            cumulative += delta
            offset += lineLength
        }
        guard rebuilt != text.substring(with: span) else { return nil }
        let start = newStart ?? selection.location + cumulative
        let end = max(start, newEnd ?? NSMaxRange(selection) + cumulative)
        return MarkdownSourceEdit(range: span, replacement: rebuilt, selection: NSRange(location: start, length: end - start))
    }

    /// Indent (`outdent == false`) or outdent every list line the selection
    /// touches by one level (a tab in, a tab or two spaces out).
    static func indentListItems(outdent: Bool, in text: NSString, selection: NSRange) -> MarkdownSourceEdit? {
        let span = lineSpan(of: selection, in: text)
        let lines = splitLines(text.substring(with: span))
        var rebuilt = ""
        var shiftStart = 0
        var shiftTotal = 0
        var offset = span.location
        for (index, line) in lines.enumerated() {
            let body = splitIndent(line.content).body
            let isItem = taskMarkerLength(body) != nil || body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ")
                || numberMarkerLength(body) != nil
            var content = line.content
            var delta = 0
            if isItem {
                if !outdent {
                    content = "\t" + content
                    delta = 1
                } else if content.hasPrefix("\t") {
                    content.removeFirst()
                    delta = -1
                } else {
                    let spaces = min(2, content.prefix { $0 == " " }.count)
                    content.removeFirst(spaces)
                    delta = -spaces
                }
            }
            if index == 0 || offset <= selection.location { shiftStart = shiftTotal + (selection.location > offset ? delta : 0) }
            shiftTotal += delta
            rebuilt += content + line.terminator
            offset += (line.content as NSString).length + (line.terminator as NSString).length
        }
        guard rebuilt != text.substring(with: span) else { return nil }
        let start = max(span.location, selection.location + shiftStart)
        return MarkdownSourceEdit(range: span, replacement: rebuilt,
                                  selection: NSRange(location: start, length: max(0, NSMaxRange(selection) + shiftTotal - start)))
    }

    /// The length of a line's list or quote marker (with its indent), before any heading.
    private static func leadingMarkerLength(_ line: String) -> Int {
        let (indent, body) = splitIndent(line)
        let indentLength = (indent as NSString).length
        if let task = taskMarkerLength(body) { return indentLength + task }
        if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") { return indentLength + 2 }
        if let number = numberMarkerLength(body) { return indentLength + number }
        if body.hasPrefix(">") {
            let quote = body.hasPrefix("> ") ? 2 : 1
            return indentLength + quote
        }
        return 0
    }

    // MARK: - Inline code

    /// Wraps the selection in backticks, or unwraps it when backticks of one
    /// run length sit right outside it. A multi-line selection toggles a
    /// fenced block around its lines. An empty selection inserts a pair.
    static func toggleCode(in text: NSString, selection: NSRange) -> MarkdownSourceEdit? {
        let selected = text.substring(with: selection)
        if selected.contains("\n") || selected.contains("\r") {
            return toggleFence(in: text, selection: selection)
        }
        if let unwrap = codeUnwrap(in: text, selection: selection) { return unwrap }
        let run = longestBacktickRun(in: selected) + 1
        let fence = String(repeating: "`", count: run)
        let pad = selected.hasPrefix("`") || selected.hasSuffix("`") ? " " : ""
        let replacement = fence + pad + selected + pad + fence
        let start = selection.location + run + pad.utf16.count
        return MarkdownSourceEdit(range: selection, replacement: replacement,
                                  selection: NSRange(location: start, length: selection.length))
    }

    private static func codeUnwrap(in text: NSString, selection: NSRange) -> MarkdownSourceEdit? {
        guard selection.length > 0 else { return nil }
        var before = 0
        while selection.location - before > 0, text.character(at: selection.location - before - 1) == 0x60 { before += 1 }
        var after = 0
        while NSMaxRange(selection) + after < text.length, text.character(at: NSMaxRange(selection) + after) == 0x60 { after += 1 }
        guard before > 0, before == after else { return nil }
        let range = NSRange(location: selection.location - before, length: selection.length + 2 * before)
        return MarkdownSourceEdit(range: range, replacement: text.substring(with: selection),
                                  selection: NSRange(location: range.location, length: selection.length))
    }

    /// the reference editor's Insert table (doc 24 §5.1.5): an empty 3 × 3 table whose first
    /// row is the header, before the caret's line when the caret starts a
    /// non-empty line, else at the caret (splitting the line). Blank lines keep
    /// it a block of its own. The selection lands in the first header cell.
    static func insertTable(in text: NSString, selection: NSRange) -> MarkdownSourceEdit {
        let caret = NSMaxRange(selection)
        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        var contentsEnd = 0
        text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: caret, length: 0))
        let lineIsBlank = text.substring(with: NSRange(location: line.location, length: contentsEnd - line.location))
            .trimmingCharacters(in: .whitespaces).isEmpty
        let insertion = caret == line.location && !lineIsBlank ? line.location : caret
        let atLineStart = insertion == 0 || text.character(at: insertion - 1) == 0x0A
        let blankBefore = insertion == 0 || (atLineStart && (insertion < 2 || text.character(at: insertion - 2) == 0x0A))
        let leading = blankBefore ? "" : (atLineStart ? "\n" : "\n\n")
        let trailing = insertion >= text.length ? "" : (text.character(at: insertion) == 0x0A ? "\n" : "\n\n")
        let table = "|  |  |  |\n| --- | --- | --- |\n|  |  |  |\n|  |  |  |"
        let firstCell = insertion + (leading as NSString).length + 2
        return MarkdownSourceEdit(range: NSRange(location: insertion, length: 0), replacement: leading + table + trailing,
                                  selection: NSRange(location: firstCell, length: 0))
    }

    /// A divider (`---`) as a block of its own after the caret's line.
    static func insertDivider(in text: NSString, selection: NSRange) -> MarkdownSourceEdit {
        let caret = NSMaxRange(selection)
        var contentsEnd = 0
        text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: caret, length: 0))
        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        let blank = text.substring(with: NSRange(location: line.location, length: contentsEnd - line.location))
            .trimmingCharacters(in: .whitespaces).isEmpty
        if blank {
            return MarkdownSourceEdit(range: NSRange(location: line.location, length: contentsEnd - line.location),
                                      replacement: "---", selection: NSRange(location: line.location + 3, length: 0))
        }
        let replacement = "\n\n---\n"
        return MarkdownSourceEdit(range: NSRange(location: contentsEnd, length: 0), replacement: replacement,
                                  selection: NSRange(location: contentsEnd + (replacement as NSString).length, length: 0))
    }

    /// Toggles a fenced code block around the selected lines (the reference editor's ⌥⌘C).
    static func toggleCodeBlock(in text: NSString, selection: NSRange) -> MarkdownSourceEdit? {
        toggleFence(in: text, selection: selection)
    }

    /// `[ ]` ↔ `[x]` on every checklist line the selection touches (the reference editor's ⌘Return).
    static func toggleTaskChecked(in text: NSString, selection: NSRange) -> MarkdownSourceEdit? {
        let span = lineSpan(of: selection, in: text)
        let lines = splitLines(text.substring(with: span))
        var changed = false
        let rebuilt = lines.map { line -> String in
            let (indent, body) = splitIndent(line.content)
            guard taskMarkerLength(body) != nil else { return line.content + line.terminator }
            changed = true
            var units = Array(body.utf16)
            units[3] = units[3] == 0x20 ? 0x78 : 0x20
            return indent + String(decoding: units, as: UTF16.self) + line.terminator
        }.joined()
        guard changed else { return nil }
        return MarkdownSourceEdit(range: span, replacement: rebuilt, selection: selection)
    }

    private static func toggleFence(in text: NSString, selection: NSRange) -> MarkdownSourceEdit? {
        let span = lineSpan(of: selection, in: text)
        let lines = splitLines(text.substring(with: span))
        guard let first = lines.first, let last = lines.last else { return nil }
        let opensFence = first.content.trimmingCharacters(in: .whitespaces).hasPrefix("```")
        let closesFence = last.content.trimmingCharacters(in: .whitespaces) == "```"
        if lines.count >= 2, opensFence, closesFence {
            // Unwrap: the inner lines keep their breaks; the last one takes the
            // closing fence's, so the text after the block stays where it was.
            var inner = lines.dropFirst().dropLast().map { $0.content + $0.terminator }
            if !inner.isEmpty { inner[inner.count - 1] = lines[lines.count - 2].content + last.terminator }
            let rebuilt = inner.joined()
            return MarkdownSourceEdit(range: span, replacement: rebuilt,
                                      selection: contentSelection(of: rebuilt, at: span.location))
        }
        let body = lines.map(\.content).joined(separator: "\n")
        let rebuilt = "```\n" + body + "\n```" + last.terminator
        return MarkdownSourceEdit(range: span, replacement: rebuilt,
                                  selection: NSRange(location: span.location + 4, length: (body as NSString).length))
    }

    private static func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }

    // MARK: - Link

    /// ⌘K: `[selection]()` with the caret in the destination, `[](url)` with
    /// the caret in the text when the selection is a URL, `[]()` otherwise.
    static func insertLink(in text: NSString, selection: NSRange) -> MarkdownSourceEdit {
        let selected = text.substring(with: selection)
        if isURL(selected) {
            return MarkdownSourceEdit(range: selection, replacement: "[](\(selected))",
                                      selection: NSRange(location: selection.location + 1, length: 0))
        }
        let caret = selection.location + 1 + selection.length + 2
        return MarkdownSourceEdit(range: selection, replacement: "[\(selected)]()",
                                  selection: NSRange(location: selected.isEmpty ? selection.location + 1 : caret, length: 0))
    }

    private static func isURL(_ text: String) -> Bool {
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return false }
        let lower = text.lowercased()
        return lower.contains("://") || lower.hasPrefix("www.") || lower.hasPrefix("mailto:")
    }

    // MARK: - Lines

    private struct Line {
        let content: String
        let terminator: String
    }

    /// The full lines the selection touches; a selection ending at a line start
    /// does not take that line.
    private static func lineSpan(of selection: NSRange, in text: NSString) -> NSRange {
        var probe = selection
        if probe.length > 0, NSMaxRange(probe) <= text.length {
            let lastLine = text.lineRange(for: NSRange(location: NSMaxRange(probe), length: 0))
            if lastLine.location == NSMaxRange(probe) { probe.length -= 1 }
        }
        return text.lineRange(for: probe)
    }

    private static func splitLines(_ span: String) -> [Line] {
        let source = span as NSString
        guard source.length > 0 else { return [Line(content: "", terminator: "")] }
        var lines: [Line] = []
        var location = 0
        while location < source.length {
            var end = 0
            var contentsEnd = 0
            source.getLineStart(nil, end: &end, contentsEnd: &contentsEnd,
                                for: NSRange(location: location, length: 0))
            lines.append(Line(content: source.substring(with: NSRange(location: location, length: contentsEnd - location)),
                              terminator: source.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd))))
            location = end
        }
        return lines
    }

    /// Selects the rebuilt text without its final line terminator.
    private static func contentSelection(of rebuilt: String, at location: Int) -> NSRange {
        var length = (rebuilt as NSString).length
        if rebuilt.hasSuffix("\r\n") { length -= 2 } else if rebuilt.hasSuffix("\n") || rebuilt.hasSuffix("\r") { length -= 1 }
        return NSRange(location: location, length: max(0, length))
    }
}
