//
//  MarkdownChrome.swift
//  PageFlow
//
//  S7b (shared-chrome stage, chrome half): the PURE, content-aware chrome logic
//  shared by PDF and Markdown tabs. Everything here is a value type with no view,
//  no AppKit window, and no engine dependency, so the tab icon, format-command
//  vocabulary, markdown outline, and word count are all unit-testable in isolation
//  (the `MarkdownChromeTests` suite drives these directly).
//
//  The markdown chrome renders through the SHARED shells: the format toolbar via
//  `GlassToolbarShell` (built from `MarkdownFormatCommand.allCases`) and the
//  outline via `GlassSidebarShell` (hosted by `MarkdownOutlineSidebar`).
//  `ContentKind` drives the shared tab pill's per-content icon (`TabItemView`).
//

import Foundation

// MARK: - Content kind

/// The content type a tab renders, derived from `TabContent`. Distinct from
/// `TabContent` itself (which carries the live backends) so the chrome layer can
/// branch on a tiny `Equatable`/`Sendable` value without reaching the managers.
/// Exhaustive switches over this — never a default — so a new content type forces
/// every chrome site to choose its icon / toolbar set / sidebar.
enum ContentKind: Equatable, Sendable {
    case pdf
    case markdown

    /// The SF Symbol shown on the tab pill so mixed PDF + Markdown tabs are
    /// visually distinguishable.
    var tabIconSystemName: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .markdown: return "text.alignleft"
        }
    }
}

// MARK: - Markdown format commands

/// The Markdown format commands (D11), shared by the Format menu and the
/// floating toolbar. Each applies to the live selection as one undoable edit
/// through the tab's editor controller.
enum MarkdownFormatCommand: String, CaseIterable, Identifiable, Sendable {
    case bold
    case italic
    case underline
    case strikethrough
    case code
    case highlight
    case link
    case text
    case heading
    case heading2
    case heading3
    case bulletedList
    case numberedList
    case checklist
    case quote
    case codeBlock
    case divider
    case table

    var id: String { rawValue }

    /// Commands that change whole lines (styles, lists, blocks), not text runs.
    var isBlock: Bool {
        switch self {
        case .bold, .italic, .underline, .strikethrough, .code, .highlight, .link: return false
        case .text, .heading, .heading2, .heading3, .bulletedList, .numberedList, .checklist, .quote,
             .codeBlock, .divider, .table: return true
        }
    }

    /// The window toolbar's set (the reference editor's host toolbar, doc 24 §6.12):
    /// Table and Checklist; the marks live on the selection bar.
    static let toolbar: [MarkdownFormatCommand] = [.table, .checklist]

    /// The toolbar's Insert ▾ rows, in the reference editor's order.
    static let insertMenu: [MarkdownFormatCommand] = [.bulletedList, .checklist, .codeBlock, .divider, .heading, .heading2,
                                                      .heading3, .numberedList, .quote]

    var title: String {
        switch self {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .underline: return "Underline"
        case .strikethrough: return "Strikethrough"
        case .code: return "Code"
        case .highlight: return "Highlight"
        case .link: return "Link"
        case .text: return "Text"
        case .heading: return "Heading 1"
        case .heading2: return "Heading 2"
        case .heading3: return "Heading 3"
        case .bulletedList: return "Bulleted List"
        case .numberedList: return "Numbered List"
        case .checklist: return "Checklist"
        case .quote: return "Quote"
        case .codeBlock: return "Code Block"
        case .divider: return "Divider"
        case .table: return "Table"
        }
    }

    /// SF Symbol for the toolbar button.
    var iconSystemName: String {
        switch self {
        case .bold: return "bold"
        case .italic: return "italic"
        case .underline: return "underline"
        case .strikethrough: return "strikethrough"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .highlight: return "highlighter"
        case .link: return "link"
        case .text: return "textformat"
        case .heading: return "textformat.size"
        case .heading2, .heading3: return "textformat.size.smaller"
        case .bulletedList: return "list.bullet"
        case .numberedList: return "list.number"
        case .checklist: return "checklist"
        case .quote: return "text.quote"
        case .codeBlock: return "curlybraces.square"
        case .divider: return "minus"
        case .table: return "tablecells"
        }
    }

