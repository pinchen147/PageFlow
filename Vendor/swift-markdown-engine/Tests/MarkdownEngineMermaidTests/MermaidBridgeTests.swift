//
//  MermaidBridgeTests.swift
//  MarkdownEngineMermaidTests
//
//  Proves the BeautifulMermaid-backed BlockDiagramRenderer actually rasterizes a
//  diagram (not just compiles), fits it to the reading column, caches it, and —
//  critically — returns nil for anything it can't draw so the editor falls back
//  to raw source (the "never lie" contract).
//

import AppKit
import Testing
@testable import MarkdownEngine
@testable import MarkdownEngineMermaid

@MainActor
@Suite("MermaidBridge rendering")
struct MermaidBridgeTests {

    private let theme = MarkdownEditorTheme.default

    private func bridge() -> MermaidBridge { MermaidBridge() }

    private let flowchart = """
    graph TD
        A[Start] --> B{Decision}
        B -->|yes| C[Do a thing]
        B -->|no| D[Do another thing]
        C --> E[End]
        D --> E
    """

    @Test("a real flowchart renders to a non-nil image with sane bounds")
    func rendersFlowchart() {
        _ = NSApplication.shared
        let result = bridge().render(source: flowchart, language: "mermaid",
                                     maxWidth: 600, fontSize: 16, theme: theme)
        guard let r = result else { Issue.record("expected a render"); return }
        #expect(r.size.width > 0 && r.size.height > 0)
        // Fitted to the reading column (allow a 1pt rounding slack).
        #expect(r.size.width <= 601)
        // The rasterized image carries real pixels at 2× backing.
        #expect(r.image.size.width > 0 && r.image.size.height > 0)
    }

    @Test("a diagram wider than the column is downscaled to fit; a small one is not upscaled")
    func fitsToWidth() {
        // Force a narrow column: the same flowchart must come back no wider than it.
        let narrow = bridge().render(source: flowchart, language: "mermaid",
                                     maxWidth: 220, fontSize: 16, theme: theme)
        guard let narrow else { Issue.record("expected a render"); return }
        #expect(narrow.size.width <= 221)

        // A tiny two-node graph in a wide column keeps its natural width (no upscale).
        let tiny = "graph LR\n  X --> Y"
        let wide = bridge().render(source: tiny, language: "mermaid",
                                   maxWidth: 4000, fontSize: 16, theme: theme)
        guard let wide else { Issue.record("expected a render"); return }
        #expect(wide.size.width < 4000, "a small diagram must not be stretched to the column width")
    }

    @Test("unsupported / broken / empty source returns nil so the editor shows the source")
    func fallsBackOnFailure() {
        let b = bridge()
        // Not a diagram at all.
        #expect(b.render(source: "this is not mermaid at all",
                         language: "mermaid", maxWidth: 600, fontSize: 16, theme: theme) == nil)
        // Empty.
        #expect(b.render(source: "   \n  ",
                         language: "mermaid", maxWidth: 600, fontSize: 16, theme: theme) == nil)
        // Degenerate width.
        #expect(b.render(source: flowchart,
                         language: "mermaid", maxWidth: 0, fontSize: 16, theme: theme) == nil)
    }

    @Test("an oversized diagram shows its source instead of laying out")
    func oversizedSourceFallsBack() {
        let edges = (0..<2_000).map { "  N\($0) --> N\($0 + 1)" }.joined(separator: "\n")
        let source = "graph TD\n" + edges
        #expect(source.utf16.count > MermaidBridge.maxSourceLength)
        #expect(bridge().render(source: source, language: "mermaid", maxWidth: 600, fontSize: 16, theme: theme) == nil)
    }

    @Test("a broken diagram stays a fallback on repeat renders (served from the failure cache)")
    func failedRenderStaysFallback() {
        let b = bridge()
        for _ in 0..<3 {
            #expect(b.render(source: "this is not mermaid at all", language: "mermaid",
                             maxWidth: 600, fontSize: 16, theme: theme) == nil)
        }
    }

    @Test("a repeated render is served from cache (same image instance)")
    func caches() {
        let b = bridge()
        guard let first = b.render(source: flowchart, language: "mermaid",
                                   maxWidth: 600, fontSize: 16, theme: theme),
              let second = b.render(source: flowchart, language: "mermaid",
                                    maxWidth: 600, fontSize: 16, theme: theme) else {
            Issue.record("expected two renders")
            return
        }
        // Identity: the cache returns the very same NATURAL NSImage, not a fresh
        // raster — the cache is keyed by source/font/appearance, not width.
        #expect(first.image === second.image)

        b.clearCache()
        let afterClear = b.render(source: flowchart, language: "mermaid",
                                  maxWidth: 600, fontSize: 16, theme: theme)
        #expect(afterClear?.image !== first.image, "clearCache must force a fresh raster")
    }

    @Test("the same cached raster refits per call — an adjacent width is not stale")
    func refitsPerCallNotStale() {
        let b = bridge()
        // Wide column first (populates the cache), then a much narrower one.
        guard let wide = b.render(source: flowchart, language: "mermaid",
                                  maxWidth: 2000, fontSize: 16, theme: theme),
              let narrow = b.render(source: flowchart, language: "mermaid",
                                    maxWidth: 300, fontSize: 16, theme: theme) else {
            Issue.record("expected two renders")
            return
        }
        // Same underlying raster…
        #expect(wide.image === narrow.image)
        // …but the narrow call is fitted to ITS column, not the wide one it was
        // cached at (the width-bucket cache regression this guards).
        #expect(narrow.size.width <= 301)
        #expect(wide.size.width >= narrow.size.width)
    }
}

