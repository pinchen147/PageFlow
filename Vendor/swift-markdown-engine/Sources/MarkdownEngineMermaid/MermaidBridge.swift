//
//  MermaidBridge.swift
//  MarkdownEngineMermaid
//
//  Ready-made BlockDiagramRenderer conformance backed by BeautifulMermaid
//  (native Swift — no WebView, no JavaScript). The diagram peer of
//  SwiftMathBridge.
//

import AppKit
import Foundation
import BeautifulMermaid
import MarkdownEngine

/// A drop-in ``BlockDiagramRenderer`` backed by [BeautifulMermaid], a native
/// Swift Mermaid renderer (CoreText/CoreGraphics — no WebView, no JavaScript,
/// no DOM).
///
/// `render(source:…)` is **synchronous**, exactly like ``LatexRenderer``: the
/// library parses → lays out → rasterizes to an `NSImage` on the calling thread
/// and returns `nil` on any failure — unknown diagram type, syntax error, empty,
/// or degenerate zero-size output — so the editor reveals the raw
/// ```` ```mermaid ```` source instead of a wrong diagram (the "never lie, show
/// the source" contract). It cannot detect a *supported* diagram type that uses
/// an *unsupported feature* (e.g. HTML labels), which BeautifulMermaid silently
/// ignores; that is an accepted limitation of the native subset (ADR-0011).
///
/// The **natural** (unfitted) raster is cached per (source, font size,
/// appearance) — NOT per width — so repeated restyles are free and a
/// live margin drag / window resize re-fits the SAME cached raster to the new
/// column per call instead of caching a stale width. The cache retains up to
/// 256 entries and 32 MiB of backing pixels plus source keys, evicting the least
/// recently used rasters. Oversized images still render without being cached.
/// The cached image is never mutated, so sharing it across tabs and fit widths
/// is safe.
///
/// Light/dark ink follows the host editor's forced appearance
/// (``appearanceOverride``) when set — same reason as ``SwiftMathBridge``: a
/// restyle triggered while another window is key must not bake the diagram
/// against the wrong scheme.
///
/// [BeautifulMermaid]: https://github.com/lukilabs/beautiful-mermaid-swift
public final class MermaidBridge: BlockDiagramRenderer, @unchecked Sendable {
    private struct CacheKey: Hashable {
        let source: String
        let fontSize: CGFloat
        let isDark: Bool
        /// Raster density the natural image was baked at (see `effectiveScale`).
        /// Zoom-in re-renders at a higher density so magnified diagrams stay
        /// crisp; each density is its own immutable cache entry (ADR-0019).
        let scale: CGFloat
    }

    private struct Entry {
        /// The diagram at its natural size (point size + `renderScale` backing).
        /// Immutable and shared across fit widths — the fragment draw scales it
        /// into the per-call reserved rect, so this is never resized.
        let image: NSImage
        let naturalSize: CGSize
        let cost: Int?
    }

    private struct CachedRender {
        let entry: Entry
        let cost: Int
        var lastUse: UInt64
    }

    private var cache: [CacheKey: CachedRender] = [:]
    private var cacheCost = 0
    /// Renders that failed, so a broken diagram is laid out once, not on every
    /// restyle. Bounded; cleared wholesale when full.
    private var failedKeys: Set<CacheKey> = []

    /// Diagrams with more source than this show as source: layout runs
    /// synchronously, and a pathological diagram would stall every restyle
    /// (and every launch that restores its note).
    static let maxSourceLength = 16_000
    private var cacheSequence: UInt64 = 0
    private let cacheLock = NSLock()
    private let renderScale: CGFloat
    private let cacheCountLimit: Int
    private let cacheCostLimit: Int

    /// Fork knob mirroring ``SwiftMathBridge/appearanceOverride``: when set,
    /// diagram ink resolves against THIS appearance instead of the key window's,
    /// so a restyle from a different key window (e.g. toggling the Settings
    /// scheme) can't bake a diagram against the wrong appearance. The cache is
    /// keyed by resolved dark/light, so flips re-render correctly.
    public var appearanceOverride: NSAppearance?