    /// The Format menu's key equivalent. `nil` for Code (none) and Underline,
    /// whose ⌘U belongs to Annotate ▸ Underline and routes here on Markdown tabs.
    /// Its Settings row (`ShortcutCatalog`): the Format menu and the focused editor share it.
    var shortcutID: String { "format.\(rawValue)" }

    /// The key the Format menu shows and the editor answers, if any.
    var menuShortcut: ShortcutModel? {
        let shortcut = ShortcutModel.current(for: shortcutID)
        return shortcut.isNone ? nil : shortcut
    }

    /// Hover-help / accessibility text, with the shortcut that triggers it.
    var help: String {
        guard let label = menuShortcut?.displayString else { return title }
        return "\(title) (\(label))"
    }
}

// MARK: - Markdown navigation trail

/// The Markdown side of Go Back/Forward (⌘[ / ⌘]) — a pure two-stack trail of
/// positions, the peer of the PDF view's page-navigation history. A jump
/// (outline click, Go to Line) records the departure position; going back pushes
/// the current position onto the forward stack, so the trail walks both ways.
/// New jumps clear the forward stack (browser semantics). The Markdown tab stores
/// text locations (ADR-0021), so zoom and reflow never strand an entry.
struct MarkdownNavigationTrail<Position: Equatable & Sendable>: Equatable, Sendable {
    /// Oldest-first; a runaway jump session prunes from the front.
    private(set) var backStack: [Position] = []
    private(set) var forwardStack: [Position] = []

    private static var capacity: Int { 100 }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    mutating func recordJump(from position: Position) {
        backStack.append(position)
        if backStack.count > Self.capacity {
            backStack.removeFirst(backStack.count - Self.capacity)
        }
        forwardStack.removeAll()
    }

    mutating func goBack(from current: Position) -> Position? {
        guard let target = backStack.popLast() else { return nil }
        forwardStack.append(current)
        return target
    }

    mutating func goForward(from current: Position) -> Position? {
        guard let target = forwardStack.popLast() else { return nil }
        backStack.append(current)
        return target
    }
}

// MARK: - Markdown outline

/// One heading in a markdown document's lightweight outline — the sidebar entry
/// for a Markdown tab (peer of the PDF `OutlineItem`). `level` is the ATX depth
/// (1 = `#` … 6 = `######`); `lineIndex` is the 0-based source line a click
/// scrolls to (`MarkdownContent.scrollToOutlineItem` via `lineStartLocation`).
struct MarkdownOutlineItem: Identifiable, Equatable, Sendable {
    let id: Int          // stable within one parse (the heading's ordinal)
    let title: String
    let level: Int
    let lineIndex: Int
}

