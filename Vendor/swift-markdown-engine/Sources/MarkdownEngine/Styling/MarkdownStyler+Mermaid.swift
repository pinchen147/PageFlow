//
//  MarkdownStyler+Mermaid.swift
//  MarkdownEngine
//
//  Rendered block diagrams (```` ```mermaid ````, …). The diagram peer of the
//  block-LaTeX pass: an INACTIVE fenced block whose info-string names a diagram
//  language is handed to ``BlockDiagramRenderer`` and, when it renders, collapses
//  to a centered standalone image (raw source hidden via the shared collapse
//  primitive, its height reserved). A `nil` render — unsupported language,
//  broken source, or the no-op renderer — or an ACTIVE block (caret inside)
//  emits nothing, leaving the ordinary code block ``MarkdownASTStyler`` already
//  styled: the "never lie, show the source" contract.
//

import AppKit
import Foundation

extension MarkdownStyler {

    // MARK: Block diagrams ```mermaid ... ```

    static func styleMermaidBlock(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        // No diagram blocks in the restyled paragraphs → nothing to do (the
        // common keystroke on a large document).
        guard !ctx.scopedMermaid.isEmpty else { return attrs }
        // Fit-to-width: the renderer downscales the diagram to the EFFECTIVE
        // width — the same zoom-aware width the table pass measures against
        // (ADR-0019). The fit is capped at that width, so the diagram never
        // needs horizontal scrolling and ALWAYS renders inline: under zoom-out
        // a wider-than-column fit spills into the grown container on the text
        // layer itself (blockImageDrawRect centers + clamps it) — no overlay,
        // so scrolling composites it with the prose in one pass.
        let containerWidth = effectiveContainerWidth(for: ctx)
        // Raster density for the current display: backing × magnification, so a
        // zoomed-in settle re-rasterizes crisply (falls back to Retina 2×).
        let rasterScale = (ctx.layoutBridge?.firstTextContainer?.textView as? NativeTextView)?
            .blockRasterScale ?? 2

        for (idx, token, language) in ctx.scopedMermaid {
            // Caret inside → leave the ordinary code block MarkdownASTStyler
            // already styled (source revealed).
            guard !ctx.activeTokenIndices.contains(idx) else { continue }
            guard let paraRange = token.standaloneParagraphRange(in: ctx.nsText) else { continue }

            let rawContent = ctx.nsText.substring(with: token.contentRange)
            let source = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
            // Empty source or a renderer that cannot draw it → keep the code
            // block (fallback), emitting nothing here.
            guard !source.isEmpty,
                  let result = ctx.services.diagram.render(
                      source: source,
                      language: language,
                      maxWidth: containerWidth,
                      fontSize: ctx.baseFont.pointSize,
                      theme: ctx.configuration.theme,
                      pixelScale: rasterScale
                  ) else { continue }

            let didRender = appendRenderedStandaloneBlock(
                for: token,
                rawContent: rawContent,
                image: result.image,
                imageBounds: CGRect(x: 0, y: 0, width: result.size.width, height: result.size.height),
                paragraphSpacingBefore: ctx.baseDefaultLineHeight * 0.5,
                paragraphSpacing: ctx.baseDefaultLineHeight * 0.5,
                alignment: .center,
                // Empty markerTexts → the collapse hides the REAL fence text
                // (```lang / ```), whatever the language/casing, mirroring the
                // table pass (its markers vary too). No hard-coded fence string.
                mode: .collapsedSource(markerTexts: []),
                ctx: ctx,
                attrs: &attrs
            )

            // CRITICAL: MarkdownASTStyler.styleCodeBlock already painted the
            // code-block background over this range. The collapse hides the
            // source but does NOT touch `.backgroundColor`, so that fill would
            // survive behind the diagram (the code-fragment draw keys off it).
            // This pass runs AFTER the AST styler, so clearing the background
            // over the collapsed range wins — only the diagram shows.
            if didRender {
                attrs.append((paraRange, [.backgroundColor: NSColor.clear]))
            }
        }
        return attrs
    }
}
