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
    /// at which point we fall back to dimming the markdown source).
    static func styleImageLinks(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for (idx, token) in ctx.scopedImageLinks {
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
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                continue
            }
            let urlRange = NSRange(location: urlStart, length: urlLength)
            let url = ctx.nsText.substring(with: urlRange)
            let isActive = ctx.activeTokenIndices.contains(idx)

            // The provider gets the destination itself: no title, no `<…>`, escapes decoded.
            let destination = InlineParser.linkDestination(in: ctx.nsText, openParen: openParen.location) ?? url
            let request = EmbeddedImageRequest(name: destination)
            guard let image = ctx.services.images.image(for: request) else {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
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
                isActive: isActive,
                markerTexts: ["![", "]", "(", ")"],
                ctx: ctx,
                attrs: &attrs
            )
            if rendered, !isActive {
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
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
            }
        }
        return attrs
    }

    // MARK: Image Embeds ![[Name]]

    static func styleImageEmbeds(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for (idx, token) in ctx.scopedImageEmbeds {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }

            let isActive = ctx.activeTokenIndices.contains(idx)
            let rawContent = ctx.nsText.substring(with: token.contentRange)
            guard let reference = ImageEmbedReference(content: rawContent) else {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                continue
            }

            if let image = EmbeddedImageCache.shared.image(for: reference, services: ctx.services) {
                let tokens = ImageAltTokens(width: reference.requestedWidth, alignment: reference.alignment, crop: reference.crop)
                let rendered = appendRenderedImage(
                    for: token,
                    rawContent: rawContent,
                    image: image,
                    tokens: tokens,
                    isActive: isActive,
                    markerTexts: ["![[", "]]"],
                    ctx: ctx,
                    attrs: &attrs
                )
                if !rendered {
                    appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                }
            } else {
                // Image not found — show syntax with marker coloring (like broken link)
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
            }
        }
        return attrs
    }

    /// One standalone image, collapsed to its picture or, while the caret is
    /// in it, drawn under its source: sized, aligned and cropped as `tokens`
    /// say, corners rounded. False when the image is not alone on its line.
    private static func appendRenderedImage(
        for token: MarkdownToken,
        rawContent: String,
        image: NSImage,
        tokens: ImageAltTokens,
        isActive: Bool,
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
        // Collapsed, the anchor's advance is the image width, so the
        // paragraph's alignment places it; revealed, the source line stays
        // left and the fragment places the image below it.
        return appendRenderedStandaloneBlock(
            for: token,
            rawContent: rawContent,
            image: image,
            imageBounds: imageBounds,
            paragraphSpacingBefore: style.paragraphSpacing,
            paragraphSpacing: style.paragraphSpacing,
            alignment: isActive ? .left : alignment,
            mode: isActive ? .visibleSource(imageGap: style.imageGap) : .collapsedSource(markerTexts: markerTexts),
            imageAttrs: imageAttrs,
            ctx: ctx,
            attrs: &attrs
        )
    }
}
