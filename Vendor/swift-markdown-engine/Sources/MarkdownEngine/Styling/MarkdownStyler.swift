//
//  MarkdownStyler.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Applies the Markdown look (bold, links, code, headings, etc.). Most styling
// is now produced by the AST-native styler (`MarkdownASTStyler`); this type
// builds the `StylingContext` and runs the NSImage rendering passes that still
// consume tokens:
//   - MarkdownStyler+Latex.swift   (block + inline LaTeX rendering)
//   - MarkdownStyler+Images.swift  (image embeds / image links)
//   - MarkdownStyler+Tables.swift  (rendered tables)
import AppKit
import Foundation

// MARK: - Styling Context

extension MarkdownStyler {
    struct StylingContext {
        let nsText: NSString
        let tokens: [MarkdownToken]
        let codeTokens: [MarkdownToken]
        let activeTokenIndices: Set<Int>
        let baseFont: NSFont
        let layoutBridge: LayoutBridge?
        let baseDefaultLineHeight: CGFloat
        let codeBackgroundColor: NSColor
        let latexMarkerFont: NSFont
        let configuration: MarkdownEditorConfiguration
        /// The paragraph ranges being restyled, or nil for a full-document pass.
        let scopedRanges: [NSRange]?

        /// Render-pass inputs categorized ONCE (and scope-filtered for latex/image),
        /// so the five NSImage passes iterate tiny lists instead of re-scanning every
        /// token in the document each. Each entry keeps the token's ORIGINAL index
        /// into `tokens` so `activeTokenIndices` membership checks stay valid.
        let scopedBlockLatex: [(index: Int, token: MarkdownToken)]
        let scopedInlineLatex: [(index: Int, token: MarkdownToken)]
        let scopedImageLinks: [(index: Int, token: MarkdownToken)]
        let scopedImageEmbeds: [(index: Int, token: MarkdownToken)]
        /// Fenced code blocks whose info-string language is a rendered diagram
        /// language (`configuration.diagramLanguages`, e.g. `mermaid`). Carries
        /// the pre-resolved lowercased language so ``styleMermaidBlock`` doesn't
        /// re-extract/re-bridge it. Scope-filtered like the LaTeX/image lists.
        let scopedMermaid: [(index: Int, token: MarkdownToken, language: String)]
        /// All tables (NOT scope-filtered — the table pass needs every table for a
        /// stable occurrence counter, then scope-gates the render itself).
        let tablesWithIndex: [(index: Int, token: MarkdownToken)]
        let tableRanges: [NSRange]
        let blockquoteRanges: [NSRange]
        /// All heading tokens, for LaTeX font-size lookup (a formula inside a heading
        /// scales to it). Headings are few, so this stays small.
        let headingTokens: [MarkdownToken]

        var services: MarkdownEditorServices { configuration.services }

        /// True when `range` intersects a restyled paragraph (or when there is no
        /// scope — a full-document pass). The NSImage render passes gate their
        /// expensive per-token work (heading-size lookup, substring extraction,
        /// image render) on this: a token outside the restyled paragraphs has its
        /// output discarded by `TextStylingService.restyle` anyway, so on a large
        /// document this keeps a per-keystroke restyle O(edit) instead of
        /// O(all-tokens).
        func inScope(_ range: NSRange) -> Bool {
            guard let scopedRanges else { return true }
            for scoped in scopedRanges where NSIntersectionRange(scoped, range).length > 0 {
                return true
            }
            return false
        }
    }
}

typealias StyledRange = (range: NSRange, attributes: [NSAttributedString.Key: Any])

// MARK: - Public API

enum MarkdownStyler {

    /// Range-valued anchor attributes whose payload is stored ANCHOR-RELATIVE
    /// (see `AnchorRelativeRange`) so it survives edits above the block. Every
    /// future range-valued anchor key MUST be added here, or its range is
    /// silently stored as an un-rebased absolute range. Consumed by the anchor
    /// rebase pass below.
    static let anchorRelativeRangeKeys: Set<NSAttributedString.Key> = [
        .scrollableBlockFullRange,
        .markdownTableSourceRange
    ]

