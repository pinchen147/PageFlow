//
//  MarkdownStyler+Tables.swift
//  MarkdownEngine
//
//  GFM tables. The block is rendered to a single NSImage and emitted via
//  the same collapsedSource path block-LaTeX uses, so the source stays
//  in sync with the document but the user only sees the rendered grid
//  when the caret is outside the table.
//

import AppKit
import Foundation

extension MarkdownStyler {

    enum TableAlignment {
        case left
        case center
        case right
    }

    struct ParsedTable {
        let header: [String]
        let alignments: [TableAlignment]
        let rows: [[String]]
    }

    static func styleTables(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        // POSITIONAL identity: the Nth table in the document. A content-derived
        // ID churned on every edit inside a table, orphaning its overlay and
        // resetting its horizontal scroll (the ghost-grid class in the
        // 2026-07-03 field forensics). Counted over ALL tables — wideness is
        // only known for in-scope ones — and BEFORE the scope guard, so scoped
        // restyles and full passes always agree on a table's ordinal.
        var tableOrdinal = -1
        let coordinator = ctx.layoutBridge?.firstTextContainer?.textView?.delegate as? NativeTextViewCoordinator
        let editingSession = coordinator?.tableEditingSession
        // View-only column widths (doc 24 §7.3.6), looked up by table key only when some are set.
        let widthsByKey = coordinator?.editorController?.tableWidthsStore.widths ?? [:]
        let widthKeys: [Int: String]? = widthsByKey.isEmpty ? nil
            : NativeTextViewCoordinator.tableKeys(for: ctx.tablesWithIndex.map(\.token.range), in: ctx.nsText)
        for (idx, token) in ctx.tablesWithIndex {
            // Tokenizer already drops tables overlapping fenced code, so no re-check here.
            attrs.append((token.range, [.spellingState: 0]))
            tableOrdinal += 1

            // Skip the per-table MODEL PARSE + render for tables OUTSIDE the restyled
            // paragraphs. A scoped per-keystroke restyle must not parse + re-render
            // every table in the document; only the ordinal above advances for all
            // tables. The out-of-scope table keeps its already-applied attributes;
            // TextStylingService discards out-of-scope output anyway.
            guard ctx.inScope(token.range) else { continue }

            // A table stays rendered wherever the caret is (the reference editor): a caret
            // in its source edits a cell (+TableEntry). Only Edit Table Source
            // shows the Markdown, until the caret leaves the table.
            let isActive = ctx.activeTokenIndices.contains(idx) && editingSession?.owns(token.range) != true
                && editingSession?.isSourceRevealed(token.range) != false
            if isActive {
                // Only the explicit Source action exposes the complete Markdown.
                // Reset syntax concealed by the AST pass, retaining paragraph geometry.
                if editingSession?.isSourceRevealed(token.range) == true {
                    attrs.append((token.range, [.font: ctx.baseFont,
                                                .foregroundColor: ctx.configuration.theme.bodyText, .kern: 0]))
                }
                // Caret inside the table — the source is shown and edited in
                // place. Its inline markup (bold, italic, underline, code, links)
                // was styled by MarkdownASTStyler like any paragraph; this pass
                // only mutes each `|` so the structure stays legible.
                let muted = ctx.configuration.theme.mutedText
                let end = NSMaxRange(token.range)
                var i = token.range.location
                while i < end {
                    if ctx.nsText.character(at: i) == 0x7C {   // '|'
                        attrs.append((NSRange(location: i, length: 1), [.foregroundColor: muted]))
                    }
                    i += 1
                }
                continue
            }

            let source = ctx.nsText.substring(with: token.range)
            let columnWidths = widthKeys.flatMap { keys in widthsByKey[keys[token.range.location] ?? ""] } ?? []

            let renderAppearance = ctx.layoutBridge?.firstTextContainer?.textView?.effectiveAppearance
                ?? NSAppearance.currentDrawing()
            var image: NSImage?
            PerfTrace.time("tables.image") {
                renderAppearance.performAsCurrentDrawingAppearance {
                    let theme = ctx.configuration.theme
                    let cacheKey = TableImageCache.Key(
                        source: source, font: ctx.baseFont, appearance: renderAppearance,
                        colors: [theme.bodyText, theme.mutedText, ctx.codeBackgroundColor,
                                 theme.tableHeaderFill, theme.tableHeaderText, theme.tableBorder],
                        widths: columnWidths, latex: ctx.services.latex
                    )
                    image = TableImageCache.image(for: cacheKey) {
                        // A warm image needs no table-model or cell parsing.
                        var model: MarkdownTableModel?
                        PerfTrace.time("tables.model") { model = MarkdownTableModel.parse(source) }
                        guard let model else { return nil }
                        var parsed: ParsedTable!
                        PerfTrace.time("tables.parsed") { parsed = parsedTable(from: model) }
                        return renderTable(
                            parsed, baseFont: ctx.baseFont, theme: ctx.configuration.theme,
                            codeBackgroundColor: ctx.codeBackgroundColor, latex: ctx.services.latex,
                            appearance: renderAppearance, columnWidths: columnWidths
                        )
                    }
                }
            }
            guard let image else { continue }
            var imageBounds = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
            // Plain inline rendering: a narrow table is a static image that occupies
            // its own paragraph in the text flow, so it can never drift or overlap
            // the following text. Only a genuinely wide table falls back to the
            // horizontal-scroll overlay. Either way, clicking a cell mounts the
            // in-place cell editor (`MarkdownTableEditingSession`) over the image.
            //
            // "Wide" means wider than the zoom-aware EFFECTIVE width (ADR-0019)
            // — identical to the prose column at magnification 1. Under
            // zoom-out a table that fits the effective width renders INLINE,
            // spilling into the grown container on the text layer itself
            // (blockImageDrawRect centers + clamps it) — buttery scrolling, no
            // overlay; only a table too wide even for the zoomed-out window
            // keeps the horizontal-scroll overlay.
            let fitWidth = effectiveContainerWidth(for: ctx)
            var isWide = image.size.width > fitWidth + 0.5
            // Paper can't scroll: a wide table prints scaled down to the page.
            if isWide, (ctx.layoutBridge?.firstTextContainer?.textView as? NativeTextView)?.rendersForPrint == true {
                imageBounds.size = CGSize(width: fitWidth, height: image.size.height * fitWidth / image.size.width)
                isWide = false
            }
            let mode: RenderedStandaloneBlockMode
            if isWide {
                // the reference editor's lane: a table wider than the column that still fits
                // the editor's width shows whole, with no scroller strip under it.
                let fitsLane = (ctx.layoutBridge?.firstTextContainer?.textView as? NativeTextView)?
                    .wideTableLaneFits(width: image.size.width) ?? false
                mode = .collapsedSourceScrollable(
                    markerTexts: [],
                    displayWidth: fitWidth,
                    sourceID: tableOrdinal,
                    reservesScroller: !fitsLane
                )
            } else {
                mode = .collapsedSource(markerTexts: [])
            }
            let gaps = tableGaps(around: token.range, ctx: ctx)
            _ = appendRenderedStandaloneBlock(
                for: token,
                rawContent: source,
                image: image,
                imageBounds: imageBounds,
                paragraphSpacingBefore: gaps.before,
                paragraphSpacing: gaps.after,
                alignment: .left,
                mode: mode,
                ctx: ctx,
                attrs: &attrs
            )
        }
        return attrs
    }

