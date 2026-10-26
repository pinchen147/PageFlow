//
//  MarkdownASTStyler.swift
//  MarkdownEngine
//
//  Phase 2.5 — the AST-native styler. Walks the document AST and emits
//  [StyledRange], COMPOSING attributes on descent: a heading sets a large bold
//  font, descending into bold adds the bold trait (keeping the size), into
//  italic adds italic — so nested/combined inline styles stack instead of
//  overwriting each other (the flaw in the flat 18-pass styler, e.g. the
//  shrinking bold in `# **n*o*des**`).
//
//  Built incrementally behind the existing styler; not wired until complete
//  and visually verified. Covered so far: heading/paragraph/blockquote blocks;
//  inline emphasis (font composition), strikethrough, inline code, markdown
//  links, wiki links. Still TODO: images, image embeds, inline LaTeX, escapes,
//  autolinks, marker-shrinking, paragraph styles, code/table/latex blocks,
//  bullets, task checkboxes, horizontal rules.
//

import AppKit
import Foundation

enum MarkdownASTStyler {

    static func styleAttributes(
        text: String,
        fontName: String,
        fontSize: CGFloat,
        caretLocation: Int = -1,
        wikiLinkIDProvider: @escaping (NSRange) -> String? = { _ in nil },
        scopedRanges: [NSRange]? = nil,
        configuration: MarkdownEditorConfiguration = .default
    ) -> [StyledRange] {
        let baseFont = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
        let baseLineHeight = ceil(baseFont.ascender - baseFont.descender + baseFont.leading)
        let baseParagraphSpacing = ceil(baseLineHeight * configuration.paragraph.spacingFactor)
        let codeFontSize = round(fontSize * configuration.codeBlock.fontSizeScale)
        let hiddenSize = configuration.markers.hiddenMarkerFontSize
        let ns = text as NSString
        let codeFont = configuration.services.syntaxHighlighter.codeFont(size: codeFontSize)
        let codeLineHeight = ceil(codeFont.ascender - codeFont.descender + codeFont.leading)
        let codePara = NSMutableParagraphStyle()
        codePara.lineBreakMode = .byCharWrapping
        codePara.lineSpacing = 0
        codePara.paragraphSpacingBefore = configuration.codeBlock.paragraphSpacing
        codePara.paragraphSpacing = configuration.codeBlock.paragraphSpacing
        codePara.headIndent = configuration.codeBlock.horizontalIndent
        codePara.firstLineHeadIndent = configuration.codeBlock.horizontalIndent
        codePara.tailIndent = -configuration.codeBlock.horizontalIndent
        codePara.minimumLineHeight = codeLineHeight
        codePara.maximumLineHeight = codeLineHeight
        let ctx = Ctx(
            ns: ns,
            fontName: fontName,
            baseFont: baseFont,
            baseLineHeight: baseLineHeight,
            baseParagraphSpacing: baseParagraphSpacing,
            codeFont: codeFont,
            codeBackground: configuration.services.syntaxHighlighter.backgroundColor(),
            codeParagraphStyle: codePara,
            inlineMarkerFont: NSFont(name: fontName, size: hiddenSize) ?? .systemFont(ofSize: hiddenSize),
            caret: caretLocation,
            config: configuration,
            wikiLinkID: wikiLinkIDProvider,
            scopedRanges: scopedRanges
        )
        var blocks: [BlockNode] = []
        PerfTrace.time("ast.parse") { blocks = DocumentAST.parse(text, scopedRanges: scopedRanges) }
        var attrs: [StyledRange] = []
        PerfTrace.time("ast.blocks") {
        for block in blocks where ctx.inScope(block.range) {
            styleBlock(block, font: baseFont, ctx: ctx, into: &attrs)
        }
        }
        PerfTrace.time("ast.shrink") { shrinkInactiveMarkers(in: blocks, ctx: ctx, into: &attrs) }

        // Text/regex passes (AST-agnostic); AST code ranges drive the "skip inside code" checks.
        var codeRanges: [NSRange] = [], checkboxRanges: [NSRange] = [], completeLinks: [NSRange] = []
        PerfTrace.time("ast.collect") { codeRanges = collectCodeRanges(in: blocks); checkboxRanges = collectCheckboxRanges(in: blocks); completeLinks = collectLinkRanges(in: blocks) }
        PerfTrace.time("ast.autoLinks") { styleAutoLinks(ctx: ctx, codeRanges: codeRanges + completeLinks, into: &attrs) }
        PerfTrace.time("ast.incompleteLinks") { styleIncompleteLinkBrackets(ctx: ctx, codeRanges: codeRanges, protectedRanges: checkboxRanges + completeLinks, into: &attrs) }
        return attrs
    }

    // MARK: - Text/regex-based passes (ported 1:1, AST-agnostic)

