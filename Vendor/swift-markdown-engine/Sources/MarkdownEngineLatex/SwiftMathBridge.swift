//
//  SwiftMathBridge.swift
//  MarkdownEngineLatex
//
//  Ready-made LatexRenderer conformance backed by SwiftMath.
//

import AppKit
import CryptoKit
import Foundation
import OSLog
import SwiftMath
import MarkdownEngine

/// A drop-in ``LatexRenderer`` backed by [SwiftMath].
///
/// Renders both block (`$$ … $$`) and inline (`$ … $`) LaTeX strings into
/// `NSImage`s using the Latin Modern math font. Results are cached per
/// (latex, font size, appearance, theme color fingerprint) so repeated
/// renders are free.
///
/// Light/dark appearance uses the current drawing context, with the host
/// appearance override taking priority. Formula ink therefore follows the
/// editor being styled independently of the key window.
///
/// [SwiftMath]: https://github.com/mgriebling/SwiftMath
public final class SwiftMathBridge: LatexRenderer, @unchecked Sendable {
    private struct CacheKey: Hashable {
        let latex: String
        let fontSize: CGFloat
        let appearance: String
        let color: [CGFloat]
    }

    private struct CacheEntry {
        let image: NSImage
        let size: CGSize
        let baselineOffset: CGFloat
    }

    private let singleLetterPaddingBottom: CGFloat
    private struct CachedRender {
        let entry: CacheEntry?
        let cost: Int
        var lastUse: UInt64
    }

    private let countLimit = 256
    private let costLimit = 32 * 1_024 * 1_024
    private var cache: [CacheKey: CachedRender] = [:]
    private var cacheCost = 0
    private var cacheSequence: UInt64 = 0
    private let cacheLock = NSLock()
    /// Formulas served from the on-disk cache since launch (tests, diagnostics).
    public private(set) var diskCacheHits = 0