    /// the reference editor's rhythm around a table (doc 24 §5.1.4), for body size b:
    /// 16 + max(2, 0.6 b) from the text above to the top border and 10 + 0.6 b
    /// from the bottom border to the text below (25.6 and 19.6 at 16 pt). A
    /// blank separator line already spaces the table at least that far, so the
    /// table adds nothing next to one.
    static func tableGaps(around range: NSRange, ctx: StylingContext) -> (before: CGFloat, after: CGFloat) {
        let body = ctx.baseFont.pointSize
        let above = 16 + max(2, 0.6 * body)
        let below = 10 + 0.6 * body
        func isBlankLine(at location: Int) -> Bool {
            guard location >= 0, location < ctx.nsText.length else { return true }
            let line = ctx.nsText.lineRange(for: NSRange(location: location, length: 0))
            return ctx.nsText.substring(with: line).allSatisfy(\.isWhitespace)
        }
        // The paragraph above already ends with its own spacing.
        let precedingSpacing = ceil(ctx.baseDefaultLineHeight * ctx.configuration.paragraph.spacingFactor)
        let before = range.location == 0 || isBlankLine(at: range.location - 1) ? 0 : max(0, above - precedingSpacing)
        let end = contentEnd(of: range, in: ctx.nsText)
        let nextLine = end < ctx.nsText.length ? NSMaxRange(ctx.nsText.lineRange(for: NSRange(location: end, length: 0))) : end
        let after = nextLine >= ctx.nsText.length || isBlankLine(at: nextLine) ? 0 : below
        return (before, after)
    }

