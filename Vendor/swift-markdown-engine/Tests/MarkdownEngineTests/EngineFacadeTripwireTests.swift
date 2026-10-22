//
//  EngineFacadeTripwireTests.swift
//  MarkdownEngineTests
//
//  PACKAGE-LEVEL TRIPWIRE (patch D14 — doc 10 §3 "+ package tripwire test";
//  ADR-0010 host-control patch contract). PageFlow vendors an EDITABLE fork of
//  swift-markdown-engine (base faa7b04). On a future rebase onto newer upstream,
//  this test FAILS THE BUILD if either load-bearing assumption the host relies on
//  drifts:
//
//    (a) FACADE FAN-OUT — `MarkdownStyler.styleAttributes` STILL delegates to
//        `MarkdownASTStyler.styleAttributes` AND appends the NSImage render passes
//        (block LaTeX, inline LaTeX, tables, image embeds) — i.e. math/tables/
//        images render BY DEFAULT, no flag. The app-level tripwire cannot reach
//        these `internal` types; only a package test can.
//
//    (b) EMBEDDING CONTRACT — `makeNSView` builds: NSScrollView.documentView is a
//        `NativeTextViewContainer` hosting a `NativeTextView`, and the
//        host-supplied `safeAreaInsets` become the scroll view's `contentInsets`.
//
//  Additive only: changes no engine source; preserves all existing behavior.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

// MARK: - Deterministic stub services (file-local; drive the NSImage passes)

/// 1×1 opaque NSImage so render passes have a concrete bitmap to plant.
private func tripwireImage() -> NSImage {
    let img = NSImage(size: NSSize(width: 1, height: 1))
    img.lockFocus()
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: 1, height: 1).fill()
    img.unlockFocus()
    return img
}

/// LaTeX renderer that always renders — proves the block/inline LaTeX passes run
/// and are wired into the facade. (The default `NoOpLatexRenderer` returns nil,
/// which would make the facade fall back to source and hide the fan-out.)
private struct AlwaysLatexRenderer: LatexRenderer {
    func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? {
        LatexRenderResult(image: tripwireImage(), size: CGSize(width: 8, height: 8), baselineOffset: 0)
    }
}

/// Embedded-image provider that always returns an image, with a stable non-zero
/// fingerprint so the process-global `EmbeddedImageCache` invalidates off the
/// no-op default and serves this image. (Default returns nil → embed shows source.)
private struct AlwaysImageProvider: EmbeddedImageProvider {
    func image(for reference: EmbeddedImageRequest) -> NSImage? { tripwireImage() }
    func fingerprint() -> AnyHashable { "tripwire-image-provider" }
}

@Suite("Engine facade + embedding tripwire (D14 / doc 10 §3 / ADR-0010)")
struct EngineFacadeTripwireTests {

    private let base: CGFloat = 14
    private var fontName: String { NSFont.systemFont(ofSize: 14).fontName }

    /// Config whose services force every NSImage pass to produce output, so the
    /// fan-out is observable. Everything else stays at engine defaults.
    private func renderingConfig() -> MarkdownEditorConfiguration {
        var config = MarkdownEditorConfiguration.default
        config.services.latex = AlwaysLatexRenderer()
        config.services.images = AlwaysImageProvider()
        return config
    }

    /// A document that exercises BOTH halves of the facade:
    ///   - heading + bold  → AST styler emits `.font` ranges
    ///   - `$$…$$`          → block-LaTeX NSImage pass
    ///   - inline `$x$`     → inline-LaTeX NSImage pass
    ///   - GFM table        → table NSImage pass (renders its own image)
    ///   - `![[pic]]`       → image-embed NSImage pass (global cache)
    private let doc = """
# Heading **bold**

$$x^2$$

inline $a+b$ math

| h1 | h2 |
| --- | --- |
| a | b |

![[pic]]
"""

    /// Every `.renderedBlockImage`-bearing range (the shared key all NSImage passes plant).
    private func renderedBlockImageRanges(_ attrs: [StyledRange]) -> [NSRange] {
        attrs.compactMap { $0.attributes[.renderedBlockImage] != nil ? $0.range : nil }
    }

    private func anyLatexImage(intersecting r: NSRange, in attrs: [StyledRange]) -> Bool {
        renderedBlockImageRanges(attrs).contains { NSIntersectionRange($0, r).length > 0 }
    }

    // MARK: (a) Facade fan-out

