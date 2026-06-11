//
//  MarkdownExporter.swift
//  PageFlow
//
//  PDFKit adapter for PDF → Markdown conversion.
//

import PDFKit
import AppKit

/// The PDFKit adapter for Markdown export. It pulls a page's attributed text,
/// per-line positions, and link targets out of a live `PDFPage`, then hands them
/// to `MarkdownLayout` — the pure pipeline that holds the column/heading/
/// monospace/list heuristics. Keeping every live-PDFKit read here is what lets
/// those heuristics be unit-tested without a rendered PDF.
struct MarkdownExporter {

    // MARK: - Public API

    static func export(
        scope: ExportScope,
        document: PDFDocument,
        comments: [CommentModel] = []
    ) -> String {
        let range = scope.pageIndices(in: document)
        guard !range.isEmpty else { return "" }

        let commentsByPage = Dictionary(
            grouping: comments.filter { !$0.text.isEmpty },
            by: \.pageIndex
        )

        let pages = range.compactMap { index -> String? in
            guard let page = document.page(at: index) else { return nil }
            let pageComments = commentsByPage[index] ?? []
            let markdown = convertPageToMarkdown(page, comments: pageComments)
            return markdown.isEmpty ? nil : markdown
        }

        return pages.joined(separator: "\n\n---\n\n")
    }

    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Page Conversion

    private static func convertPageToMarkdown(_ page: PDFPage, comments: [CommentModel]) -> String {
        // Primary source: attributedString (includes formatting). Extract the
        // PDFKit-derived inputs here, then defer to the pure layout pipeline.
        if let attributedString = page.attributedString, attributedString.length > 0 {
            let pageWidth = page.bounds(for: .mediaBox).width
            return MarkdownLayout.convert(
                attributedString: attributedString,
                pageWidth: pageWidth,
                positionMap: buildPositionMap(for: page),
                links: extractLinks(from: page),
                comments: comments
            )
        }

        // Fallback: plain string with comments appended
        var result = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !comments.isEmpty {
            let commentText = comments.map { "> \($0.text)" }.joined(separator: "\n>\n")
            result += "\n\n" + commentText
        }
        return result
    }

    // MARK: - PDFKit Extraction

    /// Per-line geometry for the page, keyed by trimmed line text — the only
    /// PDFKit-derived input the column heuristic needs.
    private static func buildPositionMap(for page: PDFPage) -> [String: MarkdownLayout.LinePosition] {
        let pageBounds = page.bounds(for: .mediaBox)
        guard let selection = page.selection(for: pageBounds) else { return [:] }

        var positionMap: [String: MarkdownLayout.LinePosition] = [:]
        for lineSelection in selection.selectionsByLine() {
            guard let lineText = lineSelection.string else { continue }
            let trimmed = lineText.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let bounds = lineSelection.bounds(for: page)
            guard !bounds.isNull && !bounds.isEmpty else { continue }

            positionMap[trimmed] = MarkdownLayout.LinePosition(y: bounds.minY, centerX: bounds.midX, width: bounds.width)
        }
        return positionMap
    }

    private static func extractLinks(from page: PDFPage) -> [MarkdownLayout.Link] {
        var links: [MarkdownLayout.Link] = []

        for annotation in page.annotations {
            guard annotation.type == "Link",
                  let action = annotation.action as? PDFActionURL,
                  let url = action.url,
                  let selection = page.selection(for: annotation.bounds),
                  let text = selection.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            links.append(MarkdownLayout.Link(text: text.trimmingCharacters(in: .whitespacesAndNewlines), url: url))
        }
        return links
    }
}