    private static func contentEnd(of range: NSRange, in text: NSString) -> Int {
        var end = NSMaxRange(range)
        while end > range.location, [0x0A, 0x0D].contains(text.character(at: end - 1)) { end -= 1 }
        return end
    }

    // MARK: - Parsing

    static func parsedTable(from model: MarkdownTableModel) -> ParsedTable {
        ParsedTable(
            header: model.header,
            alignments: model.alignments.map(tableAlignment),
            rows: model.rows
        )
    }

    private static func tableAlignment(from alignment: MarkdownTableAlignment) -> TableAlignment {
        switch alignment {
        case .left:
            return .left
        case .center:
            return .center
        case .right:
            return .right
        }
    }

    // MARK: - Inline-formatted cell strings

    /// Raw cell → `NSAttributedString`: inline markdown applied, markers stripped, LaTeX as attachments.
    static func formattedCellString(
        _ raw: String,
        baseFont: NSFont,
        header: Bool,
        theme: MarkdownEditorTheme,
        codeBackgroundColor: NSColor,
        latex: any LatexRenderer
    ) -> NSAttributedString {
        let descriptor = baseFont.fontDescriptor
        let pointSize = baseFont.pointSize
        let codeFont = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        // the reference editor sets the header in regular weight, in its own color.
        let startFont = baseFont
        let out = NSMutableAttributedString()
        appendInlineCell(
            InlineParser.parse(raw), in: raw as NSString, into: out,
            font: startFont, baseDescriptor: descriptor, pointSize: pointSize,
            codeFont: codeFont, theme: theme, codeBackgroundColor: codeBackgroundColor, latex: latex
        )
        // CJK italic: glyphs the italic face can't cover get the cascade shear
        // through the shared ItalicFallback primitive (branch (b)).
        ItalicFallback.applyToItalicRuns(in: out)
        styleBareLinks(in: out, theme: theme)
        if header, out.length > 0 {
            // Header text takes the header color; links keep theirs.
            out.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: out.length)) { value, range, _ in
                if (value as? NSColor) === theme.bodyText { out.addAttribute(.foregroundColor, value: theme.tableHeaderText, range: range) }
            }
        }
        return out
    }

    /// A code span's font in a cell: `codeFont`, with the bold or italic of
    /// the emphasis around it (`font`), as the live-preview styler does.
    static func cellCodeFont(_ codeFont: NSFont, inheriting font: NSFont) -> NSFont {
        let inherited = font.fontDescriptor.symbolicTraits.intersection([.bold, .italic])
        guard !inherited.isEmpty else { return codeFont }
        return NSFont(
            descriptor: codeFont.fontDescriptor.withSymbolicTraits(codeFont.fontDescriptor.symbolicTraits.union(inherited)),
            size: codeFont.pointSize
        ) ?? codeFont
    }

    /// A link's text in a cell, drawn or edited: link color, underlined.
    static func cellLinkAttributes(theme: MarkdownEditorTheme) -> [NSAttributedString.Key: Any] {
        [.foregroundColor: theme.link, .underlineStyle: NSUnderlineStyle.single.rawValue]
    }

    /// Compose `current`'s bold/italic traits with `kind` so nested emphasis
    /// stacks (italic+bold). `syntheticOblique` = the family has no italic
    /// face — the caller overlays `ItalicFallback.syntheticItalicOverlays` on the run
    /// (bold still binds; see ItalicFallback.resolveFont).
    private static func composeEmphasis(
        _ current: NSFont, _ kind: EmphasisKind,
        baseDescriptor: NSFontDescriptor, pointSize: CGFloat
    ) -> (font: NSFont, syntheticOblique: Bool) {
        var traits = current.fontDescriptor.symbolicTraits.intersection([.bold, .italic])
        switch kind {
        case .bold: traits.insert(.bold)
        case .italic: traits.insert(.italic)
        case .boldItalic: traits.formUnion([.bold, .italic])
        }
        return ItalicFallback.resolveFont(
            traits: traits, descriptor: baseDescriptor, size: pointSize, fallback: current
        )
    }

    /// Walk the inline AST into marker-stripped runs; LaTeX as attachments, images as meaningful labels.
    private static func appendInlineCell(
        _ nodes: [InlineNode],
        in ns: NSString,
        into out: NSMutableAttributedString,
        font: NSFont,
        baseDescriptor: NSFontDescriptor,
        pointSize: CGFloat,
        codeFont: NSFont,
        theme: MarkdownEditorTheme,
        codeBackgroundColor: NSColor,
        latex: any LatexRenderer
    ) {
        func recurse(_ children: [InlineNode], _ f: NSFont) {
            appendInlineCell(children, in: ns, into: out, font: f, baseDescriptor: baseDescriptor,
                             pointSize: pointSize, codeFont: codeFont, theme: theme,
                             codeBackgroundColor: codeBackgroundColor, latex: latex)
        }
        func appendPlain(_ range: NSRange, _ f: NSFont) {
            out.append(NSAttributedString(string: ns.substring(with: range),
                                          attributes: [.font: f, .foregroundColor: theme.bodyText]))
        }
        /// the reference editor draws `<br>`, `<br/>` and `<br />` in a cell as a line break.
        func appendText(_ range: NSRange, _ f: NSFont) {
            let text = ns.substring(with: range)
            guard text.contains("<") else { return appendPlain(range, f) }
            let broken = Self.lineBreakTag.stringByReplacingMatches(
                in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "\u{2028}"
            )
            out.append(NSAttributedString(string: broken, attributes: [.font: f, .foregroundColor: theme.bodyText]))
        }
        /// Links in a cell look like links in prose: link color, underlined.
        func styleAsLink(from start: Int) {
            guard out.length > start else { return }
            out.addAttributes(cellLinkAttributes(theme: theme), range: NSRange(location: start, length: out.length - start))
        }
        for node in nodes {
            switch node {
            case .text(let r):
                appendText(r, font)
            case .escape(_, let character, _):
                appendPlain(character, font)
            case .emphasis(let kind, _, _, let children):
                let (composed, syntheticOblique) = composeEmphasis(font, kind, baseDescriptor: baseDescriptor, pointSize: pointSize)
                let start = out.length
                recurse(children, composed)
                // Post-order, so this outer overlay lands over every nested
                // run too — once the slant can't bind it stays synthetic for
                // the whole subtree. Per-RUN shear (not a blanket font), so
                // nested bold/code fonts keep their faces and only gain the
                // slanted matrix.
                if syntheticOblique, out.length > start {
                    ItalicFallback.shearFontRuns(
                        in: out,
                        range: NSRange(location: start, length: out.length - start)
                    )
                }
            case .strikethrough(_, _, let children):
                let start = out.length
                recurse(children, font)
                if out.length > start {
                    out.addAttributes([
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .strikethroughColor: theme.bodyText
                    ], range: NSRange(location: start, length: out.length - start))
                }
            case .highlight(_, _, let children):
                let start = out.length
                recurse(children, font)
                if out.length > start {
                    out.addAttribute(.backgroundColor, value: theme.highlight,
                                     range: NSRange(location: start, length: out.length - start))
                }
            case .underline(_, _, let children):
                let start = out.length
                recurse(children, font)
                if out.length > start {
                    out.addAttribute(
                        .underlineStyle,
                        value: NSUnderlineStyle.single.rawValue,
                        range: NSRange(location: start, length: out.length - start)
                    )
                }
            case .code(_, let content):
                out.append(NSAttributedString(string: ns.substring(with: content), attributes: [
                    .font: cellCodeFont(codeFont, inheriting: font), .backgroundColor: codeBackgroundColor,
                    .foregroundColor: theme.bodyText
                ]))
            case .inlineLatex(let range, let content, _):
                // Scalable when the renderer can: the grid draws scaled under zoom.
                let source = ns.substring(with: content)
                if let entry = latex.renderScalable(latex: source, fontSize: pointSize, theme: theme)
                    ?? latex.render(latex: source, fontSize: pointSize, theme: theme) {
                    let attachment = NSTextAttachment()
                    attachment.image = entry.image
                    // `baselineOffset` is the formula's descent below the baseline;
                    // an attachment's origin is measured upward, so it is negated
                    // (the editor's own drawing puts the bottom `descent` below too).
                    attachment.bounds = CGRect(x: 0, y: -entry.baselineOffset,
                                               width: entry.size.width, height: entry.size.height)
                    out.append(NSAttributedString(attachment: attachment))
                } else {
                    appendPlain(range, font)   // renderer unavailable → keep raw `$…$`
                }
            case .link(_, _, let url, _, let children):
                let start = out.length
                recurse(children, font)
                styleAsLink(from: start)
                // Where the link goes, for the pointer and ⌘-click over the drawn cell.
                if out.length > start {
                    out.addAttribute(tableCellLink, value: InlineParser.decodedLinkDestination(in: ns, range: url),
                                     range: NSRange(location: start, length: out.length - start))
                }
            case .wikiLink(_, let name, _, _):
                let start = out.length
                appendPlain(name, font)
                styleAsLink(from: start)
                // The target, for ⌘-click: it goes to the host as a prose wiki-link does.
                if out.length > start {
                    out.addAttribute(tableCellWikiLink, value: ns.substring(with: name),
                                     range: NSRange(location: start, length: out.length - start))
                }
            case .image(_, let alt, let destination, _):
                let description = ImageAltTokens.parse(ns.substring(with: alt)).displayDescription
                let label = description.isEmpty ? InlineParser.decodedLinkDestination(in: ns, range: destination) : description
                out.append(NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: theme.bodyText]))
            case .imageEmbed(_, let target, _):
                let raw = ns.substring(with: target)
                let name = ImageEmbedReference(content: raw)?.name ?? ImageAltTokens.parse(raw).displayDescription
                out.append(NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: theme.bodyText]))
            }
        }
    }

    /// `<br>`, `<br/>` or `<br />` (any case), the line breaks GFM table cells allow.
    static let lineBreakTag = SemanticTableCellCodec.lineBreakTag

    private static let cellLinkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Bare URLs, domains and e-mail addresses in a cell's text runs, styled
    /// as links; code spans and the `excluded` ranges stay as they are.
    static func styleBareLinks(in out: NSMutableAttributedString, theme: MarkdownEditorTheme, excluding excluded: [NSRange] = []) {
        let text = out.string
        guard text.contains("://") || text.contains("@") || text.contains("."), let detector = cellLinkDetector else { return }
        detector.enumerateMatches(in: text, range: NSRange(location: 0, length: out.length)) { match, _, _ in
            guard let range = match?.range, range.length > 0,
                  !excluded.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { return }
            var inCode = false
            out.enumerateAttribute(.backgroundColor, in: range) { value, _, stop in
                if value != nil { inCode = true; stop.pointee = true }
            }
            guard !inCode else { return }
            out.addAttributes(cellLinkAttributes(theme: theme), range: range)
            if out.attribute(tableCellLink, at: range.location, effectiveRange: nil) == nil, let url = match?.url {
                out.addAttribute(tableCellLink, value: url.absoluteString, range: range)
            }
        }
    }

    /// A drawn cell's link destination (a `String`), on the link's text. It
    /// draws nothing: the pointer and ⌘-click read it.
    static let tableCellLink = NSAttributedString.Key("PageFlowTableCellLink")

    /// A drawn cell's wiki-link target (a `String`, the text before any `|`),
    /// on its text. Like `tableCellLink`, read by the pointer and ⌘-click.
    static let tableCellWikiLink = NSAttributedString.Key("PageFlowTableCellWikiLink")

    // MARK: - Rendering

    static func renderTable(
        _ table: ParsedTable,
        baseFont: NSFont,
        theme: MarkdownEditorTheme,
        codeBackgroundColor: NSColor,
        latex: any LatexRenderer,
        appearance: NSAppearance,
        columnWidths: [CGFloat?] = []
    ) -> NSImage {
        MarkdownTableLayout(table: table, font: baseFont, theme: theme, codeBackground: codeBackgroundColor, latex: latex,
                            appearance: appearance, columnWidths: columnWidths).image()
    }

    // MARK: - Scrollable table helpers

    /// Container width with fallback chain for "styler runs before layout" case.
    /// Under visual magnification the EFFECTIVE width wins: the clip view's
    /// bounds grow as the user zooms out, and width-fitted blocks (tables,
    /// diagrams, images) target that so a wide table or big diagram can use the
    /// whole window instead of the stale prose-column width (ADR-0019).
    static func effectiveContainerWidth(for ctx: StylingContext) -> CGFloat {
        if let fitWidth = (ctx.layoutBridge?.firstTextContainer?.textView as? NativeTextView)?.zoomedBlockFitWidth {
            return fitWidth
        }
        return inlineColumnWidth(for: ctx)
    }

    /// The prose column's wrap width — the widest an INLINE-drawn block image
    /// can be (fragment drawing is clipped to the text view), regardless of
    /// magnification. Wider content needs the scrollable-overlay path, whose
    /// display band uses ``effectiveContainerWidth(for:)`` instead.
    static func inlineColumnWidth(for ctx: StylingContext) -> CGFloat {
        if let container = ctx.layoutBridge?.firstTextContainer {
            let raw = container.size.width
            if raw.isFinite, raw > 0, raw < 100_000 { return raw }
            if let textView = container.textView {
                let inset = textView.textContainerInset
                let usable = textView.bounds.width - inset.width * 2
                if usable.isFinite, usable > 0 { return usable }
                let frameUsable = textView.frame.width - inset.width * 2
                if frameUsable.isFinite, frameUsable > 0 { return frameUsable }
            }
        }
        return 500
    }

}


