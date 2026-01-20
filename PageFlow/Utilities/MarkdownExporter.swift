//
//  MarkdownExporter.swift
//  PageFlow
//
//  Native PDF to Markdown conversion using PDFKit text extraction.
//

import PDFKit
import AppKit

struct MarkdownExporter {

    // MARK: - Public API

    static func export(
        scope: ExportScope,
        document: PDFDocument,
        comments: [CommentModel] = []
    ) -> String {
        let range = scope.pageIndices(in: document)
        guard !range.isEmpty else { return "" }

        let pages = range.compactMap { index -> String? in
            guard let page = document.page(at: index) else { return nil }
            let pageComments = comments.filter { $0.pageIndex == index && !$0.text.isEmpty }
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
        // Primary source: attributedString (includes formatting)
        if let attributedString = page.attributedString, attributedString.length > 0 {
            return convertAttributedString(attributedString, page: page, comments: comments)
        }

        // Fallback: plain string with comments appended
        var result = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !comments.isEmpty {
            let commentText = comments.map { "> \($0.text)" }.joined(separator: "\n>\n")
            result += "\n\n" + commentText
        }
        return result
    }

    // MARK: - Line Data Structure

    private struct LineData {
        let text: String
        let nsRange: NSRange
        var y: CGFloat = 0       // PDF Y coordinate (0 at bottom)
        var centerX: CGFloat = 0 // Center X position
        var width: CGFloat = 0   // Line width
        var hasPosition: Bool = false
    }

    private static func convertAttributedString(_ attributedString: NSAttributedString, page: PDFPage, comments: [CommentModel]) -> String {
        let text = attributedString.string
        guard !text.isEmpty else { return "" }

        // Step 1: Extract lines
        var lines = extractLinesFromAttributedString(text)
        guard !lines.isEmpty else { return "" }

        // Step 2: Attach positions for column detection
        lines = attachPositionsToLines(lines, page: page)

        // Step 3: Reorder for two-column layouts
        let pageBounds = page.bounds(for: .mediaBox)
        lines = reorderLinesForColumns(lines, pageWidth: pageBounds.width)

        // Step 4: Map comments to their closest lines
        let (lineComments, unmatchedComments) = mapCommentsToLines(comments, lines: lines)

        // Step 5: Format output with inline comments
        let modalFontSize = calculateModalFontSize(from: attributedString)
        let links = extractLinks(from: page)

        var output: [String] = []
        var inCodeBlock = false

        for (index, line) in lines.enumerated() {
            let fontSize = dominantFontSize(in: attributedString, range: line.nsRange)
            let isMonospace = detectMonospace(in: attributedString, range: line.nsRange)
            let formattedText = applyInlineFormatting(to: attributedString, range: line.nsRange)

            if isMonospace && !line.text.trimmingCharacters(in: .whitespaces).isEmpty {
                if !inCodeBlock {
                    output.append("```")
                    inCodeBlock = true
                }
                output.append(line.text)
            } else {
                if inCodeBlock {
                    output.append("```")
                    inCodeBlock = false
                }
                output.append(formatLine(line.text, fontSize: fontSize, modalFontSize: modalFontSize, formattedText: formattedText))
            }

            // Insert comments associated with this line
            if let comments = lineComments[index] {
                if inCodeBlock {
                    output.append("```")
                    inCodeBlock = false
                }
                for comment in comments {
                    output.append("> \(comment.text)")
                }
            }
        }

        if inCodeBlock {
            output.append("```")
        }

        // Append unmatched comments at end
        for comment in unmatchedComments {
            output.append("> \(comment.text)")
        }

        var result = cleanupOutput(output)
        result = applyLinks(to: result, links: links)

        return result
    }

    // MARK: - Comment-Line Mapping

    private static func mapCommentsToLines(_ comments: [CommentModel], lines: [LineData]) -> (lineComments: [Int: [CommentModel]], unmatched: [CommentModel]) {
        var lineComments: [Int: [CommentModel]] = [:]
        var unmatched: [CommentModel] = []

        for comment in comments {
            if let lineIndex = findClosestLine(for: comment, in: lines) {
                lineComments[lineIndex, default: []].append(comment)
            } else {
                unmatched.append(comment)
            }
        }

        // Sort comments within each line by creation time
        for key in lineComments.keys {
            lineComments[key]?.sort { $0.createdAt < $1.createdAt }
        }

        // Sort unmatched by creation time
        unmatched.sort { $0.createdAt < $1.createdAt }

        return (lineComments, unmatched)
    }

    private static func findClosestLine(for comment: CommentModel, in lines: [LineData]) -> Int? {
        let commentY = comment.bounds.midY

        var bestIndex: Int?
        var bestDistance: CGFloat = .greatestFiniteMagnitude

        for (index, line) in lines.enumerated() {
            guard line.hasPosition else { continue }
            let distance = abs(line.y - commentY)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }

        return bestIndex
    }

    private static func extractLinesFromAttributedString(_ text: String) -> [LineData] {
        var lines: [LineData] = []
        var currentIndex = text.startIndex

        for line in text.components(separatedBy: "\n") {
            let lineLength = line.count
            let lineEndIndex = text.index(currentIndex, offsetBy: lineLength, limitedBy: text.endIndex) ?? text.endIndex
            let nsRange = NSRange(currentIndex..<lineEndIndex, in: text)

            lines.append(LineData(text: line, nsRange: nsRange))

            currentIndex = lineEndIndex
            if currentIndex < text.endIndex {
                currentIndex = text.index(after: currentIndex)
            }
        }

        return lines
    }

    // MARK: - Position Detection (Optional Enhancement)

    private static func attachPositionsToLines(_ lines: [LineData], page: PDFPage) -> [LineData] {
        // Get position data from PDFSelection (may be incomplete)
        let pageBounds = page.bounds(for: .mediaBox)
        guard let selection = page.selection(for: pageBounds) else {
            return lines // Return unchanged if no selection available
        }

        // Build a map of line text → position
        var positionMap: [String: (y: CGFloat, centerX: CGFloat, width: CGFloat)] = [:]

        for lineSelection in selection.selectionsByLine() {
            guard let lineText = lineSelection.string else { continue }
            let trimmed = lineText.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let bounds = lineSelection.bounds(for: page)
            guard !bounds.isNull && !bounds.isEmpty else { continue }

            positionMap[trimmed] = (y: bounds.minY, centerX: bounds.midX, width: bounds.width)
        }

        // Attach positions to lines by matching text
        var result = lines
        for i in 0..<result.count {
            let trimmed = result[i].text.trimmingCharacters(in: .whitespaces)
            if let pos = positionMap[trimmed] {
                result[i].y = pos.y
                result[i].centerX = pos.centerX
                result[i].width = pos.width
                result[i].hasPosition = true
            }
        }

        return result
    }

    // MARK: - Column Detection and Reordering

    private static func reorderLinesForColumns(_ lines: [LineData], pageWidth: CGFloat) -> [LineData] {
        // Only attempt reordering if we have enough position data
        let linesWithPosition = lines.filter { $0.hasPosition }
        guard linesWithPosition.count >= 10 else {
            return lines // Not enough data, keep original order
        }

        // Detect if this is a two-column layout
        let gutterX = pageWidth / 2
        let leftThreshold = pageWidth * 0.35
        let rightThreshold = pageWidth * 0.65

        let leftCount = linesWithPosition.filter { $0.centerX < leftThreshold }.count
        let rightCount = linesWithPosition.filter { $0.centerX > rightThreshold }.count
        let totalSideCount = leftCount + rightCount
        let sideRatio = Double(totalSideCount) / Double(linesWithPosition.count)

        // Need strong evidence of two-column layout
        guard sideRatio > 0.7 && leftCount >= 5 && rightCount >= 5 else {
            return lines // Single column, keep original order
        }

        // Two-column detected: reorder lines
        var leftColumn: [LineData] = []
        var rightColumn: [LineData] = []
        var fullWidth: [LineData] = []
        var noPosition: [LineData] = []

        for line in lines {
            guard !line.text.trimmingCharacters(in: .whitespaces).isEmpty else {
                continue // Skip empty lines (will be handled in cleanup)
            }

            if !line.hasPosition {
                noPosition.append(line)
            } else if line.width > pageWidth * 0.6 {
                fullWidth.append(line) // Wide lines are full-width (headers/footers)
            } else if line.centerX < gutterX {
                leftColumn.append(line)
            } else {
                rightColumn.append(line)
            }
        }

        // Sort each column by Y descending (PDF: 0 at bottom, so higher Y = higher on page)
        leftColumn.sort { $0.y > $1.y }
        rightColumn.sort { $0.y > $1.y }
        fullWidth.sort { $0.y > $1.y }

        // Determine content boundaries
        let contentTopY = max(leftColumn.first?.y ?? 0, rightColumn.first?.y ?? 0)
        let contentBottomY = min(leftColumn.last?.y ?? 0, rightColumn.last?.y ?? 0)

        // Merge: headers → left column → right column → footers
        var result: [LineData] = []

        // Full-width blocks above content (headers/titles)
        result.append(contentsOf: fullWidth.filter { $0.y >= contentTopY })

        // Left column (read fully first)
        result.append(contentsOf: leftColumn)

        // Right column (read after left)
        result.append(contentsOf: rightColumn)

        // Full-width blocks below content (footers)
        result.append(contentsOf: fullWidth.filter { $0.y < contentBottomY })

        // Append lines without position data at the end (safety net)
        result.append(contentsOf: noPosition)

        return result
    }

    // MARK: - Line Formatting

    private static func formatLine(_ line: String, fontSize: CGFloat, modalFontSize: CGFloat, formattedText: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }

        // Check for list patterns
        if let listFormatted = formatAsList(trimmed) {
            return listFormatted
        }

        // Detect headers by font size
        let headerLevel = detectHeaderLevel(fontSize: fontSize, modalFontSize: modalFontSize)
        if headerLevel > 0 {
            return String(repeating: "#", count: headerLevel) + " " + trimmed
        }

        // Use formatted text (with bold/italic) for regular paragraphs
        let formatted = formattedText.trimmingCharacters(in: .whitespaces)
        return formatted.isEmpty ? trimmed : formatted
    }

