//
//  MarkdownZoomRefitTests.swift
//  MarkdownEngineTests
//
//  ADR-0019: visual zoom re-fits width-FITTED blocks to the effective width
//  (viewport ÷ magnification). Zoom out and a wide table's overlay band — and
//  a big diagram — use the whole window; the prose column never rewraps; the
//  container grows to host the breakout; the centering knob places the column.
//  All through the REAL wrapper (rootView reassignment → projectMagnification
//  → magnificationDidSettle → debounced containerWidthDidChange).
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Visual zoom width re-fit", .serialized)
struct MarkdownZoomRefitTests {

    final class Host { var text: String; init(_ t: String) { text = t } }

    /// Counts render calls and honors maxWidth like MermaidBridge: natural
    /// 1200pt wide, fitted down to the caller's width, never upscaled.
    final class StubDiagramRenderer: BlockDiagramRenderer, @unchecked Sendable {
        static let naturalWidth: CGFloat = 1200
        private(set) var renderCount = 0
        private(set) var lastPixelScale: CGFloat = 0
        func render(source: String, language: String, maxWidth: CGFloat,
                    fontSize: CGFloat, theme: MarkdownEditorTheme) -> DiagramRenderResult? {
            render(source: source, language: language, maxWidth: maxWidth,
                   fontSize: fontSize, theme: theme, pixelScale: 2)
        }
        func render(source: String, language: String, maxWidth: CGFloat,
                    fontSize: CGFloat, theme: MarkdownEditorTheme,
                    pixelScale: CGFloat) -> DiagramRenderResult? {
            renderCount += 1
            lastPixelScale = pixelScale
            let w = min(Self.naturalWidth, maxWidth)
            return DiagramRenderResult(
                image: NSImage(size: NSSize(width: w, height: 80)),
                size: CGSize(width: w, height: 80)
            )
        }
    }