/// What styling keeps between notes and across all of them.
public enum MarkdownSharedCaches {
    /// Gives back what's kept for notes no longer open, or under memory pressure.
    /// All of it is made again when next asked for.
    public static func release() {
        TableImageCache.removeAll()
        MarkdownASTStyler.releaseLinkDetector()
    }
}

/// Recent table images, bounded by count and by the estimated memory of the
/// layouts they draw from (a table image keeps no bitmap, see
/// `MarkdownTableLayout.image()`).
enum TableImageCache {
    /// Which LaTeX renderer drew a table's math. A class renderer is that
    /// instance, held so its identity cannot be reused; a value renderer is
    /// its value when it is `Hashable`, or its type when it stores nothing.
    /// Any other value renderer may carry state the key cannot see.
    struct RendererIdentity: Hashable {
        private let instance: AnyObject?
        private let identity: AnyHashable

        init?(_ renderer: any LatexRenderer) {
            if type(of: renderer) is AnyClass {
                let object = renderer as AnyObject
                instance = object
                identity = AnyHashable(ObjectIdentifier(object))
            } else if let value = renderer as? any Hashable {
                instance = nil
                identity = AnyHashable(value)
            } else if Self.storesNothing(renderer) {
                instance = nil
                identity = AnyHashable(ObjectIdentifier(type(of: renderer)))
            } else {
                return nil
            }
        }