    private static func detectHeaderLevel(fontSize: CGFloat, modalFontSize: CGFloat) -> Int {
        guard modalFontSize > 0, fontSize > modalFontSize else { return 0 }

        let ratio = fontSize / modalFontSize
        if ratio > 1.5 { return 1 }
        if ratio > 1.35 { return 2 }
        if ratio > 1.2 { return 3 }
        if ratio > 1.1 { return 4 }
        if ratio > 1.05 { return 5 }
        if ratio > 1.0 { return 6 }
        return 0
    }

    // MARK: - Font Analysis

    private static func dominantFontSize(in attributedString: NSAttributedString, range: NSRange) -> CGFloat {
        guard range.length > 0, range.location + range.length <= attributedString.length else {
            return 12
        }

        var sizes: [CGFloat: Int] = [:]
        attributedString.enumerateAttribute(.font, in: range, options: []) { value, attrRange, _ in
            if let font = value as? NSFont {
                sizes[font.pointSize, default: 0] += attrRange.length
            }
        }
        return sizes.max(by: { $0.value < $1.value })?.key ?? 12
    }

    private static func calculateModalFontSize(from attributedString: NSAttributedString) -> CGFloat {
        var sizes: [CGFloat: Int] = [:]
        let fullRange = NSRange(location: 0, length: attributedString.length)

        attributedString.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            if let font = value as? NSFont {
                sizes[font.pointSize, default: 0] += range.length
            }
        }
        return sizes.max(by: { $0.value < $1.value })?.key ?? 12
    }

    private static func detectMonospace(in attributedString: NSAttributedString, range: NSRange) -> Bool {
        guard range.length > 0, range.location + range.length <= attributedString.length else {
            return false
        }

        var monoCount = 0
        var totalCount = 0

        attributedString.enumerateAttribute(.font, in: range, options: []) { value, attrRange, _ in
            totalCount += attrRange.length
            if let font = value as? NSFont {
                let name = font.fontName.lowercased()
                if name.contains("mono") || name.contains("courier") || name.contains("menlo") ||
                   name.contains("consolas") || name.contains("source code") || name.contains("fira code") {
                    monoCount += attrRange.length
                }
            }
        }
        return totalCount > 0 && monoCount > totalCount / 2
    }

    // MARK: - Inline Formatting

    private static func applyInlineFormatting(to attributedString: NSAttributedString, range: NSRange) -> String {
        guard range.length > 0, range.location + range.length <= attributedString.length else {
            return ""
        }

        var result = ""
        attributedString.enumerateAttributes(in: range, options: []) { attributes, attrRange, _ in
            let text = attributedString.attributedSubstring(from: attrRange).string
            guard !text.isEmpty else { return }

            var isBold = false
            var isItalic = false

            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                isBold = traits.contains(.bold)
                isItalic = traits.contains(.italic)
            }

            switch (isBold, isItalic) {
            case (true, true): result += "***\(text)***"
            case (true, false): result += "**\(text)**"
            case (false, true): result += "*\(text)*"
            case (false, false): result += text
            }
        }
        return result
    }

    // MARK: - List Detection

    private static let unorderedListPattern = try! NSRegularExpression(pattern: #"^[-*•–—]\s+"#)
    private static let orderedListPattern = try! NSRegularExpression(pattern: #"^\d+\.\s+"#)

    private static func formatAsList(_ text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)

        if unorderedListPattern.firstMatch(in: text, range: range) != nil {
            let content = unorderedListPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            return "- \(content)"
        }

        if orderedListPattern.firstMatch(in: text, range: range) != nil {
            return text
        }

        return nil
    }

    // MARK: - Output Cleanup

    private static func cleanupOutput(_ lines: [String]) -> String {
        var result: [String] = []
        var previousWasBlank = false

        for line in lines {
            let isBlank = line.isEmpty
            if isBlank {
                if !previousWasBlank { result.append("") }
                previousWasBlank = true
            } else {
                result.append(line)
                previousWasBlank = false
            }
        }

        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Link Extraction

    private static func extractLinks(from page: PDFPage) -> [(text: String, url: URL)] {
        var links: [(text: String, url: URL)] = []

        for annotation in page.annotations {
            guard annotation.type == "Link",
                  let action = annotation.action as? PDFActionURL,
                  let url = action.url,
                  let selection = page.selection(for: annotation.bounds),
                  let text = selection.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            links.append((text: text.trimmingCharacters(in: .whitespacesAndNewlines), url: url))
        }
        return links
    }

    private static func applyLinks(to text: String, links: [(text: String, url: URL)]) -> String {
        var result = text
        for link in links {
            let markdownLink = "[\(link.text)](\(link.url.absoluteString))"
            if let range = result.range(of: link.text) {
                result = result.replacingCharacters(in: range, with: markdownLink)
            }
        }
        return result
    }
}
