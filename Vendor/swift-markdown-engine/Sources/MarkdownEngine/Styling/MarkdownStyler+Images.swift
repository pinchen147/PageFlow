//
//  MarkdownStyler+Images.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Image embed (`![[...]]`) styling and layout.
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

            let imageEmbedConfig = ctx.configuration.imageEmbed
            // Zoom-aware (ADR-0019): the same effective width the table/diagram
            // passes fit against. Under zoom-out the text VIEW spans that width,
            // so an image wider than the prose column spills inline exactly like
            // a table (blockImageDrawRect centers + clamps it); the natural-size
            // cap below still applies — images never upscale.
            let maxWidth: CGFloat = {
                let w = effectiveContainerWidth(for: ctx)
                if w > 0 && w < imageEmbedConfig.unreasonableMaxWidth { return w }
                return imageEmbedConfig.fallbackMaxWidth
            }()

            // `![alt|300](url)` sizes the image as Obsidian does: a trailing
            // `|width` on the alt text.
            let altRange = NSRange(location: NSMaxRange(token.markerRanges[0]),
                                   length: max(0, token.markerRanges[1].location - NSMaxRange(token.markerRanges[0])))
            let requestedWidth = Self.requestedWidth(inAlt: ctx.nsText.substring(with: altRange))
            let imageBounds = CGRect(origin: .zero,
                                     size: imageEmbedConfig.displaySize(natural: image.size, requestedWidth: requestedWidth, maxWidth: maxWidth))

            let rawContent = ctx.nsText.substring(with: token.range)
            let rendered: Bool
            if isActive {
                rendered = appendRenderedStandaloneBlock(
                    for: token,
                    rawContent: rawContent,
                    image: image,
                    imageBounds: imageBounds,
                    paragraphSpacingBefore: imageEmbedConfig.paragraphSpacing,
                    paragraphSpacing: imageEmbedConfig.paragraphSpacing,
                    alignment: .left,
                    mode: .visibleSource(imageGap: imageEmbedConfig.imageGap),
                    ctx: ctx,
                    attrs: &attrs
                )
            } else {
                rendered = appendRenderedStandaloneBlock(
                    for: token,
                    rawContent: rawContent,
                    image: image,
                    imageBounds: imageBounds,
                    paragraphSpacingBefore: imageEmbedConfig.paragraphSpacing,
                    paragraphSpacing: imageEmbedConfig.paragraphSpacing,
                    alignment: .left,
                    mode: .collapsedSource(markerTexts: ["![", "]", "(", ")"]),
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
            }
            if !rendered {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
            }
        }
        return attrs
    }

    /// The width an alt text asks for with a trailing `|<points>`, if any.
    static func requestedWidth(inAlt alt: String) -> CGFloat? {
        guard let bar = alt.lastIndex(of: "|") else { return nil }
        let digits = alt[alt.index(after: bar)...].trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let width = Double(digits), width > 0 else { return nil }
        return CGFloat(width)
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
                let imageEmbedConfig = ctx.configuration.imageEmbed
                // Zoom-aware (ADR-0019): the same effective width the
                // table/diagram passes fit against — an image wider than the
                // prose column spills inline under zoom-out (see above);
                // requested-width/natural caps below still apply.
                let maxWidth: CGFloat = {
                    let w = effectiveContainerWidth(for: ctx)
                    if w > 0 && w < imageEmbedConfig.unreasonableMaxWidth { return w }
                    return imageEmbedConfig.fallbackMaxWidth
                }()

                let requestedWidth = reference.requestedWidth.flatMap { $0 > 0 ? $0 : nil }
                let imageBounds = CGRect(origin: .zero,
                                         size: imageEmbedConfig.displaySize(natural: image.size, requestedWidth: requestedWidth, maxWidth: maxWidth))
                let rendered: Bool
                if isActive {
                    rendered = appendRenderedStandaloneBlock(
                        for: token,
                        rawContent: rawContent,
                        image: image,
                        imageBounds: imageBounds,
                        paragraphSpacingBefore: imageEmbedConfig.paragraphSpacing,
                        paragraphSpacing: imageEmbedConfig.paragraphSpacing,
                        alignment: .left,
                        mode: .visibleSource(imageGap: imageEmbedConfig.imageGap),
                        ctx: ctx,
                        attrs: &attrs
                    )
                } else {
                    rendered = appendRenderedStandaloneBlock(
                        for: token,
                        rawContent: rawContent,
                        image: image,
                        imageBounds: imageBounds,
                        paragraphSpacingBefore: imageEmbedConfig.paragraphSpacing,
                        paragraphSpacing: imageEmbedConfig.paragraphSpacing,
                        alignment: .left,
                        mode: .collapsedSource(markerTexts: ["![[", "]]"]),
                        ctx: ctx,
                        attrs: &attrs
                    )
                }
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
}