    private static func collectCodeRanges(in blocks: [BlockNode]) -> [NSRange] {
        var ranges: [NSRange] = []
        func walk(_ nodes: [InlineNode]) {
            for node in nodes {
                switch node {
                case .code(let range, _), .inlineLatex(let range, _, _): ranges.append(range)
                case .emphasis(_, _, _, let children), .strikethrough(_, _, let children), .highlight(_, _, let children),
                     .underline(_, _, let children), .link(_, _, _, _, let children): walk(children)
                default: break
                }
            }
        }
        for block in blocks {
            switch block {
            case .codeBlock(let range), .blockLatex(let range): ranges.append(range)
            case .paragraph(_, let inlines), .heading(_, _, _, let inlines), .blockquote(_, let inlines):
                walk(inlines)
            case .list(_, let items):
                for item in items { walk(item.inlines) }
            case .table(_, let cells):
                for cell in cells { walk(cell.inlines) }
            default: break
            }
        }
        return ranges
    }

    private static func isInCode(_ range: NSRange, _ codeRanges: [NSRange]) -> Bool {
        codeRanges.contains { NSIntersectionRange($0, range).length > 0 }
    }

    /// Completed link syntax must not be recolored as an incomplete bracket or an autolink.
    private static func collectLinkRanges(in blocks: [BlockNode]) -> [NSRange] {
        var ranges: [NSRange] = []
        func walk(_ nodes: [InlineNode]) {
            for node in nodes {
                switch node {
                case .link(let range, _, _, _, _), .wikiLink(let range, _, _, _),
                     .image(let range, _, _, _), .imageEmbed(let range, _, _):
                    ranges.append(range)
                case .emphasis(_, _, _, let children), .strikethrough(_, _, let children),
                     .underline(_, _, let children): walk(children)
                default: break
                }
            }
        }
        for block in blocks {
            switch block {
            case .paragraph(_, let nodes), .heading(_, _, _, let nodes), .blockquote(_, let nodes): walk(nodes)
            case .list(_, let items): items.forEach { walk($0.inlines) }
            case .table(_, let cells): cells.forEach { walk($0.inlines) }
            default: break
            }
        }
        return ranges
    }

    /// Checkbox boxes (`[ ]`/`[x]`), excluded so the incomplete-link pass doesn't repaint their brackets.
    private static func collectCheckboxRanges(in blocks: [BlockNode]) -> [NSRange] {
        var ranges: [NSRange] = []
        for block in blocks {
            if case .list(_, let items) = block {
                for item in items where item.checkbox != nil { ranges.append(item.checkbox!) }
            }
        }
        return ranges
    }

