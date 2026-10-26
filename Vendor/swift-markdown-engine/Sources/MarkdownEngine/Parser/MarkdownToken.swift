//
//  MarkdownToken.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Defines the basic Markdown building blocks the editor works with (bold,
// links, code, LaTeX, etc.), plus shared text attributes.
import AppKit
import Foundation

extension NSAttributedString.Key {
    public static let wikiLinkID = NSAttributedString.Key("NodeLinkID")
    public static let taskCheckbox = NSAttributedString.Key("TaskCheckbox")
    /// Code context for native editing helpers: 2 is an unfinished fenced block, 1 is other code.
    static let markdownCode = NSAttributedString.Key("MarkdownCode")
}

enum MarkdownTokenKind: Hashable {
    /// Kinds whose caret-driven reveal/collapse swaps a tall rendered band
    /// (grid / block-math image / image) for multi-line raw source — a
    /// height change big enough that a restyle touching one must anchor the
    /// viewport (see `restylePreservingViewport`). An image's width, crop
    /// and size tokens change its height too (doc 26 §2.5). Named once so the
    /// anchor gates don't re-list `.table/.blockLatex/.imageEmbed/.imageLink`
    /// inline.
    ///
    /// NOT the whole story: a rendered diagram block (```` ```mermaid ````) is
    /// ALSO height-banded — it collapses a tall image ⇄ multi-line source — but
    /// its kind is `.codeBlock`, which can't be added here (every code block
    /// would then anchor). Use ``isHeightBanded(_:in:diagramLanguages:)`` at the
    /// gates instead of testing `heightBanded.contains(kind)` directly, so the
    /// diagram case is covered by the one predicate.
    static let heightBanded: Set<MarkdownTokenKind> = [.table, .blockLatex, .imageEmbed, .imageLink]

    /// Whether `token` is height-banded: its kind is in ``heightBanded``, OR it
    /// is a fenced code block whose info-string language is a rendered diagram
    /// language (`diagramLanguages`, e.g. `mermaid`) — which collapses to a
    /// diagram image just like block math, a height change a touching restyle
    /// must anchor. This is the single shared gate for that decision; the raw
    /// `heightBanded.contains(kind)` set can't express the diagram case because
    /// it is keyed on kind alone.
    static func isHeightBanded(_ token: MarkdownToken, in text: String, diagramLanguages: Set<String>) -> Bool {
        if heightBanded.contains(token.kind) { return true }
        guard token.kind == .codeBlock, !diagramLanguages.isEmpty,
              let language = MarkdownTokenizer.extractLanguage(from: token, in: text)?.lowercased()
        else { return false }
        return diagramLanguages.contains(language)
    }

    case italic
    case boldItalic
    case bold
    case link
    case wikiLink
    case heading
    /// One blockquote line; `markerRanges[0]` is the `>` run, nesting = count of `>`.
    case blockquote
    case codeBlock
    case inlineCode
    case blockLatex
    case inlineLatex
    case imageEmbed
    case imageLink
    case strikethrough
    /// `==text==`, the reference editor's highlight mark.
    case highlight
    case underline
    case table
    /// A CommonMark backslash escape; marker is the `\`, content the escaped literal char.
    case backslashEscape
}

struct MarkdownToken {
    let kind: MarkdownTokenKind
    let range: NSRange
    let contentRange: NSRange
    let markerRanges: [NSRange]
}

extension MarkdownToken {
    func standaloneParagraphRange(in text: NSString) -> NSRange? {
        let paragraphRange = text.paragraphRange(for: range)
        let paragraphText = text.substring(with: paragraphRange) as NSString
        let tokenRelativeRange = NSRange(
            location: range.location - paragraphRange.location,
            length: range.length
        )
        let mutableParagraph = paragraphText.mutableCopy() as! NSMutableString
        mutableParagraph.replaceCharacters(in: tokenRelativeRange, with: "")
        return mutableParagraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? paragraphRange : nil
    }

    func containsSelectionOrStandaloneParagraph(_ selectionLocation: Int, in text: NSString) -> Bool {
        let start = range.location
        let end = NSMaxRange(range) - 1
        if selectionLocation >= start && selectionLocation <= end {
            return true
        }

        guard let paragraphRange = standaloneParagraphRange(in: text) else {
            return false
        }
        let paragraphEnd = NSMaxRange(paragraphRange)
        // Reveal source when caret is at document end right after the image, unless that line ends in a newline.
        let endsWithNewline = paragraphEnd > paragraphRange.location
            && (text.character(at: paragraphEnd - 1) == 0x0A || text.character(at: paragraphEnd - 1) == 0x0D)
        let isAtLastParagraphEnd = selectionLocation == text.length
            && paragraphEnd == text.length && !endsWithNewline
        return (selectionLocation >= paragraphRange.location && selectionLocation < paragraphEnd)
            || isAtLastParagraphEnd
    }
}