    /// A host-supplied renderer with no density buckets: its bitmap backing
    /// honors every requested pixel scale while its point size stays fixed.
    final class RasterDiagramRenderer: BlockDiagramRenderer, @unchecked Sendable {
        private(set) var renderCount = 0
        func render(source: String, language: String, maxWidth: CGFloat,
                    fontSize: CGFloat, theme: MarkdownEditorTheme) -> DiagramRenderResult? {
            render(source: source, language: language, maxWidth: maxWidth,
                   fontSize: fontSize, theme: theme, pixelScale: 1)
        }
        func render(source: String, language: String, maxWidth: CGFloat,
                    fontSize: CGFloat, theme: MarkdownEditorTheme,
                    pixelScale: CGFloat) -> DiagramRenderResult? {
            let size = NSSize(width: 96, height: 32)
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * pixelScale)),
                pixelsHigh: Int(ceil(size.height * pixelScale)), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { return nil }
            bitmap.size = size
            let image = NSImage(size: size)
            image.addRepresentation(bitmap)
            renderCount += 1
            return DiagramRenderResult(image: image, size: size)
        }
    }

    /// Serves one fixed-size NSImage for every request — the image peer of
    /// StubDiagramRenderer (natural 900pt: wider than the 100% column, narrower
    /// than the 50% effective width).
    final class StubImageProvider: EmbeddedImageProvider, @unchecked Sendable {
        static let naturalWidth: CGFloat = 900
        func image(for reference: EmbeddedImageRequest) -> NSImage? {
            NSImage(size: NSSize(width: Self.naturalWidth, height: 200))
        }
        func fingerprint() -> AnyHashable { "stub-image-provider" }
    }

    struct Harness: View {
        let host: Host
        let diagram: any BlockDiagramRenderer
        var images: StubImageProvider? = nil
        // VALUE props so rootView reassignment diffs (the reference-only trap).
        var magnification: CGFloat
        var centersZoomedOut: Bool = false
        var sideMargin: CGFloat = 24
        var body: some View {
            NativeTextViewWrapper(
                text: Binding(get: { host.text }, set: { host.text = $0 }),
                configuration: {
                    // PageFlow's ACTUAL full-width config (readingWidth == nil).
                    var c = MarkdownEditorConfiguration.default
                    c.textInsets = TextInsets(horizontal: sideMargin, vertical: 0)
                    c.centersZoomedOutColumn = centersZoomedOut
                    c.services.diagram = diagram
                    if let images { c.services.images = images }
                    return c
                }(),
                fontSize: 16,
                documentId: "zoom-refit",
                isEditable: true,
                magnificationRange: 0.5...4.0,
                magnification: magnification
            )
        }
    }

    /// Wider than the 100% column (~652pt) but comfortably narrower than the
    /// 50% effective width (~1352pt): overlay at 100%, INLINE spill at 50%.
    /// 4 columns ≈ 900pt — keep it far from both thresholds.
    private static let wideTable = """
    # Zoom re-fit

    | Alpha column content wide | Bravo column content wide | Charlie column content wide | Delta column content wide |
    | --- | --- | --- | --- |
    | one one one one | two two two two | three three three | four four four |

    Trailing prose after the table.
    """

    /// Wider than even the 50% effective width: keeps the horizontal-scroll
    /// overlay at every zoom, breakout-hosted once the container grows.
    private static let monsterTable: String = {
        let headers = (1...14).map { "Monster column content number \($0) is long" }
        let cells = (1...14).map { "cell \($0) cell \($0)" }
        return """
        # Monster

        | \(headers.joined(separator: " | ")) |
        | \((1...14).map { _ in "---" }.joined(separator: " | ")) |
        | \(cells.joined(separator: " | ")) |

        Trailing prose after the table.
        """
    }()

    private static let diagramDoc = """
    # Diagram zoom

    ```mermaid
    flowchart LR
      A --> B
    ```

    Trailing prose after the diagram.
    """

    private static let imageDoc = """
    # Image zoom

    ![wide screenshot](fixture://wide.png)

    Trailing prose after the image.
    """

    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    private func settle(_ rounds: Int = 8) async {
        for _ in 0..<rounds {
            spin()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    /// The zoom re-fit is debounced 200ms behind the last magnification change.
    private func settlePastRefitDebounce() async {
        try? await Task.sleep(nanoseconds: 350_000_000)
        await settle()
    }

    private func findScroll(in v: NSView) -> NSScrollView? {
        if let s = v as? NSScrollView { return s }
        for sub in v.subviews { if let s = findScroll(in: sub) { return s } }
        return nil
    }

    private func mount(
        _ host: Host, diagram: any BlockDiagramRenderer, images: StubImageProvider? = nil,
        magnification: CGFloat = 1.0, centers: Bool = false
    ) async -> (window: NSWindow, hosting: NSHostingView<Harness>, scroll: NSScrollView, textView: NativeTextView) {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: Harness(
            host: host, diagram: diagram, images: images,
            magnification: magnification, centersZoomedOut: centers
        ))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        let scroll = findScroll(in: hosting)!
        let textView = scroll.nativeTextView!
        return (window, hosting, scroll, textView)
    }

    // MARK: - Tables

    @Test("a table that fits the zoomed-out window flips overlay → inline spill (and back) — without rewrapping prose")
    func wideTableFlipsToInlineSpillOnZoomOut() async throws {
        let host = Host(Self.wideTable)
        let diagram = StubDiagramRenderer()
        let (window, hosting, scroll, textView) = await mount(host, diagram: diagram)
        defer { window.orderOut(nil) }

        let container = try #require(scroll.documentView as? NativeTextViewContainer)
        let textContainer = try #require(textView.textContainer)
        let wrapWidthAt1 = textContainer.size.width
        #expect(abs(textView.frame.width - 700) < 2, "text view spans the 700pt viewport at 100%")
        let overlayAt1 = try #require(textView.wideTableOverlays.values.first, "the table must be wide at 700pt")
        #expect(overlayAt1.superview === textView, "full-width mode hosts the overlay in the text view at 100%")
        #expect(overlayAt1.frame.width < 700, "band is bounded by the column at 100%")

        // ⌘− ⌘− → 50% through the real wrapper projection.
        hosting.rootView = Harness(host: host, diagram: diagram, magnification: 0.5)
        hosting.layoutSubtreeIfNeeded()
        await settlePastRefitDebounce()

        #expect(abs(scroll.magnification - 0.5) < 0.01)
        let effective = scroll.contentView.bounds.width
        #expect(abs(effective - 1400) < 4, "clip bounds = frame ÷ magnification")
        // The VIEW spans the effective width (the spill must stay inside it —
        // AppKit clips drawing at view bounds), while the WRAP width is pinned:
        // zoom must never rewrap a single line.
        #expect(abs(textView.frame.width - effective) < 4, "text view grows to the effective width")
        #expect(abs(container.frame.width - effective) < 4, "container grows with it")
        #expect(!textContainer.widthTracksTextView, "wrap width is PINNED while the view is zoom-widened")
        #expect(abs(textContainer.size.width - wrapWidthAt1) < 1, "prose wrap width unchanged — no reflow")

        // The table fits the effective width now → INLINE spill on the text
        // layer (buttery scroll), the overlay is swept.
        #expect(textView.wideTableOverlays.isEmpty,
                "a table that fits the zoomed-out window renders inline, not as an overlay")
        var tableImageWidth: CGFloat = 0
        textView.textStorage?.enumerateAttribute(
            .latexBounds, in: NSRange(location: 0, length: textView.textStorage?.length ?? 0), options: []
        ) { value, _, stop in
            guard let v = value as? NSValue else { return }
            tableImageWidth = v.rectValue.width
            stop.pointee = true
        }
        #expect(tableImageWidth > 700, "the inline image is the full natural-width table, spilling past the column")
        #expect(tableImageWidth <= textView.frame.width + 1, "the spill stays inside the view — nothing to clip")

        // Back to 100%: the flip reverses — pin released, overlay returns.
        hosting.rootView = Harness(host: host, diagram: diagram, magnification: 1.0)
        hosting.layoutSubtreeIfNeeded()
        await settlePastRefitDebounce()

        #expect(abs(container.frame.width - 700) < 4, "container shrinks back at 100%")
        #expect(abs(textView.frame.width - 700) < 4, "text view shrinks back at 100%")
        #expect(textContainer.widthTracksTextView, "the wrap pin is released at 100%")
        #expect(abs(textContainer.size.width - wrapWidthAt1) < 1)
        let overlayBack = try #require(textView.wideTableOverlays.values.first, "overlay returns at 100%")
        #expect(overlayBack.superview === textView)
        #expect(overlayBack.frame.width < 700)
    }

    @Test("a table wider than even the zoomed-out window keeps the overlay with the full effective band")
    func monsterTableKeepsOverlay() async throws {
        let host = Host(Self.monsterTable)
        let diagram = StubDiagramRenderer()
        let (window, hosting, scroll, textView) = await mount(host, diagram: diagram)
        defer { window.orderOut(nil) }

        _ = try #require(textView.wideTableOverlays.values.first, "monster table is wide at 100%")

        hosting.rootView = Harness(host: host, diagram: diagram, magnification: 0.5)
        hosting.layoutSubtreeIfNeeded()
        await settlePastRefitDebounce()

        let overlay = try #require(textView.wideTableOverlays.values.first, "still wider than the effective width → overlay survives")
        #expect(overlay.superview === textView, "the zoom-widened text view hosts its own overlays — no breakout layer")
        #expect(overlay.frame.width > 1300, "band spans the zoomed-out window, not the stale column")
    }

    // MARK: - Diagrams

    @Test("zoom-out re-fits a width-clamped diagram to the effective width — INLINE, never an overlay")
    func diagramRefitsOnZoomOut() async throws {
        let host = Host(Self.diagramDoc)
        let diagram = StubDiagramRenderer()
        let (window, hosting, scroll, textView) = await mount(host, diagram: diagram)
        defer { window.orderOut(nil) }

        func renderedDiagramWidth() -> CGFloat? {
            guard let storage = textView.textStorage else { return nil }
            var width: CGFloat?
            storage.enumerateAttribute(.latexBounds, in: NSRange(location: 0, length: storage.length), options: []) { value, _, stop in
                guard let v = value as? NSValue else { return }
                width = v.rectValue.width
                stop.pointee = true
            }
            return width
        }

        // 100%: clamped to the column (700 − 2×24 insets).
        let clamped = try #require(renderedDiagramWidth())
        #expect(abs(clamped - 652) < 4, "diagram fits the column at 100%")
        #expect(textView.wideTableOverlays.isEmpty, "an in-column diagram renders inline")

        hosting.rootView = Harness(host: host, diagram: diagram, magnification: 0.5)
        hosting.layoutSubtreeIfNeeded()
        await settlePastRefitDebounce()

        let refitted = try #require(renderedDiagramWidth())
        #expect(abs(refitted - StubDiagramRenderer.naturalWidth) < 1,
                "at 50% the effective width frees the diagram to its natural 1200pt")
        // The fit is capped at the effective width, so a diagram NEVER needs
        // the scrollable overlay — it spills inline on the text layer, which
        // is what keeps scrolling under it buttery (no separate compositing
        // layer, no viewport-band pop-in).
        #expect(textView.wideTableOverlays.isEmpty,
                "a zoom-freed diagram renders inline, never as an overlay")

        // Back to 100%: clamped again.
        hosting.rootView = Harness(host: host, diagram: diagram, magnification: 1.0)
        hosting.layoutSubtreeIfNeeded()
        await settlePastRefitDebounce()

        let back = try #require(renderedDiagramWidth())
        #expect(abs(back - 652) < 4)
        #expect(textView.wideTableOverlays.isEmpty)
    }

    @Test("zoom refreshes a custom renderer's bitmap density without changing point layout",
          arguments: [1.05, 2.05])
    func customDiagramDensityFollowsZoom(initialZoom: Double) async throws {
        let host = Host(Self.diagramDoc)
        let diagram = RasterDiagramRenderer()
        let (window, hosting, scroll, textView) = await mount(
            host, diagram: diagram, magnification: initialZoom
        )
        defer { window.orderOut(nil) }
        // Keep scrollbar appearance from changing the fit width during this
        // density-only probe, regardless of the machine's scrollbar preference.
        scroll.scrollerStyle = .overlay
        hosting.layoutSubtreeIfNeeded()
        textView.magnificationDidSettle()
        await settlePastRefitDebounce()
        let storage = try #require(textView.textStorage)
        func renderedImage() throws -> NSImage {
            var image: NSImage?
            storage.enumerateAttribute(.renderedBlockImage, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
                guard let rendered = value as? NSImage else { return }
                image = rendered
                stop.pointee = true
            }
            return try #require(image)
        }
        let before = try renderedImage()
        let beforeBitmap = try #require(before.representations.first as? NSBitmapImageRep)
        let width = try #require(textView.textContainer).size.width
        try #require(beforeBitmap.pixelsWide > 0)
        let nextZoom = initialZoom + 0.05

        hosting.rootView = Harness(host: host, diagram: diagram, magnification: nextZoom)
        hosting.layoutSubtreeIfNeeded()
        await settlePastRefitDebounce()

        try #require(abs(scroll.magnification - nextZoom) < 0.001)
        try #require(abs(try #require(textView.textContainer).size.width - width) <= 0.5,
                     "The density probe must keep the same fit width")
        let after = try renderedImage()
        let afterBitmap = try #require(after.representations.first as? NSBitmapImageRep)
        #expect(afterBitmap.pixelsWide > beforeBitmap.pixelsWide,
                "The stored diagram must gain backing pixels after zoom-in")
        #expect(afterBitmap.pixelsWide == Int(ceil(96 * window.backingScaleFactor * nextZoom)))
        #expect(after.size == before.size, "Sharper pixels must preserve point layout")
        #expect(host.text == Self.diagramDoc && textView.string == Self.diagramDoc)

        let renders = diagram.renderCount
        textView.magnificationDidSettle()
        await settlePastRefitDebounce()
        #expect(diagram.renderCount == renders, "Repeated settle at the same density must remain a no-op")
    }

    @Test("a settle at an unchanged effective width is a no-op (oscillation guard)")
    func settleAtSameWidthDoesNotRestyle() async throws {
        let host = Host(Self.diagramDoc)
        let diagram = StubDiagramRenderer()
        let (window, hosting, _, textView) = await mount(host, diagram: diagram)
        defer { window.orderOut(nil) }

        hosting.rootView = Harness(host: host, diagram: diagram, magnification: 0.5)
        hosting.layoutSubtreeIfNeeded()
        await settlePastRefitDebounce()

        let renders = diagram.renderCount
        textView.magnificationDidSettle()
        await settlePastRefitDebounce()
        #expect(diagram.renderCount == renders, "same effective width must not re-render anything")
    }

    @Test("scrolling under a breakout overlay never hides it (anchor = attribute location, not source-range start)")
    func breakoutOverlaySurvivesScrollRealign() async throws {
        let host = Host(Self.monsterTable)
        let diagram = StubDiagramRenderer()
        let (window, hosting, scroll, textView) = await mount(host, diagram: diagram)
        defer { window.orderOut(nil) }

        hosting.rootView = Harness(host: host, diagram: diagram, magnification: 0.5)
        hosting.layoutSubtreeIfNeeded()
        await settlePastRefitDebounce()

        let sourceID = try #require(textView.wideTableOverlays.keys.first)
        let overlay = try #require(textView.wideTableOverlays[sourceID])
        let storage = try #require(textView.textStorage)

        // The invariant realign validates on every scroll tick: the anchor
        // ATTRIBUTE must live at the overlay's anchorTextLocation. Anchoring to
        // the source-range start instead made realign hide the overlay every
        // tick and the reconcile re-show it one turn later (scroll flicker) for
        // any token whose source range starts before its anchor attribute.
        let attributed = storage.attribute(
            .scrollableBlockSourceID, at: overlay.anchorTextLocation, effectiveRange: nil
        ) as? Int
        #expect(attributed == sourceID, "anchorTextLocation must carry the sourceID attribute")

        // Scroll ticks: each boundsDidChange runs the realign glue. The overlay
        // must stay visible through every tick — a single hidden frame is a
        // visible flicker.
        for tick in 0..<6 {
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x,
                                                  y: scroll.contentView.bounds.origin.y + 4))
            scroll.reflectScrolledClipView(scroll.contentView)
            textView.realignWideTableOverlays()
            #expect(!overlay.isHidden, "overlay hidden on scroll tick \(tick) — the flicker")
            spin()
        }
    }

    // MARK: - Mid-zoom layout freeze (field fix: per-frame estimate churn = jitter)

    @Test("overlay realign is frozen while a zoom is in progress and heals after the window")
    func realignFrozenDuringZoom() async throws {
        let host = Host(Self.monsterTable)
        let diagram = StubDiagramRenderer()
        let (window, _, scroll, textView) = await mount(host, diagram: diagram)
        defer { window.orderOut(nil) }

        let clamped = try #require(scroll as? ClampedScrollView)
        let overlay = try #require(textView.wideTableOverlays.values.first)
        let goodFrame = overlay.frame

        // Displace the overlay, then realign INSIDE the zoom window: frozen —
        // chasing estimate-churn anchors per magnify frame was the jitter.
        overlay.frame = goodFrame.offsetBy(dx: 0, dy: 40)
        clamped.noteMagnificationChanged()
        #expect(clamped.isZoomInProgress)
        textView.realignWideTableOverlays()
        #expect(abs(overlay.frame.origin.y - (goodFrame.origin.y + 40)) < 0.5,
                "realign must not touch overlays mid-zoom")

        // Past the 150ms window the same call heals the frame.
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(!clamped.isZoomInProgress)
        textView.realignWideTableOverlays()
        await settle()
        #expect(abs(overlay.frame.origin.y - goodFrame.origin.y) < 1,
                "after the zoom window realign re-derives the true frame")
    }

    // MARK: - Zoom-IN is PDF-pure (field fix: "zooming in on mermaid jumps erratically")

    @Test("zoom-in never re-fits: the 100% layout scales up — no shrink, no pin, no height shifts")
    func zoomInIsPDFPure() async throws {
        let host = Host(Self.diagramDoc)
        let diagram = StubDiagramRenderer()
        let (window, hosting, scroll, textView) = await mount(host, diagram: diagram)
        defer { window.orderOut(nil) }

        func renderedDiagramWidth() -> CGFloat? {
            guard let storage = textView.textStorage else { return nil }
            var width: CGFloat?
            storage.enumerateAttribute(.latexBounds, in: NSRange(location: 0, length: storage.length), options: []) { value, _, stop in
                guard let v = value as? NSValue else { return }
                width = v.rectValue.width
                stop.pointee = true
            }
            return width
        }
        let widthAt1 = try #require(renderedDiagramWidth())
        #expect(abs(widthAt1 - 652) < 4)

        // Zoom IN through the real wrapper: 2.0 (a re-fit here would shrink the
        // diagram to ~326pt — its height change is the erratic jump).
        hosting.rootView = Harness(host: host, diagram: diagram, magnification: 2.0)
        hosting.layoutSubtreeIfNeeded()
        await settlePastRefitDebounce()

        let textContainer = try #require(textView.textContainer)
        #expect(abs(scroll.magnification - 2.0) < 0.01)
        #expect(textView.zoomedBlockFitWidth == nil, "the effective-width override is zoom-OUT only")
        // The fit must track the COLUMN, never the effective width (~326 at
        // 200% — that shrink was the erratic jump). Compare against the live
        // column rather than the 100% snapshot: a legacy vertical scroller can
        // appear at zoom-in and legitimately narrow the clip by ~17pt, exactly
        // like a window resize.
        let widthZoomedIn = try #require(renderedDiagramWidth())
        let columnZoomedIn = scroll.contentView.frame.width - 48
        #expect(abs(widthZoomedIn - columnZoomedIn) < 4, "the fit stays column-sized at zoom-in (PDF-pure)")
        #expect(widthZoomedIn > 500, "the fit must NOT shrink toward the zoomed-in effective width")
        #expect(textContainer.widthTracksTextView, "no wrap pin at zoom-in")
        #expect(abs(textView.frame.width - scroll.contentView.frame.width) < 2, "view stays at the prose width")
        #expect(textView.wideTableOverlays.isEmpty)

        // Back to 100%: column-sized again (the scroller may come or go — the
        // fit follows the live column either way).
        hosting.rootView = Harness(host: host, diagram: diagram, magnification: 1.0)
        hosting.layoutSubtreeIfNeeded()
        await settlePastRefitDebounce()
        let back = try #require(renderedDiagramWidth())
        let columnAtBack = scroll.contentView.frame.width - 48
        #expect(abs(back - columnAtBack) < 4)
    }

    // MARK: - Images (review P1: images must use the effective width too)

    @Test("a wide image expands to its natural size at 50% (inline spill) and re-clamps to the column at 100%")
    func imageRefitsOnZoomOut() async throws {
        let host = Host(Self.imageDoc)
        let diagram = StubDiagramRenderer()
        let images = StubImageProvider()
        let (window, hosting, _, textView) = await mount(host, diagram: diagram, images: images)
        defer { window.orderOut(nil) }

        func renderedImageWidth() -> CGFloat? {
            guard let storage = textView.textStorage else { return nil }
            var width: CGFloat?
            storage.enumerateAttribute(.latexBounds, in: NSRange(location: 0, length: storage.length), options: []) { value, _, stop in
                guard let v = value as? NSValue else { return }
                width = v.rectValue.width
                stop.pointee = true
            }
            return width
        }

        // 100%: the 900pt-natural image clamps to the column (700 − 2×24).
        let clamped = try #require(renderedImageWidth())
        #expect(abs(clamped - 652) < 4, "image fits the column at 100%")

        hosting.rootView = Harness(host: host, diagram: diagram, images: images, magnification: 0.5)
        hosting.layoutSubtreeIfNeeded()
        await settlePastRefitDebounce()

        let refitted = try #require(renderedImageWidth())
        #expect(abs(refitted - StubImageProvider.naturalWidth) < 1,
                "at 50% the effective width frees the image to its natural 900pt — never upscaled beyond it")

        hosting.rootView = Harness(host: host, diagram: diagram, images: images, magnification: 1.0)
        hosting.layoutSubtreeIfNeeded()
        await settlePastRefitDebounce()

        let back = try #require(renderedImageWidth())
        #expect(abs(back - 652) < 4, "back at 100% the image re-clamps to the column")
    }

    // MARK: - Live margin change while zoomed (review P1: stale pinned geometry)

    @Test("a live side-margin change at 50% zoom updates the pinned wrap width, block-fit width, and inset")
    func marginChangeWhileZoomedUpdatesPinnedGeometry() async throws {
        let host = Host(Self.diagramDoc)
        let diagram = StubDiagramRenderer()
        let (window, hosting, scroll, textView) = await mount(host, diagram: diagram)
        defer { window.orderOut(nil) }

        hosting.rootView = Harness(host: host, diagram: diagram, magnification: 0.5)
        hosting.layoutSubtreeIfNeeded()
        await settlePastRefitDebounce()

        let textContainer = try #require(textView.textContainer)
        let prose = scroll.contentView.frame.width
        #expect(!textContainer.widthTracksTextView, "pinned at 50%")
        #expect(abs(textContainer.size.width - (prose - 48)) < 2, "wrap = prose − 2×24 before the change")

        // Drag the Settings margin slider to 60 while zoomed — no magnification change.
        hosting.rootView = Harness(host: host, diagram: diagram, magnification: 0.5, sideMargin: 60)
        hosting.layoutSubtreeIfNeeded()
        await settlePastRefitDebounce()

        #expect(abs(textView.textContainerInset.width - 60) < 1, "live inset adopts the new margin (left-pinned)")
        #expect(abs(textContainer.size.width - (prose - 120)) < 2,
                "the PINNED wrap width re-derives from the new margin — it must not stay stale")
        let fit = try #require(textView.zoomedBlockFitWidth)
        #expect(abs(fit - (scroll.contentView.bounds.width - 120)) < 2,
                "the block-fit width reads the new base margin")

        // A subsequent zoom restack must NOT restore the old inset (the review
        // finding: stale configuration won the next restack).
        hosting.rootView = Harness(host: host, diagram: diagram, magnification: 0.6, sideMargin: 60)
        hosting.layoutSubtreeIfNeeded()
        await settlePastRefitDebounce()
        #expect(abs(textView.textContainerInset.width - 60) < 1, "the next zoom keeps the new margin")
    }

    // MARK: - Centering knob

    @Test("the centering knob places the zoomed-out column via the container inset; off pins it left (default)")
    func centeringKnobPlacesColumn() async throws {
        let host = Host(Self.diagramDoc)
        let diagram = StubDiagramRenderer()
        let (window, hosting, scroll, textView) = await mount(host, diagram: diagram, magnification: 0.5, centers: true)
        defer { window.orderOut(nil) }
        await settlePastRefitDebounce()

        // Column placement is the text CONTAINER's inset inside the
        // zoom-widened view (the view itself spans the window; its X stays 0).
        let prose = scroll.contentView.frame.width
        let expectedInset = 24 + floor((textView.frame.width - prose) / 2)
        #expect(expectedInset > 300, "50% zoom in a 700pt window leaves ~700pt of spill room")
        #expect(abs(textView.textContainerInset.width - expectedInset) < 2, "knob ON centers the wrap column")
        #expect(abs(textView.frame.origin.x) < 1)

        // Live toggle OFF → column pins back to the left edge (base inset).
        hosting.rootView = Harness(host: host, diagram: diagram, magnification: 0.5, centersZoomedOut: false)
        hosting.layoutSubtreeIfNeeded()
        await settlePastRefitDebounce()
        #expect(abs(textView.textContainerInset.width - 24) < 1, "knob OFF pins the column left")
    }
}