    private static func regex(_ pattern: String, _ anchored: Bool = true) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: anchored ? [.anchorsMatchLines] : [])
    }

    /// Link detector + incomplete-link patterns, compiled ONCE (they were rebuilt
    /// every restyle). Both are thread-safe + stateless for matching.
    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )
    private static let incompleteLinkPatterns: [NSRegularExpression] = [
        #"\[\]"#, #"\[\[\]\]"#, #"\[[^\]\r\n]*$"#, #"\[[^\]\r\n]+\](?!\()"#,
        #"\[[^\]\r\n]+\]\([^)\r\n]*$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: []) }

    /// Tag a thematic-break line for a full-width rule (AST-driven); suppressed while the caret edits it.
    private static func styleThematicBreak(range: NSRange, ctx: Ctx, into attrs: inout [StyledRange]) {
        var hr = range
        while hr.length > 0 {
            let last = ctx.ns.character(at: NSMaxRange(hr) - 1)
            guard last == 0x0A || last == 0x0D else { break }
            hr.length -= 1
        }
        guard hr.length > 0,
              !(NSLocationInRange(ctx.caret, hr) || ctx.caret == NSMaxRange(hr)) else { return }
        attrs.append((hr, [.foregroundColor: NSColor.clear, .thematicBreak: true]))
        attrs.append((hr, [.paragraphStyle: NSMutableParagraphStyle()]))
    }

    /// AST list-item decoration: indent paragraph, `•` bullet, checkbox + strikethrough, all caret-aware.
    private static func styleListItem(_ item: ListItem, ctx: Ctx, into attrs: inout [StyledRange]) {
        guard ctx.config.lists.helpersEnabled else { return }

        // Line content (item line minus its trailing newline).
        var line = item.range
        while line.length > 0 {
            let last = ctx.ns.character(at: NSMaxRange(line) - 1)
            guard last == 0x0A || last == 0x0D else { break }
            line.length -= 1
        }

        // 1. Indent paragraph style (hanging indent so wrapped lines align).
        let wsRange = NSRange(location: item.range.location, length: item.marker.location - item.range.location)
        let ws = ctx.ns.substring(with: wsRange)
        let markerGroup = NSRange(location: item.marker.location,
                                  length: item.contentRange.location - item.marker.location)
        let markerWidth = (ctx.ns.substring(with: markerGroup) as NSString)
            .size(withAttributes: [.font: ctx.baseFont]).width
        let depthIndent = CGFloat(MarkdownLists.indentLevel(from: ws)) * ctx.config.lists.indentPerLevel
        let extraSpacing = (item.checkbox != nil && !item.checked)
            ? HeadingHelpers.checkboxExtraSpacing(font: ctx.baseFont, configuration: ctx.config.checkbox)
            : 0
        let ps = NSMutableParagraphStyle()
        let lineHeight = ctx.baseLineHeight + ctx.config.lists.extraLineHeight
        ps.minimumLineHeight = lineHeight
        ps.maximumLineHeight = lineHeight
        ps.lineSpacing = 0
        ps.paragraphSpacing = ctx.baseParagraphSpacing
        ps.paragraphSpacingBefore = 0
        ps.tabStops = []
        ps.defaultTabInterval = ctx.config.lists.indentPerLevel
        ps.firstLineHeadIndent = ctx.config.lists.indentPerLevel
        ps.headIndent = ctx.config.lists.indentPerLevel + depthIndent + markerWidth + extraSpacing
        attrs.append((line, [.paragraphStyle: ps]))

        // 2. Marker decoration (suppressed while the caret edits the syntax).
        if let box = item.checkbox {
            let syntax = NSRange(location: item.marker.location, length: NSMaxRange(box) - item.marker.location)
            if NSLocationInRange(ctx.caret, syntax) || ctx.caret == NSMaxRange(box) { return }
            let spacer = NSRange(location: NSMaxRange(item.marker), length: box.location - NSMaxRange(item.marker))
            attrs.append((item.marker, [.foregroundColor: NSColor.clear]))
            if spacer.length > 0 { attrs.append((spacer, [.foregroundColor: NSColor.clear])) }
            attrs.append((box, [.taskCheckbox: item.checked, .foregroundColor: NSColor.clear]))
            if item.checked, NSMaxRange(item.range) > NSMaxRange(box) {
                attrs.append((NSRange(location: NSMaxRange(box), length: NSMaxRange(item.range) - NSMaxRange(box)), [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: ctx.theme.strikethroughColor,
                ]))
            }
        } else if !item.ordered {
            let syntax = NSRange(location: item.marker.location,
                                 length: item.contentRange.location - item.marker.location)
            if NSLocationInRange(ctx.caret, syntax) { return }
            attrs.append((item.marker, [.bulletMarker: true, .foregroundColor: NSColor.clear]))
        }
    }

    private static func styleAutoLinks(ctx: Ctx, codeRanges: [NSRange], into attrs: inout [StyledRange]) {
        guard let detector = Self.linkDetector else { return }
        for scan in ctx.scanRanges {
            // The detector costs ~0.2 ms per KB; most prose paragraphs cannot hold
            // a link at all (no `://`, `@`, or `.` glued to a letter) and are skipped.
            var cursor = scan.location
            let end = NSMaxRange(scan)
            while cursor < end {
                let paragraph = ctx.ns.paragraphRange(for: NSRange(location: cursor, length: 0))
                cursor = NSMaxRange(paragraph)
                let clipped = NSIntersectionRange(paragraph, scan)
                guard clipped.length > 0, mayHoldLink(clipped, in: ctx.ns) else { continue }
                detector.enumerateMatches(in: ctx.text, range: clipped) { match, _, _ in
                    guard let match, let url = match.url, !isInCode(match.range, codeRanges) else { return }
                    attrs.append((match.range, [.link: url]))
                }
            }
        }
    }

    /// A URL, bare domain or e-mail address needs `://`, `@`, or a domain-shaped
    /// dot: a letter or digit, `.`, then two or more letters (`example.com`).
    /// A sentence's full stop, `e.g.` and `U.S.` do not qualify.
    private static func mayHoldLink(_ range: NSRange, in ns: NSString) -> Bool {
        func letter(_ c: unichar) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
        func alphanumeric(_ c: unichar) -> Bool { letter(c) || (c >= 0x30 && c <= 0x39) }
        let end = NSMaxRange(range)
        var i = range.location
        while i < end {
            let c = ns.character(at: i)
            if c == 0x40 { return true }                                              // @
            if c == 0x3A, i + 2 < end, ns.character(at: i + 1) == 0x2F, ns.character(at: i + 2) == 0x2F { return true }  // ://
            if c == 0x2E, i > range.location, i + 2 < end,
               alphanumeric(ns.character(at: i - 1)), letter(ns.character(at: i + 1)), letter(ns.character(at: i + 2)) {
                return true
            }
            i += 1
        }
        return false
    }

    private static func styleIncompleteLinkBrackets(ctx: Ctx, codeRanges: [NSRange], protectedRanges: [NSRange], into attrs: inout [StyledRange]) {
        let muted = ctx.theme.mutedText
        let faded = ctx.theme.incompleteLink.withAlphaComponent(ctx.config.link.incompleteLinkAlpha)
        for re in Self.incompleteLinkPatterns {
            for scan in ctx.scanRanges {
              for m in re.matches(in: ctx.text, options: [], range: scan)
                  where !isInCode(m.range, codeRanges) && !isInCode(m.range, protectedRanges) {
                for index in m.range.location..<NSMaxRange(m.range) {
                    let r = NSRange(location: index, length: 1)
                    let unit = ctx.ns.character(at: index)
                    let isBracket = unit == 0x5B || unit == 0x5D || unit == 0x28 || unit == 0x29
                    attrs.append((r, [.foregroundColor: isBracket ? muted : faded]))
                }
              }
            }
        }
    }

    /// Shared inputs threaded through the walk.
    private struct Ctx {
        let ns: NSString
        let fontName: String
        let baseFont: NSFont
        let baseLineHeight: CGFloat
        let baseParagraphSpacing: CGFloat
        let codeFont: NSFont
        let codeBackground: NSColor
        let codeParagraphStyle: NSParagraphStyle
        let inlineMarkerFont: NSFont
        let caret: Int
        let config: MarkdownEditorConfiguration
        let wikiLinkID: (NSRange) -> String?
        let scopedRanges: [NSRange]?

        /// Active (syntax revealed) when the caret is inside the range or at its end (minus a newline).
        func isActive(_ range: NSRange) -> Bool {
            if NSLocationInRange(caret, range) { return true }
            guard range.length > 0, caret == NSMaxRange(range) else { return false }
            let last = ns.character(at: caret - 1)
            return last != 0x0A && last != 0x0D
        }
        var theme: MarkdownEditorTheme { config.theme }
        var text: String { ns as String }
        var fullRange: NSRange { NSRange(location: 0, length: ns.length) }
        /// Whether a range falls in the styled region (nil scope = whole doc).
        func inScope(_ r: NSRange) -> Bool {
            guard let scopedRanges else { return true }
            return scopedRanges.contains { NSIntersectionRange($0, r).length > 0 }
        }
        /// Ranges the regex/text passes scan (edited paragraphs, or whole doc).
        var scanRanges: [NSRange] { scopedRanges ?? [fullRange] }
    }

    // MARK: - Blocks

    private static func styleBlock(_ block: BlockNode, font: NSFont, ctx: Ctx, into attrs: inout [StyledRange]) {
        switch block {
        case .paragraph(_, let inlines):
            styleInlines(inlines, font: font, ctx: ctx, into: &attrs)

        case .heading(let level, let range, let markers, let inlines):
            let multiplier = ctx.config.headings.fontMultiplier(for: level)
            let headingBase = NSFont(name: ctx.fontName, size: ctx.baseFont.pointSize * multiplier)
                ?? .systemFont(ofSize: ctx.baseFont.pointSize * multiplier)
            let headingFont = adding(.bold, to: headingBase)
            let lineHeight = ceil(headingFont.ascender - headingFont.descender + headingFont.leading) + 1
            let headingPara = NSMutableParagraphStyle()
            headingPara.minimumLineHeight = lineHeight
            headingPara.maximumLineHeight = lineHeight
            headingPara.paragraphSpacingBefore = headingFont.pointSize * ctx.config.headings.topSpacingEm(for: level)
            headingPara.paragraphSpacing = ctx.baseParagraphSpacing
            attrs.append((ctx.ns.paragraphRange(for: range), [.paragraphStyle: headingPara]))
            attrs.append((range, [.font: headingFont]))
            for marker in markers {
                attrs.append((marker, [.foregroundColor: ctx.theme.headingMarker]))
            }
            styleInlines(inlines, font: headingFont, ctx: ctx, into: &attrs)

        case .blockquote(let range, let inlines):
            styleBlockquote(range: range, ctx: ctx, into: &attrs)
            styleInlines(inlines, font: font, ctx: ctx, into: &attrs)

        case .list(_, let items):
            for item in items {
                styleListItem(item, ctx: ctx, into: &attrs)
                styleInlines(item.inlines, font: font, ctx: ctx, into: &attrs)
            }

        case .codeBlock(let range):
            styleCodeBlock(range: range, ctx: ctx, into: &attrs)
        case .thematicBreak(let range):
            styleThematicBreak(range: range, ctx: ctx, into: &attrs)
        case .table(let range, let cells):
            // A rendered table is an image (MarkdownStyler+Tables); only the
            // REVEALED table shows its source, and that source is live markdown:
            // bold, italic, underline, code and links inside a cell style exactly
            // as they would in a paragraph.
            guard ctx.isActive(range) else { break }
            for cell in cells { styleInlines(cell.inlines, font: font, ctx: ctx, into: &attrs) }
        case .blockLatex, .blank:
            break   // NSImage rendering ported next
        }
    }

    /// Per-line blockquote: indent, mute content, hide/show `>` markers, tag first char with bar level.
    private static func styleBlockquote(range: NSRange, ctx: Ctx, into attrs: inout [StyledRange]) {
        let indentPerLevel = MarkdownTextLayoutFragment.blockquoteIndentPerLevel
        var lineStart = range.location
        let end = NSMaxRange(range)
        while lineStart < end {
            let line = ctx.ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let lineEnd = NSMaxRange(line)
            var i = line.location
            var indent = 0
            while i < lineEnd, indent < 3, ctx.ns.character(at: i) == 0x20 || ctx.ns.character(at: i) == 0x09 {
                i += 1; indent += 1
            }
            let markerStart = i
            var level = 0
            var j = i
            while j < lineEnd, ctx.ns.character(at: j) == 0x3E /* > */ {
                level += 1; j += 1
                if j < lineEnd, ctx.ns.character(at: j) == 0x20 || ctx.ns.character(at: j) == 0x09 { j += 1 }
            }
            defer { lineStart = lineEnd }
            guard level > 0 else { continue }

            var contentEnd = lineEnd
            if contentEnd > j {
                let last = ctx.ns.character(at: contentEnd - 1)
                if last == 0x0A || last == 0x0D { contentEnd -= 1 }
            }
            let markerRange = NSRange(location: markerStart, length: j - markerStart)
            let contentRange = NSRange(location: j, length: max(0, contentEnd - j))
            let tokenRange = NSRange(location: line.location, length: contentEnd - line.location)

            let textIndent = CGFloat(level) * indentPerLevel + indentPerLevel * 0.5
            let para = NSMutableParagraphStyle()
            para.firstLineHeadIndent = textIndent
            para.headIndent = textIndent
            para.minimumLineHeight = ctx.baseLineHeight
            para.maximumLineHeight = ctx.baseLineHeight
            // Inner quote lines stay tight (0); the LAST line gets the normal
            para.paragraphSpacing = (lineEnd >= end) ? ctx.baseParagraphSpacing : 0
            para.paragraphSpacingBefore = 0
            attrs.append((ctx.ns.paragraphRange(for: tokenRange), [.paragraphStyle: para]))

            if contentRange.length > 0 {
                attrs.append((contentRange, [.foregroundColor: ctx.theme.mutedText]))
            }
            if ctx.isActive(tokenRange) {
                attrs.append((markerRange, [.foregroundColor: ctx.theme.mutedText]))
            } else {
                attrs.append((markerRange, [.foregroundColor: NSColor.clear, .font: ctx.inlineMarkerFont]))
            }
            // Whole line, not just the first char, so each soft-wrapped visual line
            attrs.append((tokenRange, [.blockquoteLevel: level]))
        }
    }

    /// Above this content length, a fenced block being actively edited skips its
    /// per-keystroke re-highlight (see `styleCodeBlock`). Normal-sized blocks stay
    /// live-highlighted; only very large blocks — where the synchronous highlight.js
    /// bridge call is a visible hitch — defer to caret-exit. ~2500 chars is roughly the
    /// smallest block at which that per-keystroke bridge call becomes perceptible; raise
    /// it if live highlighting still feels fine on larger blocks on your hardware.
    private static let liveHighlightMaxLength = 2_500

    private static func styleCodeBlock(range: NSRange, ctx: Ctx, into attrs: inout [StyledRange]) {
        guard let fence = FencedCode.scan(in: ctx.ns, range: range) else { return }
        let isActive = ctx.isActive(range)
        attrs.append((fence.range, [
            .font: ctx.codeFont, .backgroundColor: ctx.codeBackground, .paragraphStyle: ctx.codeParagraphStyle,
        ]))
        // Suppress spell-check underlines on the whole fenced block — code is not prose.
        attrs.append((range, [.spellingState: 0]))
        attrs.append((fence.range, [.markdownCode: fence.isClosed ? 1 : 2]))

        // Syntax highlighting crosses the JavaScriptCore (highlight.js) bridge over the
        // WHOLE block, synchronously, every restyle. For normal blocks it's cheap enough
        // to keep live while typing; for a very large block being actively edited it's a
        // per-keystroke hitch, so skip it while the caret is inside and let it re-highlight
        // once on caret-exit. The scoped restyle keeps non-edited lines' prior colors.
        let deferHighlight = isActive && fence.content.length > Self.liveHighlightMaxLength
        if !deferHighlight {
            let codeContent = ctx.ns.substring(with: fence.content)
            if !codeContent.isEmpty,
               let highlighted = ctx.config.services.syntaxHighlighter.highlight(code: codeContent, language: fence.language(in: ctx.ns)),
               highlighted.length == fence.content.length {
                highlighted.enumerateAttributes(in: NSRange(location: 0, length: highlighted.length)) { a, r, _ in
                    guard let fg = a[.foregroundColor] else { return }
                    attrs.append((NSRange(location: fence.content.location + r.location, length: r.length), [.foregroundColor: fg]))
                }
            }
        }
        // Fence rows: the opening line, and the closing line through the block's
        // end (an unclosed fence has no closing line).
        if isActive {
            let markerAttrs: [NSAttributedString.Key: Any] = [.foregroundColor: ctx.theme.mutedText, .font: ctx.codeFont]
            attrs.append((fence.opening.line, markerAttrs))
            if let closing = fence.closingLine {
                let line = NSRange(location: closing.location, length: NSMaxRange(fence.range) - closing.location)
                attrs.append((line, markerAttrs))
            }
        } else {
            // Caret outside: the fence rows are the block's padding, not two
            // empty code lines. Each keeps the block's indents and background
            // and only its outer spacing (above the opening fence, below the
            // closing one). The glyphs are clear AND tiny: a full-size run
            // paints its own background over its typographic height, which
            // pokes out above a row clamped shorter than the font.
            let hidden = ctx.config.codeBlock.hiddenFenceHeight
            let open = NSMutableParagraphStyle(); open.setParagraphStyle(ctx.codeParagraphStyle)
            open.minimumLineHeight = hidden; open.maximumLineHeight = hidden; open.paragraphSpacing = 0
            let close = NSMutableParagraphStyle(); close.setParagraphStyle(ctx.codeParagraphStyle)
            close.minimumLineHeight = hidden; close.maximumLineHeight = hidden; close.paragraphSpacingBefore = 0
            attrs.append((fence.opening.line, [.foregroundColor: NSColor.clear, .font: ctx.inlineMarkerFont, .paragraphStyle: open]))
            if let closing = fence.closingLine {
                let line = NSRange(location: closing.location, length: NSMaxRange(fence.range) - closing.location)
                attrs.append((line, [.foregroundColor: NSColor.clear, .font: ctx.inlineMarkerFont, .paragraphStyle: close]))
            }
            // The hidden fence took the language with it: the first code line
            // carries it for the fragment to paint as a corner label.
            if let language = fence.language(in: ctx.ns)?.split(separator: " ").first, fence.content.length > 0 {
                let firstLine = ctx.ns.paragraphRange(for: NSRange(location: fence.content.location, length: 0))
                attrs.append((firstLine, [.codeBlockLanguage: String(language)]))
            }
        }
    }

    // MARK: - Inlines (composing)

    /// `syntheticOblique` = an ANCESTOR emphasis already requested italic in a
    /// family with no italic face (its overlay covers this subtree); nested
    /// emphasis re-applies the overlay after its own font append, mirroring
    /// the per-glyph re-apply below.
    private static func styleInlines(_ nodes: [InlineNode], font: NSFont, syntheticOblique: Bool = false, ctx: Ctx, into attrs: inout [StyledRange]) {
        for node in nodes {
            switch node {
            case .text:
                break

            case .emphasis(let kind, _, let markers, let children):
                let (composed, obliqueHere) = composing(traits(for: kind), with: font)
                let oblique = syntheticOblique || obliqueHere
                let contentRange = content(of: markers)
                attrs.append((contentRange, [.font: composed]))
                // ONE policy, ONE primitive: branch (a) shears the whole run
                // when the family has no italic face at all (CJK: PingFang /
                // Songti / Kaiti — the trait can't bind, bold still binds
                // through the composed font); branch (b) pins + shears the
                // cascade font on the italic run's uncovered subranges. Keyed
                // off the COMPOSED font — not the node kind — so a `**bold**`
                // nested inside italics re-applies the overlay its own font
                // append just clobbered (via the inherited `oblique` flag).
                for (r, overlay) in ItalicFallback.syntheticItalicOverlays(
                    forRun: composed, range: contentRange, in: ctx.ns, noItalicFace: oblique
                ) {
                    attrs.append((r, overlay))
                }
                styleInlines(children, font: composed, syntheticOblique: oblique, ctx: ctx, into: &attrs)

            case .strikethrough(_, let markers, let children):
                attrs.append((content(of: markers), [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: ctx.theme.strikethroughColor,
                ]))
                styleInlines(children, font: font, syntheticOblique: syntheticOblique, ctx: ctx, into: &attrs)

            case .underline(_, let markers, let children):
                attrs.append((content(of: markers), [
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]))
                styleInlines(children, font: font, syntheticOblique: syntheticOblique, ctx: ctx, into: &attrs)

            case .highlight(_, let markers, let children):
                attrs.append((content(of: markers), [.backgroundColor: ctx.theme.highlight]))
                styleInlines(children, font: font, syntheticOblique: syntheticOblique, ctx: ctx, into: &attrs)

            case .code(let range, let contentRange):
                // Inherit surrounding emphasis so `**\`code\`**` renders BOLD
                // monospace: this append lands AFTER the parent emphasis' font
                // append and would otherwise clobber it back to regular weight.
                let codeFont = adding(
                    font.fontDescriptor.symbolicTraits.intersection([.bold, .italic]),
                    to: ctx.codeFont
                )
                attrs.append((contentRange, [.font: codeFont, .backgroundColor: ctx.codeBackground]))
                // Suppress spell-check underlines on inline `code` spans (markers + content).
                attrs.append((range, [.spellingState: 0, .markdownCode: 1]))
                let markerAttrs: [NSAttributedString.Key: Any] = ctx.isActive(range)
                    ? [.foregroundColor: ctx.theme.mutedText, .font: ctx.codeFont]
                    : [.foregroundColor: ctx.theme.mutedText.withAlphaComponent(ctx.config.markers.inlineCodeMarkerAlpha),
                       .font: ctx.inlineMarkerFont]
                for marker in markers(of: range, content: contentRange) { attrs.append((marker, markerAttrs)) }

            case .link(let range, let textRange, let url, let markers, let children):
                styleLink(range: range, textRange: textRange, url: url, markers: markers, children: children, font: font, syntheticOblique: syntheticOblique, ctx: ctx, into: &attrs)

            case .wikiLink(let range, let name, let id, let markers):
                styleWikiLink(range: range, name: name, id: id, markers: markers, ctx: ctx, into: &attrs)

            case .image, .imageEmbed, .inlineLatex, .escape:
                break   // ported in later increments
            }
        }
    }

    private static func styleLink(
        range: NSRange, textRange: NSRange, url urlRange: NSRange, markers: [NSRange],
        children: [InlineNode], font: NSFont, syntheticOblique: Bool, ctx: Ctx, into attrs: inout [StyledRange]
    ) {
        attrs.append((range, [.spellingState: 0]))
        var urlString = InlineParser.decodedLinkDestination(in: ctx.ns, range: urlRange)
        // A bare `www.` host names a web page but carries no scheme to open.
        if urlString.lowercased().hasPrefix("www.") { urlString = "https://" + urlString }
        let isActive = ctx.isActive(range)
        if let url = URL(string: urlString) {
            if isActive {
                attrs.append((textRange, [
                    .foregroundColor: ctx.theme.link.withAlphaComponent(ctx.config.link.activeLinkAlpha),
                ]))
            } else {
                attrs.append((textRange, [
                    .link: url,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: ctx.theme.link,
                ]))
            }
        }
        for marker in markers { attrs.append((marker, [.foregroundColor: ctx.theme.mutedText])) }
        styleInlines(children, font: font, syntheticOblique: syntheticOblique, ctx: ctx, into: &attrs)
    }

    private static func styleWikiLink(
        range: NSRange, name: NSRange, id: NSRange?, markers: [NSRange], ctx: Ctx, into attrs: inout [StyledRange]
    ) {
        attrs.append((range, [.spellingState: 0]))
        let nodeName = ctx.ns.substring(with: name)
        let linkID = id.map { ctx.ns.substring(with: $0) } ?? ctx.wikiLinkID(range)
        var contentAttrs: [NSAttributedString.Key: Any] = [:]
        if let linkID { contentAttrs[.wikiLinkID] = linkID }
        if !ctx.isActive(range) {
            // Resolve by the stable UUID when present 
            let exists = ctx.config.services.wikiLinks.resolve(displayName: linkID ?? nodeName, range: name)?.exists ?? false
            if exists {
                contentAttrs[.link] = linkID ?? nodeName
            } else {
                contentAttrs[.foregroundColor] = ctx.theme.disabledText
            }
        }
        if !contentAttrs.isEmpty { attrs.append((name, contentAttrs)) }
        for marker in markers { attrs.append((marker, [.foregroundColor: ctx.theme.mutedText])) }
    }

    // MARK: - Marker shrinking (hide syntax of inactive nodes)

    /// Collapse inactive nodes' markers to a tiny kerned font so syntax vanishes; code/LaTeX skip themselves.
    private static func shrinkInactiveMarkers(in blocks: [BlockNode], ctx: Ctx, into attrs: inout [StyledRange]) {
        for block in blocks where ctx.inScope(block.range) {
            switch block {
            case .heading(_, let range, let markers, let inlines):
                if !ctx.isActive(range) { shrink(markers, ctx: ctx, into: &attrs) }
                shrinkInlineMarkers(inlines, ctx: ctx, into: &attrs)
            case .paragraph(_, let inlines), .blockquote(_, let inlines):
                shrinkInlineMarkers(inlines, ctx: ctx, into: &attrs)
            case .list(_, let items):
                // Phase A: shrink only inline markers; the list marker is hidden by the bullet/task pass.
                for item in items { shrinkInlineMarkers(item.inlines, ctx: ctx, into: &attrs) }
            case .table(let range, let cells):
                // Revealed table only (a rendered one is collapsed whole).
                guard ctx.isActive(range) else { break }
                for cell in cells { shrinkInlineMarkers(cell.inlines, ctx: ctx, into: &attrs) }
            case .codeBlock, .blockLatex, .thematicBreak, .blank:
                break
            }
        }
    }

    /// Shrink inactive markers; an active ancestor reveals its whole subtree via `forceReveal`.
    private static func shrinkInlineMarkers(_ nodes: [InlineNode], ctx: Ctx, forceReveal: Bool = false, into attrs: inout [StyledRange]) {
        for node in nodes {
            switch node {
            case .emphasis(_, let range, let markers, let children):
                let active = forceReveal || ctx.isActive(range)
                if !active { shrink(markers, ctx: ctx, into: &attrs) }
                shrinkInlineMarkers(children, ctx: ctx, forceReveal: active, into: &attrs)
            case .strikethrough(let range, let markers, let children), .highlight(let range, let markers, let children):
                let active = forceReveal || ctx.isActive(range)
                if !active { shrink(markers, ctx: ctx, into: &attrs) }
                shrinkInlineMarkers(children, ctx: ctx, forceReveal: active, into: &attrs)
            case .underline(let range, let markers, let children):
                let active = forceReveal || ctx.isActive(range)
                if !active { shrink(markers, ctx: ctx, into: &attrs) }
                shrinkInlineMarkers(children, ctx: ctx, forceReveal: active, into: &attrs)
            case .link(let range, _, _, let markers, let children):
                let active = forceReveal || ctx.isActive(range)
                if !active {
                    shrink(markers, ctx: ctx, into: &attrs)
                    if markers.count >= 4 {   // also hide the "(url)" run
                        let hide = NSRange(location: markers[2].location,
                                           length: NSMaxRange(markers[3]) - markers[2].location)
                        attrs.append((hide, [.font: ctx.inlineMarkerFont, .foregroundColor: NSColor.clear]))
                    }
                }
                shrinkInlineMarkers(children, ctx: ctx, forceReveal: active, into: &attrs)
            case .wikiLink(let range, _, let id, let markers):
                if !(forceReveal || ctx.isActive(range)) {
                    shrink(markers, ctx: ctx, into: &attrs)
                    if let id {
                        let suffix = NSRange(location: id.location - 1, length: id.length + 1)
                        attrs.append((suffix, [.font: ctx.inlineMarkerFont, .foregroundColor: NSColor.clear,
                                               .kern: -ctx.inlineMarkerFont.pointSize]))
                    }
                }
            case .image(let range, _, _, let markers):
                if !(forceReveal || ctx.isActive(range)) { shrink(markers, ctx: ctx, into: &attrs) }
            case .escape(let range, _, let marker):
                if !(forceReveal || ctx.isActive(range)) { shrink([marker], ctx: ctx, into: &attrs) }
            case .text, .code, .imageEmbed, .inlineLatex:
                break   // own marker handling / not shrunk
            }
        }
    }

    private static func shrink(_ markers: [NSRange], ctx: Ctx, into attrs: inout [StyledRange]) {
        for marker in markers {
            attrs.append((marker, [.font: ctx.inlineMarkerFont, .kern: -ctx.inlineMarkerFont.pointSize]))
        }
    }

    // MARK: - Helpers

    private static func traits(for kind: EmphasisKind) -> NSFontDescriptor.SymbolicTraits {
        switch kind {
        case .italic: return .italic
        case .bold: return .bold
        case .boldItalic: return [.bold, .italic]
        }
    }

    private static func adding(_ extra: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
        composing(extra, with: font).font
    }

    /// Trait composition through the ONE seam that survives families without
    /// an italic face — `syntheticOblique` = the slant could not bind and the
    /// caller must overlay `ItalicFallback.syntheticItalicOverlays` on the run.
    private static func composing(_ extra: NSFontDescriptor.SymbolicTraits, with font: NSFont) -> (font: NSFont, syntheticOblique: Bool) {
        let merged = font.fontDescriptor.symbolicTraits.union(extra)
        return ItalicFallback.resolveFont(
            traits: merged, descriptor: font.fontDescriptor, size: font.pointSize, fallback: font
        )
    }

    private static func content(of markers: [NSRange]) -> NSRange {
        let start = NSMaxRange(markers[0])
        return NSRange(location: start, length: markers[1].location - start)
    }

    /// The two backtick marker ranges of an inline code span (range minus content).
    private static func markers(of range: NSRange, content: NSRange) -> [NSRange] {
        [
            NSRange(location: range.location, length: content.location - range.location),
            NSRange(location: NSMaxRange(content), length: NSMaxRange(range) - NSMaxRange(content)),
        ]
    }
}
