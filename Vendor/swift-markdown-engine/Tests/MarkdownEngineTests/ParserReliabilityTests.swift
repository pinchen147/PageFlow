import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Markdown parser source fidelity", .serialized)
struct ParserReliabilityTests {
    private func attributes(_ text: String, caret: Int = -1) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text)
        for (range, values) in MarkdownASTStyler.styleAttributes(
            text: text, fontName: NSFont.systemFont(ofSize: 14).fontName,
            fontSize: 14, caretLocation: caret
        ) where range.length > 0 {
            result.addAttributes(values, range: range)
        }
        return result
    }

    @Test("unfinished fences remain literal code through the final source line",
          arguments: ["```", "```swift\n- item", "```swift\n# heading\n[x](target)\nlast", "~~~swift\nlast\n"])
    func unfinishedFence(_ text: String) throws {
        let ns = text as NSString
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        #expect(tokens.count == 1)
        let token = try #require(tokens.first)
        #expect(token.kind == .codeBlock)
        #expect(token.range == NSRange(location: 0, length: ns.length))
        #expect(token.markerRanges.count == 1)
        #expect(NSMaxRange(token.contentRange) == ns.length)
        #expect(MarkdownDetection.isInsideCodeBlock(location: ns.length, codeTokens: tokens))
        let styled = attributes(text)
        #expect(styled.string.utf16.elementsEqual(text.utf16))
        #expect(styled.attribute(.spellingState, at: ns.length - 1, effectiveRange: nil) as? Int == 0)
        #expect(styled.attribute(NSAttributedString.Key("MarkdownCode"), at: ns.length - 1, effectiveRange: nil) as? Int == 2)
        #expect(styled.attribute(.font, at: ns.length - 1, effectiveRange: nil) != nil)
    }

    @Test("fence closers honor the opening character, length, indentation and trailing whitespace")
    func fenceClosingRules() throws {
        let fixtures: [(String, String, String)] = [
            ("````swift\n```\n- literal\n````` \t\nnext", "```\n- literal\n", "swift"),
            ("   ~~~ruby\n```\n    ~~~\n~~~junk\n   ~~~~\nnext", "```\n    ~~~\n~~~junk\n", "ruby"),
            ("```swift\nbody\n   ```\nnext", "body\n", "swift"),
        ]
        for (text, body, language) in fixtures {
            let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
            let token = try #require(tokens.first { $0.kind == .codeBlock })
            #expect((text as NSString).substring(with: token.contentRange) == body)
            #expect(token.markerRanges.count == 2)
            #expect(MarkdownTokenizer.extractLanguage(from: token, in: text) == language)
            #expect(!MarkdownDetection.isInsideCodeBlock(location: (text as NSString).range(of: "next").location, codeTokens: tokens.filter { $0.kind == .codeBlock }))
        }
        #expect(BlockParser.parse("    ```swift\nplain").allSatisfy { $0.kind != .fencedCode })
        #expect(BlockParser.parse("```bad`info\nplain").allSatisfy { $0.kind != .fencedCode })
    }

    @Test("editing a separator cannot leave two paragraphs at an incremental seam")
    func newlineSeams() {
        let fixtures: [(String, NSRange, String)] = [
            ("*a\n\nb*", NSRange(location: 2, length: 1), "x"),
            ("😀a\r\n\r\nb", NSRange(location: 3, length: 2), "x"),
            ("a\n\n> b\n> c\n> d", NSRange(location: 1, length: 1), "x"),
            ("a\n\n- b\n- c\n- d", NSRange(location: 1, length: 1), "x"),
            ("a\n\n|h|\n|--|\n|b|\n|c|", NSRange(location: 1, length: 1), "x"),
            ("a\n\n~~~swift\nliteral\n~~~\nnext", NSRange(location: 1, length: 1), "x"),
        ]
        for (old, range, replacement) in fixtures {
            _ = BlockParser.parse(old)
            let new = (old as NSString).replacingCharacters(in: range, with: replacement)
            let incremental = BlockParser.parse(new)
            _ = BlockParser.parse("")
            #expect(incremental == BlockParser.parse(new))
        }
    }

    @Test("an edit inside a code or math block matches a full parse, and fence-forming edits fall back")
    func editsInsideOpaqueBlocks() {
        let code = "intro\n\n```swift\nlet a = 1\nlet b = 2\n```\n\nafter"
        let math = "intro\n\n$$\nx = 1\ny = 2\n$$\n\nafter"
        let unclosed = "intro\n\n```\nlet a = 1"
        let oneLine = "intro\n\n$$P = \\frac{a}{b}$$ after\n\nnext"
        let inLetA = (code as NSString).range(of: "a = 1").location
        let fixtures: [(String, NSRange, String)] = [
            (code, NSRange(location: inLetA, length: 0), "x"),                          // typing in code
            (code, NSRange(location: inLetA, length: 0), "\n"),                         // a new line in code
            (code, NSRange(location: inLetA, length: 1), ""),                           // a deletion in code
            (math, NSRange(location: (math as NSString).range(of: "x = 1").location, length: 0), "z"),
            (unclosed, NSRange(location: (unclosed as NSString).length, length: 0), "x"),
            (code, NSRange(location: inLetA, length: 0), "\n```\n"),                   // closes the fence early
            (code, NSRange(location: inLetA, length: 0), "\n   "),                      // indents a line, no fence
            ("```\nfoo   ```\n```", NSRange(location: 7, length: 0), "\n"),            // forms an indented closer
            (math, NSRange(location: (math as NSString).range(of: "x = 1").location, length: 0), "$$"),
            (oneLine, NSRange(location: (oneLine as NSString).range(of: "frac").location, length: 0), "x"),  // in a one-line formula
            (oneLine, NSRange(location: (oneLine as NSString).range(of: "frac").location, length: 0), "\n"),
            (oneLine, NSRange(location: (oneLine as NSString).range(of: "$$ after").location, length: 0), "$"),
            ("```\na\n``` \nb\n", NSRange(location: 10, length: 0), "x"),           // text after a closer
            ("```\na\n   ```\nb\n", NSRange(location: 6, length: 0), " "),          // a closer indented to 4
            ("   ```\na\n```\nb\n", NSRange(location: 0, length: 0), " "),          // an opener indented to 4
        ]
        for (old, range, replacement) in fixtures {
            _ = BlockParser.parse(old)
            let new = (old as NSString).replacingCharacters(in: range, with: replacement)
            let incremental = BlockParser.parse(new)
            _ = BlockParser.parse("")
            #expect(incremental == BlockParser.parse(new), "\(new.debugDescription)")
        }
    }

    @Test("canonically equivalent Unicode keeps exact incremental source token coordinates")
    func literalUnicodeCacheIdentity() throws {
        for (first, second) in [("*é*", "*e\u{301}*"), ("*e\u{301}*", "*é*")] {
            let prefix = "Before paragraph\n\n"
            let suffix = "\n\nAfter paragraph"
            _ = MarkdownTokenizer.parseTokensViaAST(in: prefix + "*x*" + suffix)
            _ = MarkdownTokenizer.parseTokensViaAST(in: prefix + first + suffix)
            _ = MarkdownTokenizer.parseTokensViaAST(in: prefix + "*x*" + suffix)
            let text = prefix + second + suffix
            let token = try #require(MarkdownTokenizer.parseTokensViaAST(in: text).first { $0.kind == .italic })
            let start = prefix.utf16.count
            let length = second.utf16.count
            #expect(token.range == NSRange(location: start, length: length))
            #expect(token.contentRange == NSRange(location: start + 1, length: length - 2))
            #expect(token.markerRanges.last == NSRange(location: start + length - 1, length: 1))
        }
    }

    @Test("link labels own code and escaped brackets without duplicate top-level nodes")
    func linkLabelChildren() throws {
        let text = "[a `]` b\\]](dest)"
        let nodes = InlineParser.parse(text)
        #expect(nodes.count == 1)
        guard case .link(_, let label, let url, _, let children) = try #require(nodes.first) else {
            Issue.record("expected one link owning its label children")
            return
        }
        #expect((text as NSString).substring(with: label) == "a `]` b\\]")
        #expect((text as NSString).substring(with: url) == "dest")
        #expect(children.contains { if case .code = $0 { return true }; return false })
        #expect(children.contains { if case .escape = $0 { return true }; return false })
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        #expect(tokens.filter { $0.kind == .link }.count == 1)
        #expect(tokens.filter { $0.kind == .inlineCode }.count == 1)
        #expect(InlineParser.parse("`[x](dest)`") == [.code(range: NSRange(location: 0, length: 11), content: NSRange(location: 1, length: 9))])
    }

    @Test("explicit link targets exclude angle delimiters and optional titles")
    func linkDestinationParsing() throws {
        let fixtures: [(String, String)] = [
            ("[x](<https://example.com> \"title\")", "https://example.com"),
            ("[x](mailto:user@example.com 'title')", "mailto:user@example.com"),
            ("[x](a(b)c (title))", "a(b)c"),
            ("[x](#anchor)", "#anchor"),
            ("[x](./guide.md)", "./guide.md"),
            ("[x]()", ""),
            ("[x](a\\(b\\))", "a\\(b\\)"),
        ]
        for (text, destination) in fixtures {
            guard case .link(_, _, let url, _, _) = try #require(InlineParser.parse(text).first) else {
                Issue.record("expected link for \(text)")
                continue
            }
            #expect((text as NSString).substring(with: url) == destination)
            if !destination.contains("\\") {
                let target = attributes(text).attribute(.link, at: 1, effectiveRange: nil) as? URL
                if destination.isEmpty {
                    #expect(target == nil)
                } else {
                    #expect(target?.absoluteString == destination)
                }
            }
        }
        for text in ["[x](dest junk)", "[x](<dest)", "[x](dest \"unfinished)"] {
            #expect(!InlineParser.parse(text).contains { if case .link = $0 { return true }; return false })
        }
    }

    @Test("wiki names retain their source identifier and hide only inactive suffix presentation")
    func wikiIdentifierSource() {
        let text = "[[Name|stable-id]]"
        let inactive = attributes(text)
        #expect(inactive.attribute(.wikiLinkID, at: 2, effectiveRange: nil) as? String == "stable-id")
        #expect(inactive.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor == .clear)
        #expect((inactive.attribute(.font, at: 7, effectiveRange: nil) as? NSFont)?.pointSize == MarkdownEditorConfiguration.default.markers.hiddenMarkerFontSize)
        #expect(inactive.string == text)
        let active = attributes(text, caret: 7)
        #expect(active.attribute(.wikiLinkID, at: 2, effectiveRange: nil) as? String == "stable-id")
        #expect(active.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor != .clear)
    }

    @Test("incomplete link coloring covers every UTF-16 unit without coloring content as brackets",
          arguments: ["[😀]", "[e\u{301}]", "[👩‍👩‍👧‍👦]", "[😀abc"])
    func incompleteLinkUnicode(_ text: String) {
        let styled = attributes(text)
        let ns = text as NSString
        let theme = MarkdownEditorConfiguration.default.theme
        let faded = theme.incompleteLink.withAlphaComponent(MarkdownEditorConfiguration.default.link.incompleteLinkAlpha)
        for index in 0..<ns.length {
            let unit = ns.character(at: index)
            let bracket = [0x5B, 0x5D, 0x28, 0x29].contains(Int(unit))
            #expect(styled.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor == (bracket ? theme.mutedText : faded))
        }
    }

    @Test("inline and closed fenced code provide code context across markers and content")
    func codeContextAttributes() {
        for text in ["`x`", "~~~\nx\n~~~"] {
            let styled = attributes(text)
            for index in 0..<styled.length {
                #expect(styled.attribute(NSAttributedString.Key("MarkdownCode"), at: index, effectiveRange: nil) as? Int == 1)
            }
        }
        #expect(attributes("plain").attribute(NSAttributedString.Key("MarkdownCode"), at: 0, effectiveRange: nil) == nil)
    }

    @Test("caret immediately after closed code belongs to prose")
    func closedCodeCaretBoundary() {
        for text in ["`x`", "```swift\nx\n```"] {
            let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
            let end = (text as NSString).length
            #expect(MarkdownDetection.isInsideCodeBlock(location: end - 1, codeTokens: tokens))
            #expect(!MarkdownDetection.isInsideCodeBlock(location: end, codeTokens: tokens))
        }
    }

    @Test("link activation decodes destination escapes while retaining literal source")
    func escapedDestinationActivation() {
        let text = "[x](https://example.com/a\\(b\\)\\*?q=%20)"
        let styled = attributes(text)
        #expect(styled.string.utf16.elementsEqual(text.utf16))
        #expect((styled.attribute(.link, at: 1, effectiveRange: nil) as? URL)?.absoluteString == "https://example.com/a(b)*?q=%20")
    }

    @Test("the parse cache's chunked compare matches a full copy, across chunk boundaries")
    func chunkedUTF16Compare() {
        let text = String(repeating: "abc😀", count: 3_000) as NSString
        let units = copiedUTF16(of: text)
        #expect(utf16(units, equals: text))
        var changed = units
        changed[5_000] &+= 1
        #expect(!utf16(changed, equals: text))
        #expect(!utf16(Array(units.dropLast()), equals: text))
        #expect(utf16([], equals: ""))
    }
}