    /// - Parameter renderScale: backing raster scale (points → pixels). 2.0
    ///   keeps diagrams crisp on Retina and gives downscale headroom when a wide
    ///   diagram is fitted to the reading column.
    public convenience init(renderScale: CGFloat = 2.0) {
        self.init(renderScale: renderScale, cacheCountLimit: 256,
                  cacheCostLimit: 32 * 1_024 * 1_024)
    }

    init(renderScale: CGFloat, cacheCountLimit: Int, cacheCostLimit: Int) {
        self.renderScale = renderScale
        self.cacheCountLimit = max(1, cacheCountLimit)
        self.cacheCostLimit = max(0, cacheCostLimit)
    }

    /// Clears the rendered-image cache (e.g. after an appearance flip if the host
    /// doesn't re-render automatically).
    public func clearCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheCost = 0
        cacheSequence = 0
        cacheLock.unlock()
    }

    // MARK: - BlockDiagramRenderer

    public func render(
        source: String,
        language: String,
        maxWidth: CGFloat,
        fontSize: CGFloat,
        theme: MarkdownEditorTheme
    ) -> DiagramRenderResult? {
        render(source: source, language: language, maxWidth: maxWidth,
               fontSize: fontSize, theme: theme, pixelScale: renderScale)
    }

    public func render(
        source: String,
        language: String,
        maxWidth: CGFloat,
        fontSize: CGFloat,
        theme: MarkdownEditorTheme,
        pixelScale: CGFloat
    ) -> DiagramRenderResult? {
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, maxWidth > 1, normalized.utf16.count <= Self.maxSourceLength else { return nil }

        // `NSApp` is an implicitly-unwrapped optional that is nil until an
        // NSApplication exists; bind it optionally so a render off any app (a
        // unit test, a headless export) resolves a sane appearance instead of
        // crashing. In the live editor `appearanceOverride` / the key window
        // always win first.
        let sharedApp: NSApplication? = NSApp
        let appearance = appearanceOverride
            ?? sharedApp?.keyWindow?.effectiveAppearance
            ?? sharedApp?.effectiveAppearance
            ?? NSAppearance(named: .aqua)!
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        // Cache the NATURAL raster (width-independent); fit is computed per call
        // below, so adjacent widths never reuse a stale fitted size.
        let scale = effectiveScale(for: pixelScale)
        let key = CacheKey(source: normalized, fontSize: fontSize, isDark: isDark, scale: scale)

        cacheLock.lock()
        let cached: Entry?
        if var hit = cache[key] {
            cacheSequence &+= 1
            hit.lastUse = cacheSequence
            cache[key] = hit
            cached = hit.entry
        } else {
            cached = nil
        }
        cacheLock.unlock()

        let entry: Entry
        if let cached {
            entry = cached
        } else {
            cacheLock.lock()
            let failedBefore = failedKeys.contains(key)
            cacheLock.unlock()
            guard !failedBefore else { return nil }
            guard let fresh = renderNatural(normalized, fontSize: fontSize, isDark: isDark, scale: scale) else {
                cacheLock.lock()
                if failedKeys.count >= cacheCountLimit { failedKeys.removeAll() }
                failedKeys.insert(key)
                cacheLock.unlock()
                return nil
            }
            store(fresh, for: key)
            entry = fresh
        }

        // Fit the cached raster to the reading column THIS call; never upscale a
        // diagram narrower than the column ("fit width, scroll if tiny"). The
        // fragment draw downscales the natural-size, `renderScale`-backed image
        // crisply into this reserved `size` — the cached image is not touched.
        let fit = min(1, maxWidth / entry.naturalSize.width)
        let size = CGSize(width: (entry.naturalSize.width * fit).rounded(),
                          height: (entry.naturalSize.height * fit).rounded())
        return DiagramRenderResult(image: entry.image, size: size)
    }

    // MARK: - Private

    private func store(_ entry: Entry, for key: CacheKey) {
        guard let cost = entry.cost, cost <= cacheCostLimit else { return }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let previous = cache.removeValue(forKey: key) { cacheCost -= previous.cost }
        while cache.count >= cacheCountLimit || cost > cacheCostLimit - cacheCost {
            guard let oldest = cache.min(by: { $0.value.lastUse < $1.value.lastUse })?.key,
                  let removed = cache.removeValue(forKey: oldest) else { break }
            cacheCost -= removed.cost
        }
        cacheSequence &+= 1
        cache[key] = CachedRender(entry: entry, cost: cost, lastUse: cacheSequence)
        cacheCost += cost
    }

    private static func cacheCost(of raster: CGImage, source: String) -> Int? {
        let (pixelCost, pixelOverflow) = raster.bytesPerRow.multipliedReportingOverflow(by: raster.height)
        let (sourceCost, sourceOverflow) = source.utf16.count.multipliedReportingOverflow(by: 2)
        let (cost, totalOverflow) = pixelCost.addingReportingOverflow(sourceCost)
        guard !pixelOverflow, !sourceOverflow, !totalOverflow, pixelCost > 0 else { return nil }
        return cost
    }

    /// Raster density for a render: never below the base `renderScale` (Retina
    /// floor + downscale headroom), quantized to 0.5 steps so a pinch that
    /// settles at 1.62× and one at 1.68× share a cache entry, and capped at 4×
    /// — beyond that the memory cost of a large diagram outweighs the last bit
    /// of sharpness at extreme zoom (ADR-0019).
    private func effectiveScale(for pixelScale: CGFloat) -> CGFloat {
        guard pixelScale.isFinite, pixelScale > renderScale else { return renderScale }
        return min((pixelScale * 2).rounded(.up) / 2, 4)
    }

    private func renderNatural(_ source: String, fontSize: CGFloat, isDark: Bool, scale: CGFloat) -> Entry? {
        var diagramTheme = isDark ? DiagramTheme.zincDark : DiagramTheme.zincLight
        // Transparent canvas → the editor background shows through; node fills,
        // strokes and ink are still drawn. Labels track the editor's text size.
        diagramTheme.transparent = true
        diagramTheme.font = BMFont.systemFont(ofSize: fontSize)

        // `try?` → nil folds every BeautifulMermaid failure (unknown diagram
        // type, syntax error, empty, degenerate 0-size output) into the
        // show-the-source fallback.
        guard let raw = try? MermaidRenderer.renderImage(source: source, theme: diagramTheme, scale: scale) else {
            return nil
        }
        let natural = raw.size
        guard natural.width > 0, natural.height > 0 else { return nil }
        let corrected = correctingOrientation(raw)
        let cost = corrected.raster.flatMap { Self.cacheCost(of: $0, source: source) }
        return Entry(image: corrected.image, naturalSize: natural, cost: cost)
    }

    /// BeautifulMermaid 1.0.4's macOS `renderImage` rasterizes into a raw
    /// bottom-left-origin `CGContext` **without flipping**, while its
    /// `DiagramRenderer` lays out top-left — so the returned `NSImage` is
    /// vertically MIRRORED (the root of a `flowchart TB` lands at the bottom and
    /// every glyph is upside down). Correct it by flipping the raster back at the
    /// CGImage level, which preserves the full backing resolution (a `lockFocus`
    /// redraw would downsample to 1×).
    ///
    /// Version-specific: if a BeautifulMermaid bump fixes its macOS raster path,
    /// remove this — `MermaidOrientationTests` fails on the resulting double-flip.
    private func correctingOrientation(_ image: NSImage) -> (image: NSImage, raster: CGImage?) {
        // Full-resolution CGImage: with no hints, cgImage(forProposedRect:)
        // caps the returned raster at the DEVICE scale (2×), silently
        // downsampling the higher-density renders the zoom-in pixelScale asks
        // for — hint the rep's true pixel/point ratio via the CTM instead.
        let pixelsWide = image.representations.map(\.pixelsWide).max() ?? 0
        let ratio = image.size.width > 0 ? CGFloat(pixelsWide) / image.size.width : 1
        let transform = NSAffineTransform()
        transform.scale(by: max(ratio, 1))
        var proposed = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: [.ctm: transform])
        else { return (image, nil) }
        guard let space = cg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: cg.width, height: cg.height,
                                  bitsPerComponent: cg.bitsPerComponent, bytesPerRow: 0,
                                  space: space, bitmapInfo: cg.bitmapInfo.rawValue)
        else { return (image, nil) }   // can't flip → show it as-is without caching an unknown backing
        ctx.translateBy(x: 0, y: CGFloat(cg.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let flipped = ctx.makeImage() else { return (image, nil) }
        return (NSImage(cgImage: flipped, size: image.size), flipped)
    }
}