        private static func storesNothing<Renderer: LatexRenderer>(_ renderer: Renderer) -> Bool {
            MemoryLayout<Renderer>.size == 0
        }

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
        func hash(into hasher: inout Hasher) { hasher.combine(identity) }
    }

    struct Key: Hashable {
        let source: [UInt16]
        let fontDescriptor: NSFontDescriptor
        let fontSize: CGFloat
        let appearance: String
        let colors: [CGFloat]

        let widths: [CGFloat]
        /// The math renderer, for a source that may hold math.
        let renderer: RendererIdentity?

        init?(source: String, font: NSFont, appearance: NSAppearance, colors: [NSColor], widths: [CGFloat?] = [],
              latex: any LatexRenderer) {
            if source.contains("$") {
                guard let renderer = RendererIdentity(latex) else { return nil }
                self.renderer = renderer
            } else {
                renderer = nil
            }
            self.widths = widths.map { $0 ?? -1 }
            var components: [CGFloat] = []
            for color in colors {
                guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
                components.append(contentsOf: [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent])
            }
            self.source = Array(source.utf16)
            self.fontDescriptor = font.fontDescriptor
            self.fontSize = font.pointSize
            self.appearance = appearance.name.rawValue
            self.colors = components
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(source.count)
            source.withUnsafeBufferPointer { buffer in
                hasher.combine(bytes: UnsafeRawBufferPointer(buffer))
            }
            hasher.combine(fontDescriptor)
            hasher.combine(fontSize)
            hasher.combine(appearance)
            hasher.combine(colors)
            hasher.combine(widths)
            hasher.combine(renderer)
        }
    }