/// Pure markdown heading extraction for the sidebar outline. Scans `#`..`######`
/// ATX headings, ignoring `#` that appear inside fenced code blocks (``` or ~~~)
/// so a `# comment` inside a shell snippet never becomes a fake outline entry.
nonisolated enum MarkdownOutline {
    /// UTF-16 location where the zero-based source line starts. Markdown
    /// lines use LF, CRLF or CR, including a final empty line after a terminator.
    static func lineStartLocation(ofLine lineIndex: Int, in text: String) -> Int? {
        let source = text as NSString
        guard lineIndex >= 0, source.length > 0 else { return nil }
        if lineIndex == 0 { return 0 }
        var location: Int?
        enumerateSourceLines(source) { index, _, nextStart in
            guard index + 1 != lineIndex else { location = nextStart; return false }
            return true
        }
        return location
    }

    static func lineCount(in text: String) -> Int {
        var count = 0
        enumerateSourceLines(text as NSString) { _, _, _ in count += 1; return true }
        return count
    }

    /// Visits source content ranges without allocating substrings or a line
    /// array. The next start permits navigation to stop before scanning the
    /// requested line's contents; nil identifies the final line at EOF.
    private static func enumerateSourceLines(_ source: NSString, shouldCancel: () -> Bool = { false }, visit: (Int, NSRange, Int?) -> Bool) {
        let length = source.length
        var buffer = [UInt16](repeating: 0, count: 4096)
        var bufferStart = 0
        var bufferLength = 0
        func unit(at offset: Int) -> UInt16 {
            if offset < bufferStart || offset >= bufferStart + bufferLength {
                bufferStart = offset
                bufferLength = min(buffer.count, length - offset)
                source.getCharacters(&buffer, range: NSRange(location: offset, length: bufferLength))
            }
            return buffer[offset - bufferStart]
        }
        var start = 0
        var offset = 0
        var index = 0
        var nextCancellationCheck = 0
        while offset < length {
            if offset >= nextCancellationCheck {
                guard !shouldCancel() else { return }
                nextCancellationCheck = offset + 4096
            }
            let current = unit(at: offset)
            guard current == 0x0A || current == 0x0D else { offset += 1; continue }
            let range = NSRange(location: start, length: offset - start)
            if current == 0x0D, offset + 1 < length, unit(at: offset + 1) == 0x0A {
                offset += 1
            }
            offset += 1
            guard visit(index, range, offset) else { return }
            start = offset
            index += 1
        }
        _ = visit(index, NSRange(location: start, length: length - start), nil)
    }

    /// Parses `text` into outline items in document order. A heading is a line
    /// whose first non-space run is 1–6 `#` followed by a space (or end of line),
    /// outside any fenced code block. Setext headings (=== / ---) are not parsed
    /// in v1 — noted as a deferral.
    static func parse(_ text: String) -> [MarkdownOutlineItem] {
        parse(text, shouldCancel: { false })!
    }

    static func parse(_ text: String, shouldCancel: () -> Bool) -> [MarkdownOutlineItem]? {
        var items: [MarkdownOutlineItem] = []
        var ordinal = 0
        var inFence = false
        var fenceMarker: Character = "`"   // which marker opened the current fence

        let source = text as NSString
        guard !shouldCancel() else { return nil }
        enumerateSourceLines(source, shouldCancel: shouldCancel) { lineIndex, range, _ in
            // Only a heading (`#`) or a fence (`` ` `` / `~`) matters; skip every
            // other line before allocating its text.
            var start = range.location
            while start < NSMaxRange(range), [0x20, 0x09].contains(source.character(at: start)) {
                if (start - range.location).isMultiple(of: 4096), shouldCancel() { return false }
                start += 1
            }
            guard start < NSMaxRange(range), [0x23, 0x60, 0x7E].contains(source.character(at: start)) else { return true }
            let line = source.substring(with: range)
            let trimmed = line.drop { $0 == " " || $0 == "\t" }

            // Fence toggling: a line that starts with ``` or ~~~ opens/closes a
            // code block. The close must use the same marker that opened it.
            if let marker = fenceOpener(trimmed) {
                if inFence {
                    if marker == fenceMarker { inFence = false }
                } else {
                    inFence = true
                    fenceMarker = marker
                }
                return true
            }
            if inFence { return true }

            guard let heading = headingTitleAndLevel(trimmed) else { return true }
            items.append(
                MarkdownOutlineItem(
                    id: ordinal,
                    title: heading.title,
                    level: heading.level,
                    lineIndex: lineIndex
                )
            )
            ordinal += 1
            return true
        }
        return shouldCancel() ? nil : items
    }

    /// If `line` opens or closes a fence, returns the marker character (`` ` ``
    /// or `~`); else nil. A fence is at least three identical marker characters.
    private static func fenceOpener(_ line: Substring) -> Character? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let run = line.prefix { $0 == first }
        return run.count >= 3 ? first : nil
    }

    /// Parses an ATX heading from a leading-whitespace-trimmed line: 1–6 `#`
    /// then a space (or the line is only `#`s). Returns the trimmed title and
    /// level, or nil if the line is not a heading. The title has trailing closing
    /// `#` and surrounding whitespace stripped (`## Title ##` → `Title`).
    private static func headingTitleAndLevel(_ line: Substring) -> (title: String, level: Int)? {
        let hashes = line.prefix { $0 == "#" }
        let level = hashes.count
        guard level >= 1, level <= 6 else { return nil }

        let afterHashes = line.dropFirst(level)
        // Require a space after the hashes, unless the line is hashes-only.
        guard afterHashes.isEmpty || afterHashes.first == " " || afterHashes.first == "\t" else {
            return nil
        }

        var title = afterHashes.trimmingCharacters(in: .whitespaces)
        // Strip an ATX closing-hash run (`## Foo ##` → `Foo`), but ONLY when it is
        // whitespace-preceded (a CommonMark closing sequence). A `#` fused to the
        // word (`# C#` → `C#`) is part of the title, not a closing sequence.
        let trailingHashes = title.reversed().prefix { $0 == "#" }.count
        if trailingHashes > 0 {
            let base = title.dropLast(trailingHashes)
            if base.isEmpty || base.last == " " || base.last == "\t" {
                title = base.trimmingCharacters(in: .whitespaces)
            }
        }
        return (title, level)
    }
}