/// End-to-end through the REAL styling pass with the REAL BeautifulMermaid
/// bridge (the bridge unit tests above exercise the adapter in isolation; the
/// engine's own suite covers the collapse pass with a mock). This proves the
/// whole pipeline: a fenced ```` ```mermaid ```` block whose caret is away
/// collapses to a `.renderedBlockImage` and clears the code-block background,
/// while an active block (caret inside) stays raw source.
@MainActor
@Suite("Mermaid end-to-end styling")
struct MermaidEndToEndStylingTests {

    private func configuration() -> MarkdownEditorConfiguration {
        var c = MarkdownEditorConfiguration.default
        c.services.diagram = MermaidBridge()
        return c
    }

    private let doc = """
    # Title

    ```mermaid
    graph TD
        A[Start] --> B[End]
    ```

    Trailing prose.
    """

    @Test("an inactive mermaid block collapses to a rendered image and clears the code background")
    func collapsesToImage() {
        _ = NSApplication.shared
        let attrs = MarkdownStyler.styleAttributes(
            text: doc, fontName: "Helvetica", fontSize: 16,
            caretLocation: -1, activeTokenIndices: [], configuration: configuration()
        )
        // The real renderer produced a block image…
        #expect(attrs.contains { $0.attributes[.renderedBlockImage] is NSImage },
                "a rendered mermaid block must carry a .renderedBlockImage")
        // …and the code-block fill under it was cleared to transparent.
        #expect(attrs.contains { ($0.attributes[.backgroundColor] as? NSColor) == .clear },
                "the collapsed diagram must clear the code-block background")
    }

    @Test("a caret INSIDE the mermaid block reveals source — no image")
    func activeBlockShowsSource() {
        _ = NSApplication.shared
        let ns = doc as NSString
        let caret = ns.range(of: "graph TD").location
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: doc)
        let active = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: NSRange(location: caret, length: 0), tokens: tokens, in: ns
        )
        let attrs = MarkdownStyler.styleAttributes(
            text: doc, fontName: "Helvetica", fontSize: 16,
            caretLocation: caret, activeTokenIndices: active,
            precomputedTokens: tokens, configuration: configuration()
        )
        #expect(!attrs.contains { $0.attributes[.renderedBlockImage] is NSImage },
                "with the caret inside, the block must stay raw source (no image)")
    }

    @Test("pixelScale raises raster density for zoom-in without changing the fitted point size (ADR-0019)")
    func pixelScaleRaisesDensityNotPointSize() {
        _ = NSApplication.shared
        let b = MermaidBridge()
        let base = b.render(source: "graph LR\n  X --> Y", language: "mermaid",
                            maxWidth: 4000, fontSize: 16, theme: MarkdownEditorTheme.default)
        // 2× backing × 2× magnification → a 4× raster of the SAME point size.
        let dense = b.render(source: "graph LR\n  X --> Y", language: "mermaid",
                             maxWidth: 4000, fontSize: 16, theme: MarkdownEditorTheme.default,
                             pixelScale: 4)
        guard let base, let dense else { Issue.record("expected renders"); return }
        #expect(abs(base.size.width - dense.size.width) < 1,
                "density must not change the fitted point size (no-upscale cap)")
        // The TRUE backing width: both cgImage(forProposedRect:) and the
        // snapshot rep's pixelsWide report point size × screen scale, hiding
        // any density above 2× — the TIFF encoding carries the real raster.
        func pixelWidth(_ image: NSImage) -> Int {
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else { return 0 }
            return rep.pixelsWide
        }
        #expect(pixelWidth(dense.image) > pixelWidth(base.image),
                "a higher pixelScale must bake more pixels (crisp at zoom-in)")
        // Below the base render scale, the floor wins — same raster as base.
        let low = b.render(source: "graph LR\n  X --> Y", language: "mermaid",
                           maxWidth: 4000, fontSize: 16, theme: MarkdownEditorTheme.default,
                           pixelScale: 1)
        guard let low else { Issue.record("expected a render"); return }
        #expect(pixelWidth(low.image) == pixelWidth(base.image),
                "pixelScale below the 2× floor must reuse the base density")
    }
}