    static func styleAttributes(
        text: String,
        fontName: String,
        fontSize: CGFloat,
        layoutBridge: LayoutBridge? = nil,
        caretLocation: Int,
        activeTokenIndices: Set<Int>,
        wikiLinkIDProvider: @escaping (NSRange) -> String? = { _ in nil },
        precomputedTokens: [MarkdownToken]? = nil,
        scopedRanges: [NSRange]? = nil,
        configuration: MarkdownEditorConfiguration = .default
    ) -> [StyledRange] {
        let tokens = precomputedTokens ?? MarkdownTokenizer.parseTokensViaAST(in: text)
        let nsText = text as NSString

        // Categorize every render-pass input in ONE pass (scope-filtering latex/image
        // to the restyled paragraphs), instead of re-`filter`-ing all tokens inside
        // each of the five NSImage passes. Each kept entry carries its ORIGINAL token
        // index so the downstream `activeTokenIndices` checks stay correct. This is
        // the per-keystroke restyle hot path on large documents.
        func _inScope(_ r: NSRange) -> Bool {
            guard let scopedRanges else { return true }
            for s in scopedRanges where NSIntersectionRange(s, r).length > 0 { return true }
            return false
        }
        var codeTokens: [MarkdownToken] = []
        var scopedBlockLatex: [(index: Int, token: MarkdownToken)] = []
        var scopedInlineLatex: [(index: Int, token: MarkdownToken)] = []
        var scopedImageLinks: [(index: Int, token: MarkdownToken)] = []
        var scopedImageEmbeds: [(index: Int, token: MarkdownToken)] = []
        var scopedMermaid: [(index: Int, token: MarkdownToken, language: String)] = []
        var tablesWithIndex: [(index: Int, token: MarkdownToken)] = []
        var tableRanges: [NSRange] = []
        var blockquoteRanges: [NSRange] = []
        var headingTokens: [MarkdownToken] = []
        let diagramLanguages = configuration.diagramLanguages
        for (i, t) in tokens.enumerated() {
            switch t.kind {
            case .codeBlock:
                codeTokens.append(t)
                // A code block whose info-string names a diagram language is a
                // render candidate (reuses the same language helper the code-block
                // styler/coordinator use); the trailing `styleMermaidBlock` pass
                // collapses it to the diagram image when inactive.
                if _inScope(t.range), !diagramLanguages.isEmpty,
                   let language = MarkdownTokenizer.extractLanguage(from: t, in: text)?.lowercased(),
                   diagramLanguages.contains(language) {
                    scopedMermaid.append((i, t, language))
                }
            case .inlineCode: codeTokens.append(t)
            case .blockLatex: if _inScope(t.range) { scopedBlockLatex.append((i, t)) }
            case .inlineLatex: if _inScope(t.range) { scopedInlineLatex.append((i, t)) }
            case .imageLink: if _inScope(t.range) { scopedImageLinks.append((i, t)) }
            case .imageEmbed: if _inScope(t.range) { scopedImageEmbeds.append((i, t)) }
            case .table: tablesWithIndex.append((i, t)); tableRanges.append(t.range)
            case .blockquote: blockquoteRanges.append(t.range)
            case .heading: headingTokens.append(t)
            default: break
            }
        }
        let baseFont = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        let baseDefaultLineHeight = ceil(
            layoutBridge?.defaultLineHeight(for: baseFont)
            ?? (baseFont.ascender - baseFont.descender + baseFont.leading)
        )
        let codeBackgroundColor = configuration.services.syntaxHighlighter.backgroundColor()
        let hiddenMarkerSize = configuration.markers.hiddenMarkerFontSize
        let ctx = StylingContext(
            nsText: nsText,
            tokens: tokens,
            codeTokens: codeTokens,
            activeTokenIndices: activeTokenIndices,
            baseFont: baseFont,
            layoutBridge: layoutBridge,
            baseDefaultLineHeight: baseDefaultLineHeight,
            codeBackgroundColor: codeBackgroundColor,
            latexMarkerFont: NSFont(name: fontName, size: hiddenMarkerSize)
                ?? NSFont.systemFont(ofSize: hiddenMarkerSize),
            configuration: configuration,
            scopedRanges: scopedRanges,
            scopedBlockLatex: scopedBlockLatex,
            scopedInlineLatex: scopedInlineLatex,
            scopedImageLinks: scopedImageLinks,
            scopedImageEmbeds: scopedImageEmbeds,
            scopedMermaid: scopedMermaid,
            tablesWithIndex: tablesWithIndex,
            tableRanges: tableRanges,
            blockquoteRanges: blockquoteRanges,
            headingTokens: headingTokens
        )

        var result: [StyledRange] = []
        // AST-native styler handles everything but NSImage rendering (incl. the composition fixes).
        PerfTrace.time("ast") {
        result += MarkdownASTStyler.styleAttributes(
            text: text, fontName: fontName, fontSize: fontSize,
            caretLocation: caretLocation, wikiLinkIDProvider: wikiLinkIDProvider,
            scopedRanges: scopedRanges, configuration: configuration
        )
        }
        // NSImage rendering reuses the existing, proven machinery.
        PerfTrace.time("blockLatex") { result += styleBlockLatex(ctx) }
        PerfTrace.time("inlineLatex") { result += styleInlineLatex(ctx) }
        PerfTrace.time("imageEmbeds") { result += styleImageEmbeds(ctx) }
        PerfTrace.time("imageLinks") { result += styleImageLinks(ctx) }
        PerfTrace.time("tables") { result += styleTables(ctx) }
        PerfTrace.time("mermaid") { result += styleMermaidBlock(ctx) }
        return result
    }
}