    private struct Entry {
        let image: NSImage
        let cost: Int
        var lastUse: UInt64
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var images: [Key: Entry] = [:]
    nonisolated(unsafe) private static var totalCost = 0
    nonisolated(unsafe) private static var sequence: UInt64 = 0
    // Retain every table in a large note without letting wide edited revisions accumulate.
    private static let capacity = 512
    /// About 1.4 M characters of tables; a long edit of one big table keeps
    /// a few dozen old revisions at most.
    static let costLimit = 32 * 1_024 * 1_024
    /// Retained bytes per UTF-16 unit of table source: the key's copy (2) and
    /// the layout's formatted cells and measurements (15 measured on a
    /// 50 × 8 table of formatted prose), with headroom.
    static let bytesPerSourceUnit = 24

    /// An entry's estimated memory. The image draws on demand, so it holds
    /// no pixels; what it keeps grows with the source, not with its area.
    static func cost(of key: Key) -> Int {
        4_096 + key.source.count * bytesPerSourceUnit
    }

    static func image(for key: Key?, render: () -> NSImage?) -> NSImage? {
        guard let key else { return render() }
        lock.lock()
        if var hit = images[key] {
            sequence &+= 1
            hit.lastUse = sequence
            images[key] = hit
            lock.unlock()
            return hit.image
        }
        lock.unlock()
        guard let image = render() else { return nil }
        let cost = cost(of: key)
        guard cost <= costLimit else { return image }

        lock.lock()
        defer { lock.unlock() }
        if let hit = images[key] { return hit.image }
        while images.count >= capacity || totalCost + cost > costLimit {
            guard let oldest = images.min(by: { $0.value.lastUse < $1.value.lastUse })?.key,
                  let removed = images.removeValue(forKey: oldest) else { break }
            totalCost -= removed.cost
        }
        sequence &+= 1
        images[key] = Entry(image: image, cost: cost, lastUse: sequence)
        totalCost += cost
        return image
    }

    static func removeAll() {
        lock.lock()
        images.removeAll()
        totalCost = 0
        lock.unlock()
    }
}
