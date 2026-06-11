//
//  MarkdownLayoutTests.swift
//  PageFlowTests
//
//  Exercises the pure Markdown heuristics with synthetic attributed text and
//  positions — no live PDFPage required.
//

import AppKit
import Testing
@testable import PageFlow

struct MarkdownLayoutTests {

    // MARK: - Builders

    /// Builds a multi-line attributed string. Each inner array is one line's
    /// runs; lines are joined with "\n". The newline carries no font.
    private func attributed(_ lines: [[(text: String, font: NSFont)]]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (lineIndex, runs) in lines.enumerated() {
            if lineIndex > 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            for run in runs {
                result.append(NSAttributedString(string: run.text, attributes: [.font: run.font]))
            }
        }
        return result
    }

    /// A single-font line, the common case.
    private func line(_ text: String, _ font: NSFont) -> [(text: String, font: NSFont)] {
        [(text, font)]
    }

    private let body = NSFont.systemFont(ofSize: 12)

    private func convert(
        _ attr: NSAttributedString,
        pageWidth: CGFloat = 600,
        positions: [String: MarkdownLayout.LinePosition] = [:],
        links: [MarkdownLayout.Link] = [],
        comments: [CommentModel] = []
    ) -> String {
        MarkdownLayout.convert(
            attributedString: attr,
            pageWidth: pageWidth,
            positionMap: positions,
            links: links,
            comments: comments
        )
    }

    // MARK: - Basic conversion

    @Test
    func emptyAttributedStringProducesEmptyOutput() {
        #expect(convert(NSAttributedString(string: "")) == "")
    }

    @Test
    func plainParagraphPassesThrough() {
        let attr = attributed([line("Hello world", body)])
        #expect(convert(attr) == "Hello world")
    }

    // MARK: - Headings by font size

    @Test
    func largerFontBecomesHeadingRelativeToModalSize() {
        // Modal size is 12 (body dominates by character count); 24/12 = 2.0 -> h1.
        let attr = attributed([
            line("Title", NSFont.systemFont(ofSize: 24)),
            line("body text one", body),
            line("body text two", body),
        ])
        #expect(convert(attr) == "# Title\nbody text one\nbody text two")
    }

    @Test
    func headingLevelTracksTheSizeRatioBoundaries() {
        // 13.5/12 = 1.125 -> falls in the (1.1, 1.2] band -> h4.
        let attr = attributed([
            line("Sub", NSFont.systemFont(ofSize: 13.5)),
            line("aaaaaaaaaaaa", body),
            line("bbbbbbbbbbbb", body),
        ])
        #expect(convert(attr).hasPrefix("#### Sub\n"))
    }

    // MARK: - Monospace -> fenced code block

    @Test
    func monospaceLinesAreFencedAsCode() {
        let mono = NSFont(name: "Menlo", size: 12)!
        let attr = attributed([
            line("intro", body),
            line("let x = 1", mono),
            line("outro", body),
        ])
        #expect(convert(attr) == "intro\n```\nlet x = 1\n```\noutro")
    }

    // MARK: - Lists

    @Test
    func unorderedMarkersNormalizeToDash() {
        let attr = attributed([
            line("- first", body),
            line("* second", body),
        ])
        #expect(convert(attr) == "- first\n- second")
    }

    @Test
    func orderedListItemsArePreserved() {
        let attr = attributed([line("1. first", body)])
        #expect(convert(attr) == "1. first")
    }

    // MARK: - Inline bold/italic

    @Test
    func boldRunGetsDoubleAsterisks() {
        let attr = attributed([[
            (text: "normal ", font: body),
            (text: "bold", font: NSFont.boldSystemFont(ofSize: 12)),
        ]])
        #expect(convert(attr) == "normal **bold**")
    }

    // MARK: - Two-column reordering

    @Test
    func strongTwoColumnEvidenceReordersLeftThenRight() {
        // 6 left + 6 right positioned lines: count >= 10, sideRatio = 1.0,
        // leftCount = rightCount = 6 -> two-column. Source order interleaves the
        // columns; output must be the full left column then the full right column,
        // each top-to-bottom (PDF y descending).
        let pageWidth: CGFloat = 100
        let leftX: CGFloat = 20   // < 35 (0.35 * 100)
        let rightX: CGFloat = 80  // > 65 (0.65 * 100)
        let lineWidth: CGFloat = 30 // < 60 (0.6 * 100): not full-width

        var positions: [String: MarkdownLayout.LinePosition] = [:]
        var interleaved: [[(text: String, font: NSFont)]] = []
        for i in 0..<6 {
            let y = CGFloat(600 - i * 100)
            positions["L\(i)"] = .init(y: y, centerX: leftX, width: lineWidth)
            positions["R\(i)"] = .init(y: y, centerX: rightX, width: lineWidth)
            interleaved.append(line("L\(i)", body))
            interleaved.append(line("R\(i)", body))
        }

        let expected = (0..<6).map { "L\($0)" }.joined(separator: "\n")
            + "\n" + (0..<6).map { "R\($0)" }.joined(separator: "\n")
        #expect(convert(attributed(interleaved), pageWidth: pageWidth, positions: positions) == expected)
    }

