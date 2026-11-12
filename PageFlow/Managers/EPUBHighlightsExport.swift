//
//  EPUBHighlightsExport.swift
//  PageFlow
//
//  A book's highlights and notes as Markdown: the title and author, then
//  each chapter's highlights in reading order as a quote, its page and its
//  note. Saved to a file (Export Highlights…) or opened as a new untitled
//  Markdown tab.
//

import AppKit
import EPUBKit
import SwiftUI

enum EPUBHighlightsExport {
    /// One highlight as the export writes it.
    struct Entry: Equatable {
        var chapter: Int
        /// The highlighted words, paragraph breaks kept.
        var text: String
        /// One-based; nil when unknown.
        var page: Int?
        var note: String?
    }

    /// The Markdown for a book's highlights, grouped under their chapters.
    nonisolated static func markdown(title: String, authors: [String], chapterTitles: [String],
                                     entries: [Entry]) -> String {
        var lines = ["# \(escaped(title.isEmpty ? "Untitled Book" : title))", ""]
        if !authors.isEmpty {
            lines += ["by \(escaped(authors.joined(separator: ", ")))", ""]
        }
        var chapter: Int?
        for entry in entries {
            if entry.chapter != chapter {
                chapter = entry.chapter
                let heading = chapterTitles.indices.contains(entry.chapter) ? chapterTitles[entry.chapter] : ""
                lines += ["## \(escaped(heading.isEmpty ? "Section \(entry.chapter + 1)" : heading))", ""]
            }
            let paragraphs = entry.text.components(separatedBy: .newlines)
                .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            // Blank lines inside the quote stay in it, as ">".
            let quote = paragraphs.drop { $0.isEmpty }.reversed().drop { $0.isEmpty }.reversed()
            lines += quote.map { $0.isEmpty ? ">" : "> \(escaped($0))" }
            lines.append("")
            if let page = entry.page { lines += ["Page \(page)", ""] }
            if let note = entry.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                lines += noteLines(note) + [""]
            }
        }
        if entries.isEmpty { lines += ["No highlights yet.", ""] }
        return lines.joined(separator: "\n")
    }

    /// A note is plain text, as typed: its line breaks stay, and nothing in it
    /// (an unclosed code fence, a "# heading") can change the export around it.
    nonisolated private static func noteLines(_ note: String) -> [String] {
        let lines = note.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.indices.map { index in
            guard !lines[index].isEmpty else { return "" }
            let continues = lines.indices.contains(index + 1) && !lines[index + 1].isEmpty
            return escaped(lines[index]) + (continues ? "  " : "")
        }
    }

    /// Book text read as plain text, not Markdown: marks that would format
    /// it are escaped, as is anything that would start a block.
    nonisolated static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\`*_[]<>~=$".contains(character) { result.append("\\") }
            result.append(character)
        }
        if let first = result.first, "#+-|".contains(first) { result.insert("\\", at: result.startIndex) }
        // "1. Words" and "1) Words" would start a numbered list.
        if let dot = result.firstIndex(where: { $0 == "." || $0 == ")" }), dot != result.startIndex,
           result[..<dot].allSatisfy(\.isNumber) { result.insert("\\", at: dot) }
        return result
    }

    /// A file name for the export: the book's title, without path separators.
    nonisolated static func fileName(forTitle title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(cleaned.isEmpty ? "Book" : cleaned) Highlights.md"
    }
}

extension EPUBHighlightsExport {
    /// The book's highlights as Markdown, as whole passages: chapters not in
    /// memory are styled first. Pages are left out until the book is fully
    /// paginated, since a page number before then could be wrong.
    @MainActor
    static func markdown(for content: EPUBContent) async -> String {
        var texts: [Int: NSString] = [:]
        for chapter in Set(content.highlights.items.map(\.chapterIndex)) {
            texts[chapter] = await content.styledChapter(chapter)?.text.string as NSString?
        }
        let hasPages = content.book != nil && content.pagination.isComplete
        let entries = content.highlights.items.map { highlight in
            Entry(chapter: highlight.chapterIndex, text: passage(of: highlight, in: texts[highlight.chapterIndex]),
                  page: hasPages && !content.pagination.isExcluded(highlight.chapterIndex) ? content.page(of: highlight) + 1 : nil,
                  note: highlight.hasNote ? highlight.note : nil)
        }
        return markdown(title: content.documentTitle, authors: content.book?.authors ?? [],
                        chapterTitles: content.book?.chapters.map(\.title) ?? [], entries: entries)
    }

    private static func passage(of highlight: EPUBHighlight, in text: NSString?) -> String {
        guard let text, NSMaxRange(highlight.range) <= text.length else { return highlight.excerpt }
        // Images are attachment characters; they have no words.
        return text.substring(with: highlight.range).replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    /// Export Highlights…: a save panel, then the Markdown file.
    @MainActor
    static func save(_ content: EPUBContent) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = MarkdownSavePanel.allowedContentTypes
        panel.nameFieldStringValue = fileName(forTitle: content.documentTitle)
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try await markdown(for: content).write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t export the highlights: \(error.localizedDescription)"
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    /// Opens the Markdown as a new untitled note, unsaved until the reader saves it.
    @MainActor
    static func openInNewTab(_ content: EPUBContent, tabManager: TabManager) async {
        let markdown = await markdown(for: content)
        tabManager.newMarkdownDocument()
        tabManager.activeSession?.content.markdown?.documentManager.text = markdown
    }
}

/// The sidebar's export actions, handed down by the tab, which knows its window.
struct EPUBHighlightsExportActions {
    // SwiftUI can cache the sidebar environment after the book closes.
    weak var content: EPUBContent?
    weak var tabManager: TabManager?

    @MainActor func save() {
        guard let content else { return }
        EPUBHighlightsExport.save(content)
    }

    @MainActor func openInNewTab() {
        guard let content, let tabManager else { return }
        Task { await EPUBHighlightsExport.openInNewTab(content, tabManager: tabManager) }
    }
}

extension EnvironmentValues {
    @Entry var epubHighlightsExport: EPUBHighlightsExportActions?
}

/// The Highlights sidebar's export menu.
struct EPUBHighlightsExportMenu: View {
    let actions: EPUBHighlightsExportActions
    let isEnabled: Bool

    var body: some View {
        Menu {
            Button("Export Highlights…", action: actions.save)
            Button("Open Highlights in New Tab", action: actions.openInNewTab)
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: DesignTokens.sidebarToggleIconSize))
                .foregroundStyle(.primary)
                .frame(width: DesignTokens.sidebarToggleButtonSize, height: DesignTokens.sidebarToggleButtonSize)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pageFlowClickCursor()
        .disabled(!isEnabled)
        .help("Export highlights and notes as Markdown")
        .accessibilityLabel("Export Highlights")
    }
}