// MARK: - Word count

/// Words + characters for the Markdown bottom-bar chip. Pure so the count is
/// unit-testable; the chip view just formats `WordCount`.
nonisolated struct WordCount: Equatable, Sendable {
    let words: Int
    let characters: Int

    /// Counts whitespace-delimited words and total characters (Unicode grapheme
    /// clusters, so an emoji or combined glyph is one character). Empty and
    /// whitespace-only inputs are zero words; characters count every code point
    /// the user sees, including spaces and newlines.
    static func count(_ text: String) -> WordCount {
        count(text, shouldCancel: { false })!
    }

    static func count(_ text: String, shouldCancel: () -> Bool) -> WordCount? {
        guard !shouldCancel() else { return nil }
        var source = text
        // AppKit-backed strings transcode faster through Foundation's UTF-8
        // export than through Swift's foreign-string character traversal.
        if !source.isContiguousUTF8,
           let data = (source as NSString).data(using: String.Encoding.utf8.rawValue) {
            source = String(decoding: data, as: UTF8.self)
        } else {
            source.makeContiguousUTF8()
        }
        guard !shouldCancel() else { return nil }
        let bytes = Array(source.utf8)
        var offset = 0
        var words = 0
        var characters = 0
        var inWord = false
        var nextCancellationCheck = 0
        while offset < bytes.count {
            if offset >= nextCancellationCheck {
                guard !shouldCancel() else { return nil }
                nextCancellationCheck = offset + 4096
            }
            let byte = bytes[offset]
            let isWhitespace: Bool
            // Adjacent ASCII cannot combine, except CRLF. Before any non-ASCII
            // byte, let Swift consume the complete grapheme (including combining
            // marks, Prepend characters, keycaps and joined emoji).
            if byte < 0x80, offset + 1 == bytes.count || bytes[offset + 1] < 0x80 {
                isWhitespace = byte == 0x20 || (0x09...0x0D).contains(byte)
                offset += byte == 0x0D && offset + 1 < bytes.count && bytes[offset + 1] == 0x0A ? 2 : 1
            } else {
                let index = source.utf8.index(source.utf8.startIndex, offsetBy: offset)
                isWhitespace = source[index].isWhitespace
                offset = source.utf8.distance(from: source.utf8.startIndex, to: source.index(after: index))
            }
            characters += 1
            if isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                words += 1
            }
        }
        return shouldCancel() ? nil : WordCount(words: words, characters: characters)
    }

    /// Compact label for the chip, e.g. "128 words · 742 chars".
    var label: String {
        let w = words == 1 ? "word" : "words"
        let c = characters == 1 ? "char" : "chars"
        return "\(words) \(w) · \(characters) \(c)"
    }
}