    @Test
    func weakColumnEvidenceKeepsOriginalOrder() {
        // 12 positioned lines all centered in the gutter: leftCount = rightCount = 0,
        // so the two-column guard fails and original order is preserved.
        let pageWidth: CGFloat = 100
        var positions: [String: MarkdownLayout.LinePosition] = [:]
        var lines: [[(text: String, font: NSFont)]] = []
        for i in 0..<12 {
            positions["C\(i)"] = .init(y: CGFloat(1200 - i * 100), centerX: 50, width: 30)
            lines.append(line("C\(i)", body))
        }
        let expected = (0..<12).map { "C\($0)" }.joined(separator: "\n")
        #expect(convert(attributed(lines), pageWidth: pageWidth, positions: positions) == expected)
    }

    // MARK: - Comment mapping

    @Test
    func commentAttachesAfterItsClosestPositionedLine() {
        // Two positioned lines; comment at y≈120 is closest to "beta" (y 100).
        let attr = attributed([line("alpha", body), line("beta", body)])
        let positions: [String: MarkdownLayout.LinePosition] = [
            "alpha": .init(y: 500, centerX: 50, width: 200),
            "beta": .init(y: 100, centerX: 50, width: 200),
        ]
        let comment = CommentModel(text: "note", pageIndex: 0,
                                   bounds: CGRect(x: 0, y: 115, width: 10, height: 10))
        #expect(convert(attr, positions: positions, comments: [comment]) == "alpha\nbeta\n> note")
    }

    @Test
    func commentWithoutPositionedLinesIsAppendedAtEnd() {
        // No positions -> no line to attach to -> comment goes to the end.
        let attr = attributed([line("alpha", body), line("beta", body)])
        let comment = CommentModel(text: "note", pageIndex: 0,
                                   bounds: CGRect(x: 0, y: 115, width: 10, height: 10))
        #expect(convert(attr, comments: [comment]) == "alpha\nbeta\n> note")
    }

    // MARK: - Links

    @Test
    func linkTextIsRewrittenAsMarkdownLink() {
        let attr = attributed([line("see example here", body)])
        let link = MarkdownLayout.Link(text: "example", url: URL(string: "https://example.com/page")!)
        #expect(convert(attr, links: [link]) == "see [example](https://example.com/page) here")
    }

    @Test
    func duplicateLinkTextLinksOnlyTheFirstOccurrence() {
        // Current rule: each link claims one occurrence — the first one wins.
        let attr = attributed([line("docs and docs again", body)])
        let link = MarkdownLayout.Link(text: "docs", url: URL(string: "https://docs.example")!)
        #expect(convert(attr, links: [link]) == "[docs](https://docs.example) and docs again")
    }

    @Test
    func laterLinkMatchingOnlyInsideAnEarlierInsertedURLIsSkipped() {
        // "com" never occurs in the page text — only inside the URL inserted for
        // "example". Ranges are resolved against the pristine text, so the second
        // link must not corrupt the first markdown link.
        let attr = attributed([line("see example here", body)])
        let links = [
            MarkdownLayout.Link(text: "example", url: URL(string: "https://example.com")!),
            MarkdownLayout.Link(text: "com", url: URL(string: "https://c.om")!),
        ]
        #expect(convert(attr, links: links) == "see [example](https://example.com) here")
    }

    // MARK: - Multi-scalar text

    @Test
    func headingAttributionSurvivesMultiScalarText() {
        // Emoji and accented characters occupy multiple UTF-16 units (and the
        // astronaut is a multi-scalar ZWJ cluster); the per-line ranges must stay
        // aligned so the heading font is attributed to the right line and the
        // bold run keeps its own boundaries.
        let attr = attributed([
            line("🚀 Café résumé", NSFont.systemFont(ofSize: 24)),
            [(text: "naïve ", font: body),
             (text: "🧑‍🚀 bold", font: NSFont.boldSystemFont(ofSize: 12))],
            line("plain body line two", body),
        ])
        #expect(convert(attr) == "# 🚀 Café résumé\nnaïve **🧑‍🚀 bold**\nplain body line two")
    }

    // MARK: - Cleanup

    @Test
    func consecutiveBlankLinesCollapseToOne() {
        let attr = attributed([
            line("a", body),
            line("", body),
            line("", body),
            line("b", body),
        ])
        #expect(convert(attr) == "a\n\nb")
    }
}