    // MARK: - Disk cache
    //
    // A rendered formula is also kept under Caches/com.pageflow.MarkdownEngine
    // as a PNG plus a sidecar (point size, baseline), keyed by the render
    // inputs and the screen scale. Opening a note renders every formula it
    // holds synchronously (0.4 s of a 2.0 s open on a 490 KB note with 286
    // block and hundreds of inline formulas); the second open reads pixels
    // instead. Bump `diskCacheVersion` whenever the rendering itself changes
    // (SwiftMath update, font, cropping) — the key covers the inputs only.
    private static let diskCacheVersion = "v5"
    private static let diskCacheDirectory: URL? = {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let root = base.appendingPathComponent("com.pageflow.MarkdownEngine", isDirectory: true)
        let directory = root.appendingPathComponent("math-\(diskCacheVersion)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        diskQueue.async { pruneDiskCache(root: root, current: directory, limit: diskCacheLimit) }
        return directory
    }()
    private static let diskCacheLimit = 64 * 1024 * 1024

    /// Keeps the cache bounded, once per launch: earlier render versions go,
    /// and past `limit` bytes the least recently written renders go first.
    static func pruneDiskCache(root: URL, current: URL, limit: Int) {
        let fileManager = FileManager.default
        let siblings = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for sibling in siblings where sibling.lastPathComponent.hasPrefix("math-")
            && sibling.lastPathComponent != current.lastPathComponent {
            try? fileManager.removeItem(at: sibling)
        }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
        let files = ((try? fileManager.contentsOfDirectory(at: current, includingPropertiesForKeys: keys)) ?? [])
            .compactMap { url -> (url: URL, written: Date, size: Int)? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                return (url, values.contentModificationDate ?? .distantPast, values.totalFileAllocatedSize ?? 0)
            }
        var total = files.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        for file in files.sorted(by: { $0.written < $1.written }) where total > limit * 3 / 4 {
            try? fileManager.removeItem(at: file.url)
            total -= file.size
        }
    }
    private static let diskQueue = DispatchQueue(label: "com.pageflow.MarkdownEngine.mathDiskCache", qos: .utility)
    private struct DiskSidecar: Codable {
        let width: CGFloat
        let height: CGFloat
        let baselineOffset: CGFloat
    }

    private static func diskName(for key: CacheKey) -> String {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let color = key.color.map { String(describing: $0) }.joined(separator: ",")
        let material = [key.latex, "\(key.fontSize)", key.appearance, color, "\(scale)"]
            .joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func loadFromDisk(_ key: CacheKey) -> CacheEntry? {
        guard let directory = diskCacheDirectory else { return nil }
        let name = diskName(for: key)
        guard let png = try? Data(contentsOf: directory.appendingPathComponent(name + ".png")),
              let json = try? Data(contentsOf: directory.appendingPathComponent(name + ".json")),
              let sidecar = try? JSONDecoder().decode(DiskSidecar.self, from: json),
              let rep = NSBitmapImageRep(data: png) else { return nil }
        let size = CGSize(width: sidecar.width, height: sidecar.height)
        rep.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return CacheEntry(image: image, size: size, baselineOffset: sidecar.baselineOffset)
    }

    private static func saveToDisk(_ entry: CacheEntry, for key: CacheKey) {
        guard let directory = diskCacheDirectory,
              let rep = entry.image.representations.first as? NSBitmapImageRep else { return }
        let sidecar = DiskSidecar(width: entry.size.width, height: entry.size.height, baselineOffset: entry.baselineOffset)
        guard let json = try? JSONEncoder().encode(sidecar) else { return }
        let name = diskName(for: key)
        // The rep is the one AppKit draws from; encode a private copy off the
        // caller's thread (a bitmap rep is not safe to read while it is drawn).
        guard let copy = rep.copy() as? NSBitmapImageRep else { return }
        diskQueue.async {
            guard let png = copy.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
            try? json.write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
        }
    }

    /// PageFlow fork knob: when set, math ink resolves against THIS appearance
    /// instead of the drawing context's. The host sets it from its forced editor
    /// color scheme so a restyle triggered from a different key window (e.g.
    /// toggling the scheme in Settings) can't bake formulas against the wrong
    /// appearance. `nil` uses the current drawing appearance. The cache includes resolved
    /// ink and alpha, so flips and color changes re-render correctly.
    public var appearanceOverride: NSAppearance?

    /// - Parameter singleLetterPaddingBottom: Extra bottom padding (in
    ///   points) added to single-letter formulas to prevent visual
    ///   clipping; matches the engine's
    ///   ``MarkdownEditorConfiguration/blockLatex/singleLetterPaddingBottom``
    ///   default. Override to match a customized configuration.
    public init(singleLetterPaddingBottom: CGFloat = 1.0) {
        self.singleLetterPaddingBottom = singleLetterPaddingBottom
    }

    /// Clears the rendered-image cache. Call after appearance flips if
    /// the host code doesn't re-render formulas automatically.
    public func clearCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheCost = 0
        cacheLock.unlock()
    }

    // MARK: - LatexRenderer

    public func render(
        latex: String,
        fontSize: CGFloat,
        theme: MarkdownEditorTheme
    ) -> LatexRenderResult? {
        let normalizedLatex = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLatex.isEmpty else { return nil }

        let appearance = appearanceOverride ?? NSAppearance.currentDrawing()
        let isDarkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let requestedColor = isDarkMode ? theme.latexDarkModeText : theme.latexLightModeText
        var resolvedColor: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolvedColor = requestedColor.usingColorSpace(.sRGB)
        }
        let textColor = resolvedColor ?? requestedColor
        let key = resolvedColor.map { CacheKey(
            latex: normalizedLatex, fontSize: fontSize, appearance: appearance.name.rawValue,
            color: [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent]
        ) }

        cacheLock.lock()
        if let key, var cached = cache[key] {
            cacheSequence &+= 1
            cached.lastUse = cacheSequence
            cache[key] = cached
            cacheLock.unlock()
            return cached.entry.map(Self.result)
        }
        cacheLock.unlock()

        if let key, let disk = Self.loadFromDisk(key) {
            store(disk, for: key)
            cacheLock.lock()
            diskCacheHits += 1
            cacheLock.unlock()
            return Self.result(disk)
        }

        var entry: CacheEntry?
        appearance.performAsCurrentDrawingAppearance {
            entry = renderLatex(normalizedLatex, fontSize: fontSize, textColor: textColor)
        }
        if let key {
            store(entry, for: key)
            if let entry { Self.saveToDisk(entry, for: key) }
        }
        return entry.map(Self.result)
    }

    // MARK: - Private

    private static func result(_ entry: CacheEntry) -> LatexRenderResult {
        LatexRenderResult(image: entry.image, size: entry.size, baselineOffset: entry.baselineOffset)
    }

    private func store(_ entry: CacheEntry?, for key: CacheKey) {
        let imageCost = entry.map { ceil($0.size.width * $0.size.height * 16) } ?? 0
        guard imageCost.isFinite, imageCost >= 0, imageCost < CGFloat(costLimit) else { return }
        let cost = Int(imageCost) + key.latex.utf16.count * 2
        guard cost <= costLimit else { return }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let previous = cache.removeValue(forKey: key) { cacheCost -= previous.cost }
        while cache.count >= countLimit || cacheCost + cost > costLimit {
            guard let oldest = cache.min(by: { $0.value.lastUse < $1.value.lastUse })?.key,
                  let removed = cache.removeValue(forKey: oldest) else { break }
            cacheCost -= removed.cost
        }
        cacheSequence &+= 1
        cache[key] = CachedRender(entry: entry, cost: cost, lastUse: cacheSequence)
        cacheCost += cost
    }