// MARK: - Shared helpers used by multiple styling extensions

extension MarkdownStyler {

    static func appendSecondaryMarkers(
        for token: MarkdownToken,
        to attrs: inout [StyledRange],
        theme: MarkdownEditorTheme
    ) {
        token.markerRanges.forEach {
            attrs.append(($0, [.foregroundColor: theme.mutedText]))
        }
    }

    enum RenderedStandaloneBlockMode {
        case collapsedSource(markerTexts: [String])
        case visibleSource(imageGap: CGFloat)
        /// Wide-table mode: anchor reserves container width, line gains scroller strip, tagged by sourceID.
        case collapsedSourceScrollable(
            markerTexts: [String],
            displayWidth: CGFloat,
            sourceID: Int,
            /// False for a table that fits the reference editor's lane: nothing to scroll, no strip.
            reservesScroller: Bool = true
        )
    }

    static func appendRenderedStandaloneBlock(
        for token: MarkdownToken,
        rawContent: String,
        image: NSImage,
        imageBounds: CGRect,
        paragraphSpacingBefore: CGFloat,
        paragraphSpacing: CGFloat,
        alignment: NSTextAlignment,
        mode: RenderedStandaloneBlockMode,
        ctx: StylingContext,
        attrs: inout [StyledRange]
    ) -> Bool {
        guard let paraRange = token.standaloneParagraphRange(in: ctx.nsText) else { return false }

        let para = NSMutableParagraphStyle()
        let baseLineHeight = layoutBridgeDefaultLineHeight(for: ctx.baseFont, using: ctx.layoutBridge)
        para.paragraphSpacingBefore = max(para.paragraphSpacingBefore, paragraphSpacingBefore)
        para.alignment = alignment

        switch mode {
        case .collapsedSource(let markerTexts):
            emitCollapsedAttrs(
                token: token,
                rawContent: rawContent,
                image: image,
                imageBounds: imageBounds,
                paragraphSpacing: paragraphSpacing,
                para: para,
                paraRange: paraRange,
                advanceWidth: imageBounds.width,
                neededLineHeight: imageBounds.height,
                extraAnchorAttrs: token.kind == .table
                    ? [.markdownTableSourceRange: NSValue(range: token.range)] : [:],
                markerTexts: markerTexts,
                ctx: ctx,
                attrs: &attrs
            )

        case .collapsedSourceScrollable(let markerTexts, let displayWidth, let sourceID, let reservesScroller):
            let scrollerStrip = reservesScroller ? MarkdownTextLayoutFragment.scrollableBlockScrollerStrip : 0
            let totalHeight = imageBounds.height + scrollerStrip
            emitCollapsedAttrs(
                token: token,
                rawContent: rawContent,
                image: image,
                imageBounds: imageBounds,
                paragraphSpacing: paragraphSpacing,
                para: para,
                paraRange: paraRange,
                advanceWidth: displayWidth,
                neededLineHeight: totalHeight,
                extraAnchorAttrs: [
                    .scrollableBlockNaturalWidth: imageBounds.width,
                    .scrollableBlockSourceID: sourceID,
                    .scrollableBlockTotalHeight: totalHeight,
                    .scrollableBlockFullRange: NSValue(range: paraRange),
                    .markdownTableSourceRange: NSValue(range: token.range)
                ],
                markerTexts: markerTexts,
                ctx: ctx,
                attrs: &attrs
            )

        case .visibleSource(let imageGap):
            para.minimumLineHeight = max(para.minimumLineHeight, baseLineHeight)
            para.maximumLineHeight = max(para.maximumLineHeight, baseLineHeight)
            para.paragraphSpacing = max(para.paragraphSpacing, imageBounds.height + imageGap + paragraphSpacing)

            attrs.append((paraRange, [.paragraphStyle: para]))
            attrs.append((token.range, [
                .renderedBlockImage: image,
                .latexBounds: NSValue(rect: imageBounds),
                .latexIsBlock: true,
                .latexBlockOffsetY: baseLineHeight + imageGap
            ]))
            appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
        }

        return true
    }

