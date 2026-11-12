//
//  MarkdownStyler+Images.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Image (`![alt](url)`, `![[...]]`) styling and layout: size, alignment and
//  crop come from the alt tokens (`ImageAltTokens`).
//

import AppKit
import Foundation

extension MarkdownStyler {

    // MARK: Markdown Image Links ![alt](url)

    /// Style standalone `![alt](url)` paragraphs by routing the URL through
    /// the embedder's `EmbeddedImageProvider` (URL goes into the request's
    /// `name` field — providers that don't speak URLs simply return `nil`,
    /// at which point its meaningful alt text or destination remains visible).
    static func styleImageLinks(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for (_, token) in ctx.scopedImageLinks {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }

            // The URL lives between markerRanges[2] ('(') and markerRanges[3] (')').
            guard token.markerRanges.count >= 4 else {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                continue
            }
            let openParen = token.markerRanges[2]
            let closeParen = token.markerRanges[3]
            let urlStart = NSMaxRange(openParen)
            let urlLength = closeParen.location - urlStart
            guard urlLength > 0 else {
                appendImageFallback(for: token, label: imageFallbackLabel(for: token, ctx: ctx), ctx: ctx, attrs: &attrs)
                continue
            }
            let urlRange = NSRange(location: urlStart, length: urlLength)
            let url = ctx.nsText.substring(with: urlRange)

            // The provider gets the destination itself: no title, no `<…>`, escapes decoded.
            let destination = InlineParser.linkDestination(in: ctx.nsText, openParen: openParen.location) ?? url
            let request = EmbeddedImageRequest(name: destination)
            guard let image = ctx.services.images.image(for: request) else {
                appendImageFallback(for: token, label: imageFallbackLabel(for: token, ctx: ctx), ctx: ctx, attrs: &attrs)
                continue
            }

            // `![alt|center|crop=…|300](url)`: size, alignment and crop ride
            // in the alt text (doc 26 §2).
            let altRange = NSRange(location: NSMaxRange(token.markerRanges[0]),
                                   length: max(0, token.markerRanges[1].location - NSMaxRange(token.markerRanges[0])))
            let tokens = ImageAltTokens.parse(ctx.nsText.substring(with: altRange))
            let rendered = appendRenderedImage(
                for: token,
                rawContent: ctx.nsText.substring(with: token.range),
                image: image,
                tokens: tokens,
                markerTexts: ["![", "]", "(", ")"],
                ctx: ctx,
                attrs: &attrs
            )
            if rendered {
                // The standalone helper hides the alt text + the four
                // markers, but the URL between '(' and ')' is its own
                // range and stays visible unless we collapse it too.
                let urlText = ctx.nsText.substring(with: urlRange)
                attrs.append((urlRange, [
                    .foregroundColor: NSColor.clear,
                    .font: ctx.latexMarkerFont,
                    .kern: -HeadingHelpers.hiddenRunWidth(urlText, font: ctx.latexMarkerFont)
                ]))
            }
            if !rendered {
                appendImageFallback(for: token, label: imageFallbackLabel(for: token, ctx: ctx), ctx: ctx, attrs: &attrs)
            }
        }
        return attrs
    }

    // MARK: Image Embeds ![[Name]]

    static func styleImageEmbeds(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for (_, token) in ctx.scopedImageEmbeds {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }

            let rawContent = ctx.nsText.substring(with: token.contentRange)
            guard let reference = ImageEmbedReference(content: rawContent) else {
                appendImageFallback(for: token, label: imageFallbackLabel(for: token, ctx: ctx), ctx: ctx, attrs: &attrs)
                continue
            }

            if let image = EmbeddedImageCache.shared.image(for: reference, services: ctx.services) {
                let tokens = ImageAltTokens(width: reference.requestedWidth, alignment: reference.alignment, crop: reference.crop)
                let rendered = appendRenderedImage(
                    for: token,
                    rawContent: rawContent,
                    image: image,
                    tokens: tokens,
                    markerTexts: ["![[", "]]"],
                    ctx: ctx,
                    attrs: &attrs
                )
                if !rendered {
                    appendImageFallback(for: token, label: imageFallbackLabel(for: token, ctx: ctx), ctx: ctx, attrs: &attrs)
                }
            } else {
                appendImageFallback(for: token, label: imageFallbackLabel(for: token, ctx: ctx), ctx: ctx, attrs: &attrs)
            }
        }
        return attrs
    }

    private static func imageFallbackLabel(for token: MarkdownToken, ctx: StylingContext) -> NSRange {
        if token.kind == .imageLink, token.markerRanges.count >= 4 {
            let start = NSMaxRange(token.markerRanges[0])
            let alt = NSRange(location: start, length: max(0, token.markerRanges[1].location - start))
            let description = ImageAltTokens.parse(ctx.nsText.substring(with: alt)).description
            if !description.isEmpty { return NSRange(location: alt.location, length: description.utf16.count) }
            let urlStart = NSMaxRange(token.markerRanges[2])
            return NSRange(location: urlStart, length: max(0, token.markerRanges[3].location - urlStart))
        }
        let description = ImageAltTokens.parse(ctx.nsText.substring(with: token.contentRange)).description
        let length = description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : description.utf16.count
        return NSRange(location: token.contentRange.location, length: length)
    }

    private static func appendImageFallback(for token: MarkdownToken, label: NSRange,
                                            ctx: StylingContext, attrs: inout [StyledRange]) {
        attrs.append((token.range, [.foregroundColor: NSColor.clear, .font: ctx.latexMarkerFont,
                                   .kern: -ctx.latexMarkerFont.pointSize]))
        if label.length > 0 {
            attrs.append((label, [.foregroundColor: ctx.configuration.theme.disabledText,
                                 .font: ctx.baseFont, .kern: 0]))
        }
    }

    /// A standalone rich-body image, collapsed to its sized/cropped picture.
    private static func appendRenderedImage(
        for token: MarkdownToken,
        rawContent: String,
        image: NSImage,
        tokens: ImageAltTokens,
        markerTexts: [String],
        ctx: StylingContext,
        attrs: inout [StyledRange]
    ) -> Bool {
        let style = ctx.configuration.imageEmbed
        // Zoom-aware (ADR-0019): the same effective width the table/diagram
        // passes fit against. Under zoom-out the text VIEW spans that width,
        // so an image wider than the prose column spills inline exactly like
        // a table (blockImageDrawRect places + clamps it); the natural-size
        // cap still applies to an image without a width — images never upscale.
        let maxWidth: CGFloat = {
            let w = effectiveContainerWidth(for: ctx)
            if w > 0 && w < style.unreasonableMaxWidth { return w }
            return style.fallbackMaxWidth
        }()
        // A crop's kept part is the image's natural size from here on.
        let natural = tokens.croppedSize(of: image.size)
        let imageBounds = CGRect(origin: .zero,
                                 size: style.displaySize(natural: natural, requestedWidth: tokens.width, maxWidth: maxWidth))
        let alignment: NSTextAlignment = switch tokens.alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        var imageAttrs: [NSAttributedString.Key: Any] = [
            .blockImageCornerRadius: style.cornerRadius,
            .blockImageAlignment: alignment.rawValue
        ]
        if let crop = tokens.crop {
            imageAttrs[.blockImageCrop] = NSValue(rect: crop)
        }
        // The collapsed anchor's advance preserves the image's native alignment.
        let rendered = appendRenderedStandaloneBlock(
            for: token,
            rawContent: rawContent,
            image: image,
            imageBounds: imageBounds,
            paragraphSpacingBefore: style.paragraphSpacing,
            paragraphSpacing: style.paragraphSpacing,
            alignment: alignment,
            mode: .collapsedSource(markerTexts: markerTexts),
            imageAttrs: imageAttrs,
            ctx: ctx,
            attrs: &attrs
        )
        if rendered { appendCollapsedSeparator(after: token, ctx: ctx, attrs: &attrs) }
        return rendered
    }

    // MARK: Blank separator after an image (owner decision Q24A)

    /// Point size of a collapsed separator's characters.
    static let collapsedSeparatorFontSize: CGFloat = 0.1

    /// A line drawn with no height and no spacing.
    static let collapsedSeparatorStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 0
        // 0 means "no limit": the smallest positive height instead.
        style.maximumLineHeight = 0.01
        style.lineSpacing = 0
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        return style
    }()

    /// The blank line written after an image (doc 26 §9, §10) keeps the next
    /// paragraph out of the image's paragraph in other Markdown apps, so it
    /// stays in the source; it is drawn with no height, and the image's bottom
    /// gap stands in for it. Only a whitespace-only line directly after the
    /// image's line collapses, never the caret's line. When the image's line
    /// ends the note, the empty line TextKit adds after it collapses instead.
    private static func appendCollapsedSeparator(after token: MarkdownToken, ctx: StylingContext, attrs: inout [StyledRange]) {
        let text = ctx.nsText
        let imageLine = text.paragraphRange(for: token.range)
        let end = NSMaxRange(imageLine)
        guard end > imageLine.location, [0x0A, 0x0D].contains(text.character(at: end - 1)) else { return }
        guard end < text.length else {
            attrs.append((NSRange(location: end - 1, length: 1), [.collapsesTrailingLine: true]))
            return
        }
        let separator = text.paragraphRange(for: NSRange(location: end, length: 0))
        guard isBlankLine(separator, in: text) else { return }
        let caret = ctx.caretLocation
        let holdsCaret = NSLocationInRange(caret, separator) || (caret == NSMaxRange(separator) && caret == text.length
            && ![0x0A, 0x0D].contains(text.character(at: NSMaxRange(separator) - 1)))
        guard !holdsCaret else { return }
        attrs.append((separator, [
            .collapsedImageSeparator: true,
            .paragraphStyle: collapsedSeparatorStyle,
            .font: NSFont.systemFont(ofSize: collapsedSeparatorFontSize)
        ]))
        if NSMaxRange(separator) == text.length {
            attrs.append((NSRange(location: NSMaxRange(separator) - 1, length: 1), [.collapsesTrailingLine: true]))
        }
    }

    /// The blank line holding `location` when the line above it starts with
    /// `!`: a line the image pass may collapse as a separator. Text only, for
    /// the selection handler, which restyles when the caret enters or leaves one.
    static func imageSeparatorCandidate(at location: Int, in text: NSString) -> NSRange? {
        guard location >= 0, location <= text.length else { return nil }
        let line = text.paragraphRange(for: NSRange(location: location, length: 0))
        guard line.location > 0, isBlankLine(line, in: text) else { return nil }
        let above = text.paragraphRange(for: NSRange(location: line.location - 1, length: 0))
        return startsWithBang(above, in: text) ? line : nil
    }

    /// Whether `line` starts, after spaces and tabs, with `!`: the cheap test
    /// for an image's line before any parse.
    static func startsWithBang(_ line: NSRange, in text: NSString) -> Bool {
        var index = line.location
        while index < NSMaxRange(line), [0x20, 0x09].contains(text.character(at: index)) { index += 1 }
        return index < NSMaxRange(line) && text.character(at: index) == 0x21
    }

    /// Whether `line` holds only spaces, tabs and its line break.
    static func isBlankLine(_ line: NSRange, in text: NSString) -> Bool {
        guard line.length > 0 else { return false }
        for index in line.location..<NSMaxRange(line) where ![0x20, 0x09, 0x0A, 0x0D].contains(text.character(at: index)) {
            return false
        }
        return true
    }
}