    private func renderLatex(_ latex: String, fontSize: CGFloat, textColor: NSColor) -> CacheEntry? {
        guard let mathList = Self.parse(latex) else { return nil }
        Self.normalizeBinaryOperators(in: mathList)

        let mathLabel = MTMathUILabel()
        mathLabel.mathList = mathList
        mathLabel.fontSize = fontSize
        mathLabel.textColor = textColor
        mathLabel.textAlignment = .left
        mathLabel.labelMode = .text

        // Latin Modern Math gives the cleanest LaTeX glyphs at typical sizes.
        if let mathFont = MTFontManager().font(withName: "latinmodern-math", size: fontSize) {
            mathLabel.font = mathFont
        }

        mathLabel.layoutSubtreeIfNeeded()

        guard let displayList = mathLabel.displayList else { return nil }

        // SwiftMath skips unsupported glyphs (e.g. emoji/raw Greek), which can yield
        // zero-sized output. Bail instead of trying to render a 0x0 image — lockFocus
        // (used internally by NSImage drawing) crashes on zero dimensions.
        let exactWidth = displayList.width
        let exactHeight = displayList.ascent + displayList.descent
        guard exactWidth > 0, exactHeight > 0 else { return nil }

        let isSimpleSingleLetter = latex.range(of: #"^[A-Za-z]{1,3}$"#, options: .regularExpression) != nil
        let paddingBottom: CGFloat = isSimpleSingleLetter ? singleLetterPaddingBottom : 0
        let canvasHeight = exactHeight + paddingBottom

        // `displayList.width` is the advance width, which excludes the right-side ink
        // overhang of slanted glyphs (V, Y, P, F, …) — cropping to it clips them.
        // Render with right slack, then crop to the measured ink edge.
        let rightSlack = ceil(fontSize)
        let probeWidth = ceil(exactWidth) + rightSlack

        guard let probeRep = renderLabelToRep(mathLabel, size: CGSize(width: probeWidth, height: canvasHeight)),
              let probeCG = probeRep.cgImage else {
            return nil
        }

        let inkRight = Self.inkRightEdge(probeCG, widthInPoints: probeWidth) ?? exactWidth
        let finalWidth = max(ceil(exactWidth), ceil(inkRight))
        let finalSize = CGSize(width: finalWidth, height: canvasHeight)

        // Crop to the measured width (full height kept); points→pixels via the rep,
        // so this is correct at any backing scale.
        let pxPerPoint = CGFloat(probeCG.width) / probeWidth
        let cropPx = min(probeCG.width, Int((finalWidth * pxPerPoint).rounded()))
        guard cropPx > 0,
              let croppedCG = probeCG.cropping(to: CGRect(x: 0, y: 0, width: cropPx, height: probeCG.height)) else {
            return nil
        }

        let finalRep = NSBitmapImageRep(cgImage: croppedCG)
        finalRep.size = finalSize
        let image = NSImage(size: finalSize)
        image.addRepresentation(finalRep)

        return CacheEntry(
            image: image,
            size: finalSize,
            baselineOffset: displayList.descent
        )
    }

    /// The formula as SwiftMath parses it, after the compatibility rewrite and
    /// up to a few error-driven structural repairs (an unpaired `\left`,
    /// sizing that could not be paired, a missing brace). Unsupported commands
    /// return nil so the styler shows the source without changing its meaning.
    static func parse(_ latex: String) -> MTMathList? {
        _ = LatexCompatibility.registerMissingSymbols
        // Paired sizing reads best; a formula whose pairs span aligned rows
        // still renders with the sizing dropped.
        for pairingSizing in [true, false] {
            if let list = parseRepairing(LatexCompatibility.rewrite(latex, pairingSizing: pairingSizing)) {
                return list
            }
        }
        Self.logger.debug("unrenderable formula")
        return nil
    }

    private static func parseRepairing(_ rewritten: String) -> MTMathList? {
        var candidate = rewritten
        for _ in 0..<6 {
            var parseError: NSError?
            if let list = MTMathListBuilder.build(fromString: candidate, error: &parseError), parseError == nil {
                return list
            }
            guard let parseError, let repaired = LatexCompatibility.repair(candidate, error: parseError),
                  repaired != candidate else { return nil }
            candidate = repaired
        }
        return nil
    }

    private static let logger = Logger(subsystem: "com.pageflow.MarkdownEngine", category: "Latex")

    /// TeX Appendix G rules 5 and 6, applied to EVERY nested list. SwiftMath's own
    /// `MTMathList.finalized` applies them to the top level, scripts, fractions,
    /// radicals and `\left…\right` groups, but not to table cells (`aligned`,
    /// `matrix`, …) or over/underline, accent and color bodies. A binary operator
    /// left unnormalized there makes the typesetter assert "Invalid space between
    /// Relation and Binary Operator" in Debug builds (SwiftMath 1.7.3,
    /// MTTypesetter.swift:810) and drops the spacing in Release. Idempotent: the
    /// unary atoms this produces are what SwiftMath's finalize would have produced.
    static func normalizeBinaryOperators(in list: MTMathList) {
        var previous: MTMathAtom?
        for atom in list.atoms {
            for nested in Self.nestedLists(of: atom) {
                normalizeBinaryOperators(in: nested)
            }
            // The typesetter looks THROUGH spacing (`\;`, `\!`) and style
            // (`\displaystyle`) atoms when it picks the neighbour for
            // inter-element spacing, so the rules must look through them too:
            // `y \;=\; -x` is still a relation followed by a binary operator.
            if atom.type == .space || atom.type == .style { continue }
            if atom.type == .binaryOperator, Self.demotesFollowingBinaryOperator(previous?.type) {
                atom.type = .unaryOperator
            }
            if let previous, previous.type == .binaryOperator,
               atom.type == .relation || atom.type == .punctuation || atom.type == .close {
                previous.type = .unaryOperator
            }
            previous = atom
        }
        if let previous, previous.type == .binaryOperator {
            previous.type = .unaryOperator
        }
    }

    /// Rule 5: a binary operator at the start of a list, or after one of these
    /// atom types, is unary (`-x`, `= -1`, `(-a`, `, -b`, `\sum -c`).
    private static func demotesFollowingBinaryOperator(_ previousType: MTMathAtomType?) -> Bool {
        guard let previousType else { return true }
        switch previousType {
        case .binaryOperator, .relation, .open, .punctuation, .largeOperator: return true
        default: return false
        }
    }

    private static func nestedLists(of atom: MTMathAtom) -> [MTMathList] {
        var lists = [atom.subScript, atom.superScript]
        switch atom {
        case let fraction as MTFraction: lists += [fraction.numerator, fraction.denominator]
        case let radical as MTRadical: lists += [radical.radicand, radical.degree]
        case let inner as MTInner: lists.append(inner.innerList)
        case let overline as MTOverLine: lists.append(overline.innerList)
        case let underline as MTUnderLine: lists.append(underline.innerList)
        case let accent as MTAccent: lists.append(accent.innerList)
        case let color as MTMathColor: lists.append(color.innerList)
        case let textColor as MTMathTextColor: lists.append(textColor.innerList)
        case let box as MTMathColorbox: lists.append(box.innerList)
        case let table as MTMathTable: lists += table.cells.flatMap { $0 }
        default: break
        }
        return lists.compactMap { $0 }
    }

    private func renderLabelToRep(_ label: MTMathUILabel, size: CGSize) -> NSBitmapImageRep? {
        // `bitmapImageRepForCachingDisplay` + `cacheDisplay(in:to:)` is the
        // documented way to snapshot an NSView that isn't in a window. Setting
        // `wantsLayer = true` and `layer.render(in:)` snapshots the (empty)
        // backing layer instead of triggering MTMathUILabel's `draw(_:)`.
        label.frame = CGRect(origin: .zero, size: size)
        label.layoutSubtreeIfNeeded()

        guard let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) else { return nil }
        label.cacheDisplay(in: label.bounds, to: rep)
        return rep
    }

    /// Right-most x (in points) containing non-transparent ink, or `nil` if empty —
    /// lets us crop a formula to its true ink width instead of the advance width.
    private static func inkRightEdge(_ image: CGImage, widthInPoints: CGFloat) -> CGFloat? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0, widthInPoints > 0 else { return nil }

        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: &data, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Scan each row from the right, stopping once we pass the running max.
        var maxX = -1
        for y in 0..<h {
            let row = y * bytesPerRow
            var x = w - 1
            while x > maxX {
                if data[row + x * 4 + 3] > 10 { maxX = x; break }
                x -= 1
            }
        }
        guard maxX >= 0 else { return nil }

        // +1: pixel `maxX` spans [maxX, maxX+1). Convert to points.
        return (CGFloat(maxX) + 1) * widthInPoints / CGFloat(w)
    }
}