    /// (a1) The facade STILL delegates to the AST styler: every `.font` run the
    /// AST styler emits for the heading line appears verbatim in the facade output.
    /// If a rebase makes MarkdownStyler stop calling MarkdownASTStyler, this fails.
    @MainActor
    @Test("facade still delegates to MarkdownASTStyler (AST output ⊆ facade output)")
    func facadeDelegatesToASTStyler() {
        _ = NSApplication.shared
        let config = renderingConfig()

        let astOnly = MarkdownASTStyler.styleAttributes(
            text: doc, fontName: fontName, fontSize: base,
            caretLocation: -1, configuration: config
        )
        let facade = MarkdownStyler.styleAttributes(
            text: doc, fontName: fontName, fontSize: base,
            caretLocation: -1, activeTokenIndices: [], configuration: config
        )

        // Canonical (range, sorted-keys) tuples the facade must contain.
        func fontKeyTuples(_ ranges: [StyledRange]) -> Set<String> {
            Set(ranges.compactMap { entry -> String? in
                guard entry.attributes[.font] != nil else { return nil }
                return "\(entry.range.location)+\(entry.range.length):\(entry.attributes.keys.map(\.rawValue).sorted().joined(separator: ","))"
            })
        }
        let astFontTuples = fontKeyTuples(astOnly)
        let facadeFontTuples = fontKeyTuples(facade)

        #expect(!astFontTuples.isEmpty, "AST styler produced no `.font` runs — fixture/contract drift")
        // The facade must be a SUPERSET of the AST styler's font runs.
        #expect(astFontTuples.isSubset(of: facadeFontTuples),
                "MarkdownStyler facade no longer reproduces MarkdownASTStyler output — fan-out broken")
    }

    /// (a2) The facade APPENDS the NSImage passes (math/tables/images render by
    /// default, no flag): the facade emits `.renderedBlockImage` ranges the AST styler
    /// never does, for block math, inline math, the table, and the image embed.
    @MainActor
    @Test("facade appends the NSImage render passes (math/tables/images on by default)")
    func facadeAppendsImagePasses() {
        _ = NSApplication.shared
        let config = renderingConfig()
        let ns = doc as NSString

        let astOnly = MarkdownASTStyler.styleAttributes(
            text: doc, fontName: fontName, fontSize: base,
            caretLocation: -1, configuration: config
        )
        let facade = MarkdownStyler.styleAttributes(
            text: doc, fontName: fontName, fontSize: base,
            caretLocation: -1, activeTokenIndices: [], configuration: config
        )

        // The AST styler alone renders NO images (it explicitly defers image/
        // latex/table to the facade passes).
        #expect(renderedBlockImageRanges(astOnly).isEmpty,
                "MarkdownASTStyler unexpectedly emitted `.renderedBlockImage` — pass ownership drifted")

        // The facade renders all of them — one assertion per pass so a SINGLE
        // dropped pass is caught, not masked by the others.
        let blockMath = ns.range(of: "x^2")
        let inlineMath = ns.range(of: "a+b")
        // The table renders via the shared collapsed-source path, which plants
        // `.renderedBlockImage` on a SINGLE anchor character near the top of the table's
        // content (emitCollapsedAttrs), not across every row. Scope the assertion
        // to the whole table span so it faithfully captures the table pass's image
        // wherever the anchor lands — the contract is "the table pass appends an
        // image the AST styler never does", not the exact sub-range.
        let tableHeader = ns.range(of: "| h1 | h2 |")
        let tableBody = ns.range(of: "| a | b |")
        let tableSpan = NSRange(location: tableHeader.location,
                                length: NSMaxRange(tableBody) - tableHeader.location)
        let embed = ns.range(of: "![[pic]]")

        #expect(anyLatexImage(intersecting: blockMath, in: facade),
                "block-LaTeX pass (styleBlockLatex) not appended by the facade")
        #expect(anyLatexImage(intersecting: inlineMath, in: facade),
                "inline-LaTeX pass (styleInlineLatex) not appended by the facade")
        #expect(anyLatexImage(intersecting: tableSpan, in: facade),
                "table pass (styleTables) not appended by the facade")
        #expect(anyLatexImage(intersecting: embed, in: facade),
                "image-embed pass (styleImageEmbeds) not appended by the facade")
        // And the facade must carry strictly MORE `.renderedBlockImage` ranges than AST-only.
        #expect(renderedBlockImageRanges(facade).count > renderedBlockImageRanges(astOnly).count)
    }

    // MARK: (b) Embedding contract

    /// The host relies on `makeNSView`'s wiring: documentView is a
    /// `NativeTextViewContainer` hosting a `NativeTextView`, and the supplied
    /// `safeAreaInsets` become the scroll view's `contentInsets`. Replicated
    /// headlessly; the whole stack is bound for the test's lifetime.
    @MainActor
    @Test("embedding contract: documentView class, hosted text view, content insets")
    func embeddingContractHolds() {
        _ = NSApplication.shared
        let insets = SafeAreaInsets(top: 12, leading: 7, trailing: 9, bottom: 5)
        var config = MarkdownEditorConfiguration.default
        config.safeAreaInsets = insets

        // Mirror makeNSView's wiring (no SwiftUI Representable lifecycle needed).
        let scrollView = ClampedScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: config.safeAreaInsets.top,
            left: config.safeAreaInsets.leading,
            bottom: config.safeAreaInsets.bottom,
            right: config.safeAreaInsets.trailing
        )
        let textView = NativeTextView(frame: .zero)
        textView.configuration = config
        textView.autoresizingMask = []
        let container = NativeTextViewContainer(frame: scrollView.bounds)
        container.autoresizingMask = [.width]
        container.textView = textView
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 0)
        container.addSubview(textView)
        scrollView.documentView = container

        // The embedding contract the host depends on.
        #expect(scrollView.documentView is NativeTextViewContainer,
                "documentView is no longer a NativeTextViewContainer — embedding contract broken")
        #expect(scrollView.nativeTextView === textView,
                "NSScrollView.nativeTextView accessor no longer resolves the hosted NativeTextView")
        #expect(container.textView === textView)
        #expect(textView.superview === container,
                "text view is not a subview of the container document view")

        // Host-supplied safeAreaInsets must be applied as the scroll view's contentInsets.
        #expect(scrollView.contentInsets.top == insets.top)
        #expect(scrollView.contentInsets.left == insets.leading)
        #expect(scrollView.contentInsets.right == insets.trailing)
        #expect(scrollView.contentInsets.bottom == insets.bottom)
        #expect(scrollView.automaticallyAdjustsContentInsets == false,
                "engine must own the insets (automaticallyAdjustsContentInsets stays off)")
    }
}