    /// Shared body for collapsed-source modes; hides raw source, plants image on anchor.
    private static func emitCollapsedAttrs(
        token: MarkdownToken,
        rawContent: String,
        image: NSImage,
        imageBounds: CGRect,
        paragraphSpacing: CGFloat,
        para: NSMutableParagraphStyle,
        paraRange: NSRange,
        advanceWidth: CGFloat,
        neededLineHeight: CGFloat,
        extraAnchorAttrs: [NSAttributedString.Key: Any],
        markerTexts: [String],
        ctx: StylingContext,
        attrs: inout [StyledRange]
    ) {
        let baseLineHeight = layoutBridgeDefaultLineHeight(for: ctx.baseFont, using: ctx.layoutBridge)
        let resolved = max(para.minimumLineHeight, neededLineHeight, baseLineHeight)
        para.minimumLineHeight = resolved
        para.maximumLineHeight = max(para.maximumLineHeight, resolved)
        para.paragraphSpacing = max(para.paragraphSpacing, paragraphSpacing)
        para.lineBreakMode = .byClipping

        let collapsedPara = NSMutableParagraphStyle()
        collapsedPara.maximumLineHeight = 1
        collapsedPara.paragraphSpacing = 0
        collapsedPara.paragraphSpacingBefore = 0

        let leadingWhitespaceUnits = rawContent.utf16.prefix { codeUnit in
            guard let scalar = UnicodeScalar(UInt32(codeUnit)) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }.count
        let contentEnd = NSMaxRange(token.contentRange)
        let anchorLocation = min(token.contentRange.location + leadingWhitespaceUnits, contentEnd - 1)

        var paragraphAttributes: [StyledRange] = []
        ctx.nsText.enumerateSubstrings(in: paraRange, options: .byParagraphs) { _, _, enclosingRange, _ in
            if NSLocationInRange(anchorLocation, enclosingRange) {
                paragraphAttributes.append((enclosingRange, [.paragraphStyle: para]))
            } else {
                paragraphAttributes.append((enclosingRange, [.paragraphStyle: collapsedPara]))
            }
        }
        attrs.append(contentsOf: paragraphAttributes)

        if leadingWhitespaceUnits > 0 {
            let leadingRange = NSRange(location: token.contentRange.location, length: leadingWhitespaceUnits)
            let leadingText = ctx.nsText.substring(with: leadingRange)
            attrs.append((leadingRange, [
                .foregroundColor: NSColor.clear,
                .font: ctx.latexMarkerFont,
                .kern: -HeadingHelpers.hiddenRunWidth(leadingText, font: ctx.latexMarkerFont)
            ]))
        }

        let anchorRange = NSRange(location: anchorLocation, length: 1)
        let anchorChar = ctx.nsText.substring(with: anchorRange)
        var anchorAttrs: [NSAttributedString.Key: Any] = [
            .renderedBlockImage: image,
            .latexBounds: NSValue(rect: imageBounds),
            .latexIsBlock: true,
            .foregroundColor: NSColor.clear,
            .font: ctx.latexMarkerFont,
            .kern: advanceWidth - HeadingHelpers.textWidth(anchorChar, font: ctx.latexMarkerFont)
        ]
        for (key, value) in extraAnchorAttrs {
            // Range payloads are stored ANCHOR-RELATIVE so they survive edits
            // above the block (see AnchorRelativeRange). Rebased HERE — the one
            // place the anchor location is known at style time.
            if MarkdownStyler.anchorRelativeRangeKeys.contains(key),
               let absolute = value as? NSValue {
                anchorAttrs[key] = AnchorRelativeRange.encode(absolute.rangeValue, anchorLocation: anchorLocation)
            } else {
                anchorAttrs[key] = value
            }
        }
        attrs.append((anchorRange, anchorAttrs))

        let trailingStart = anchorLocation + 1
        let trailingLength = contentEnd - trailingStart
        if trailingLength > 0 {
            let trailingRange = NSRange(location: trailingStart, length: trailingLength)
            let trailingText = ctx.nsText.substring(with: trailingRange)
            attrs.append((trailingRange, [
                .foregroundColor: NSColor.clear,
                .font: ctx.latexMarkerFont,
                .kern: -HeadingHelpers.hiddenRunWidth(trailingText, font: ctx.latexMarkerFont)
            ]))
        }

        for (index, markerRange) in token.markerRanges.enumerated() {
            let markerText = markerTexts.indices.contains(index)
                ? markerTexts[index]
                : ctx.nsText.substring(with: markerRange)
            attrs.append((markerRange, [
                .foregroundColor: NSColor.clear,
                .font: ctx.latexMarkerFont,
                .kern: -HeadingHelpers.textWidth(markerText, font: ctx.latexMarkerFont)
            ]))
        }

        let preTokenLength = token.range.location - paraRange.location
        if preTokenLength > 0 {
            let preTokenRange = NSRange(location: paraRange.location, length: preTokenLength)
            let preTokenText = ctx.nsText.substring(with: preTokenRange)
            attrs.append((preTokenRange, [
                .foregroundColor: NSColor.clear,
                .font: ctx.latexMarkerFont,
                .kern: -HeadingHelpers.hiddenRunWidth(preTokenText, font: ctx.latexMarkerFont)
            ]))
        }
    }
}

// MARK: - Whole-document & inline-only styling kept inline (small helpers)

extension MarkdownStyler {

    /// Thematic-break (HR) line matcher, compiled once. `hrLineRange` runs on every
    /// caret move (twice — previous + current location), so the `.regularExpression`
    /// range search here used to recompile this pattern on each call.
    static let thematicBreakRegex: NSRegularExpression = try! NSRegularExpression(
        pattern: #"^[ \t]*(-{3,}|\*{3,}|_{3,})[ \t]*$"#,
        options: []
    )

    /// Line range if `location` is on a thematic-break line (3+ `-`/`*`/`_`), else nil; drives HR restyle.
    /// Takes `NSString` so the caller can bridge the document once per caret move.
    static func hrLineRange(at location: Int, in text: NSString) -> NSRange? {
        let safeLoc = max(0, min(location, text.length))
        let lineRange = text.lineRange(for: NSRange(location: safeLoc, length: 0))
        let line = text.substring(with: lineRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lineRangeForMatch = NSRange(location: 0, length: (line as NSString).length)
        guard thematicBreakRegex.firstMatch(in: line, options: [], range: lineRangeForMatch) != nil else {
            return nil
        }
        return lineRange
    }
}

