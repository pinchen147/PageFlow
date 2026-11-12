//
//  NativeTextView+PasteHandling.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//

import AppKit
import UniformTypeIdentifiers

extension NativeTextView {
    private static let pastableTextExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "txt", "text"
    ]

    override func copy(_ sender: Any?) {
        if !copySelectedMarkdownBlock(to: .general),
           (delegate as? NativeTextViewCoordinator)?.copyEmphasisSelection(in: self, to: .general) != true { super.copy(sender) }
    }

    override func cut(_ sender: Any?) {
        if !cutSelection(to: .general) { super.cut(sender) }
    }

    /// Refusal is handled; ordinary native Cut remains the caller's fallback.
    func cutSelection(to board: NSPasteboard) -> Bool {
        guard isEditable, !hasMarkedText() else { return true }
        guard (delegate as? NativeTextViewCoordinator)?.admitFoldedEdit(selectedRange(), in: self) != false else { return true }
        if copySelectedMarkdownBlock(to: board), let coordinator = delegate as? NativeTextViewCoordinator {
            _ = coordinator.replaceSourceRanges([selectedRange()], with: "", expectedSource: string, actionName: "Cut")
            return true
        } else if let coordinator = delegate as? NativeTextViewCoordinator,
                  coordinator.copyEmphasisSelection(in: self, to: board) {
            return coordinator.applyEmphasisInput("", range: selectedRange(), in: self)
        }
        return false
    }

    func copySelectedMarkdownBlock(to pasteboard: NSPasteboard) -> Bool {
        guard let coordinator = delegate as? NativeTextViewCoordinator,
              let object = coordinator.objectSelection, selectedRange() == object.token,
              let payload = coordinator.blockMovePayload(range: object.token, kind: .image) else { return false }
        let item = NSPasteboardItem()
        payload.write(to: item)
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    override func paste(_ sender: Any?) {
        guard isEditable, !hasMarkedText() else { return }
        if !paste(from: .general) { pasteAsPlainText(sender) }
    }

    /// Reads a paste representation and inserts it through the native edit transaction.
    func paste(from pasteboard: NSPasteboard) -> Bool {
        guard isEditable, !hasMarkedText() else { return false }

        guard (delegate as? NativeTextViewCoordinator)?.admitFoldedEdit(selectedRange(), in: self) != false else { return true }
        if (delegate as? NativeTextViewCoordinator)?.pasteMarkdownBlock(from: pasteboard) == true { return true }

        // A spreadsheet's grid (its HTML table first, else tab-separated text)
        // becomes a Markdown table on its own lines (owner decision, PR D),
        // before the picture of the cells a spreadsheet also puts there.
        if pastesTablesHere(), let table = TableClipboard.proseTable(from: pasteboard) {
            insertLiteralText(blockSeparated(table))
            return true
        }

        if let imageEmbed = onPasteImage?(pasteboard), !imageEmbed.isEmpty {
            insertBlockEmbed(imageEmbed)
            return true
        }

        // Plain text is the source representation, including whitespace and an
        // empty replacement. Rich clipboard data must not override it.
        if let plain = pasteboard.string(forType: .string) {
            insertLiteralText(plain)
            return true
        }

        if let html = pasteboard.string(forType: .html),
           html.range(of: "<table", options: .caseInsensitive) != nil,
           let markdownTable = Self.htmlTableToMarkdown(html) {
            insertLiteralText(markdownTable)
            return true
        }

        if let fileText = textFromPastedFileURL(pasteboard: pasteboard) {
            insertLiteralText(fileText)
            return true
        }

        return false
    }

    /// A pasted grid is a table only in prose: inside a code block or a
    /// table's revealed source it is the text it says.
    private func pastesTablesHere() -> Bool {
        guard let coordinator = delegate as? NativeTextViewCoordinator else { return true }
        let location = selectedRange().location
        return !coordinator.parsedDocument(for: string).tokens.contains {
            ($0.kind == .codeBlock || $0.kind == .table) && $0.range.location < location && location < NSMaxRange($0.range)
        }
    }

    /// `block` with the line breaks that put it on its own lines, a blank
    /// line away from the text around the selection.
    private func blockSeparated(_ block: String) -> String {
        let text = string as NSString
        let selection = selectedRange()
        func isNewline(_ index: Int) -> Bool { [0x0A, 0x0D].contains(text.character(at: index)) }
        var prefix = ""
        if selection.location > 0 {
            if !isNewline(selection.location - 1) {
                prefix = "\n\n"
            } else if selection.location > 1, !isNewline(selection.location - 2) {
                prefix = "\n"
            }
        }
        var suffix = ""
        let end = NSMaxRange(selection)
        if end < text.length {
            if !isNewline(end) {
                suffix = "\n\n"
            } else {
                let crlf = text.character(at: end) == 0x0D && end + 1 < text.length && text.character(at: end + 1) == 0x0A
                let next = end + (crlf ? 2 : 1)
                if next < text.length, !isNewline(next) { suffix = "\n" }
            }
        }
        return prefix + block + suffix
    }

    private func insertLiteralText(_ text: String) {
        let coordinator = delegate as? NativeTextViewCoordinator
        let previous = coordinator?.isLiteralInsertion ?? false
        coordinator?.isLiteralInsertion = true
        defer { coordinator?.isLiteralInsertion = previous }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        insertText(normalized, replacementRange: selectedRange())
    }

    /// AppKit's own pasteboard reader (Services, Paste and Match Style). The
    /// host's image hook gets the first look at files, exactly as for a
    /// paste, so an image file becomes a rendering image link instead of its
    /// path as plain text. Dropped files never come here: the note routes
    /// every file drag itself (`NativeTextView+FileDrop`).
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard (delegate as? NativeTextViewCoordinator)?.admitFoldedEdit(selectedRange(), in: self) != false else { return true }
        // Files arrive under more than one type (the modern file URL and the
        // legacy filenames list); whichever AppKit picked, the pasteboard is
        // what the hook reads.
        if isEditable,
           pboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
           let embed = onPasteImage?(pboard), !embed.isEmpty {
            insertBlockEmbed(embed)
            return true
        }
        if type == .string, isEditable, !hasMarkedText(),
           let plain = pboard.string(forType: .string) {
            insertLiteralText(plain)
            return true
        }
        return super.readSelection(from: pboard, type: type)
    }

    /// Inserts an embed on its own line and leaves the caret on the line
    /// after it, so the block renders at once instead of sitting revealed
    /// under the caret.
    /// the reference editor's Insert block → Image: an image chosen in an open panel goes
    /// through the host's image hook, as a dropped image file does, and lands
    /// on its own line at `location`. `choose` stands in for the panel in tests.
    func insertImageFromPicker(at location: Int, choose: (() -> URL?)? = nil) {
        guard isEditable, onPasteImage != nil else { return }
        let url = choose.map { $0() } ?? {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            return panel.runModal() == .OK ? panel.url : nil
        }()
        guard let url else { return }
        let board = NSPasteboard(name: NSPasteboard.Name("com.pageflow.image-pick.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.writeObjects([url as NSURL])
        guard let embed = onPasteImage?(board), !embed.isEmpty else { return }
        setSelectedRange(NSRange(location: min(location, (string as NSString).length), length: 0))
        insertBlockEmbed(embed)
    }

    private func insertBlockEmbed(_ embed: String) {
        let sel = selectedRange()
        let nsText = string as NSString
        var prefix = ""
        var suffix = ""
        if sel.location > 0, nsText.character(at: sel.location - 1) != 0x0A {
            prefix = "\n"
        }
        let afterLocation = sel.location + sel.length
        let newlineFollows = afterLocation < nsText.length && nsText.character(at: afterLocation) == 0x0A
        if !newlineFollows {
            suffix = "\n"
        }
        insertLiteralText(prefix + embed + suffix)
        if newlineFollows {
            let caret = sel.location + (prefix + embed).utf16.count + 1
            setSelectedRange(NSRange(location: min(caret, (string as NSString).length), length: 0))
        }
    }

    /// Reads the textual content of a pasted markdown/text file URL — the
    /// fallback that makes iOS Universal Clipboard pastes useful.
    private func textFromPastedFileURL(pasteboard: NSPasteboard) -> String? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        for url in urls where url.isFileURL {
            guard Self.pastableTextExtensions.contains(url.pathExtension.lowercased()) else { continue }
            if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
            if let s = try? String(contentsOf: url) { return s }
        }
        return nil
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) {
            let pasteboard = NSPasteboard.general
            if PasteboardImageReader.canPasteImage(from: pasteboard) { return true }
            if textFromPastedFileURL(pasteboard: pasteboard) != nil { return true }
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: - HTML table → Markdown table

    private static let trRegex = try! NSRegularExpression(
        pattern: #"<tr\b[^>]*>(.*?)</tr>"#,
        options: [.dotMatchesLineSeparators, .caseInsensitive]
    )
    private static let cellRegex = try! NSRegularExpression(
        pattern: #"<t[hd]\b[^>]*>(.*?)</t[hd]>"#,
        options: [.dotMatchesLineSeparators, .caseInsensitive]
    )
    private static let tagStripRegex = try! NSRegularExpression(
        pattern: #"<[^>]+>"#
    )

    /// First `<table>` in `html` → CommonMark pipe-table; nil if no table.
    static func htmlTableToMarkdown(_ html: String) -> String? {
        guard html.range(of: "<table", options: .caseInsensitive) != nil else { return nil }
        let nsHtml = html as NSString
        let trMatches = trRegex.matches(in: html, range: NSRange(location: 0, length: nsHtml.length))
        guard !trMatches.isEmpty else { return nil }

        var rows: [[String]] = []
        for trMatch in trMatches {
            let trContent = nsHtml.substring(with: trMatch.range(at: 1))
            let nsTr = trContent as NSString
            let cellMatches = cellRegex.matches(in: trContent, range: NSRange(location: 0, length: nsTr.length))
            var cells: [String] = []
            for cellMatch in cellMatches {
                let raw = nsTr.substring(with: cellMatch.range(at: 1))
                let nsRaw = raw as NSString
                let stripped = tagStripRegex.stringByReplacingMatches(
                    in: raw, range: NSRange(location: 0, length: nsRaw.length), withTemplate: ""
                )
                let decoded = decodeHTMLEntities(stripped)
                    .replacingOccurrences(of: "|", with: #"\|"#)
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cells.append(decoded)
            }
            if !cells.isEmpty { rows.append(cells) }
        }
        guard !rows.isEmpty else { return nil }

        let columnCount = rows.map(\.count).max() ?? 0
        guard columnCount > 0 else { return nil }
        func pad(_ row: [String]) -> [String] {
            row + Array(repeating: "", count: max(0, columnCount - row.count))
        }

        var lines: [String] = []
        lines.append("| " + pad(rows[0]).joined(separator: " | ") + " |")
        lines.append("|" + Array(repeating: "---", count: columnCount).joined(separator: "|") + "|")
        for row in rows.dropFirst() {
            lines.append("| " + pad(row).joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    private static func decodeHTMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
