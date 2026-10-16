//
//  ItalicFallback.swift
//  MarkdownEngine
//
//  CJK has no italic faces: the `.italic` symbolic trait slants only the
//  glyphs the italic base font (e.g. SF Pro Italic) actually covers — Han /
//  Kana / Hangul fall back per-glyph to an UPRIGHT face (PingFang…), so
//  `*中文*` renders with no emphasis at all. The fix is the synthetic oblique
//  browsers use (`font-synthesis: style`): shear the glyphs that have no real
//  italic face by ~14° — same glyph shapes, slanted.
//
//  MECHANISM — three hard-won constraints (each replaced a failed attempt):
//
//  1. The slant must live in the FONT MATRIX. TextKit 2 ignores the
//     `.obliqueness` attribute (Apple: "This attribute is not supported with
//     TextKit 2"); an attribute-based slant renders as nothing.
//
//  2. The sheared font must be built by CONVERTING the concrete font —
//     `CTFontCreateCopyWithAttributes` — never by descriptor round-trips.
//     `NSFont(descriptor:textTransform:)` re-enters font MATCHING: private
//     system-font descriptors can resolve to Times New Roman (rdar://6153065;
//     CoreText logs "it will get TimesNewRomanPSMT"), and named-font
//     descriptors can drop the point size to 1 — the field failure was serif
//     Latin plus invisible (1pt) CJK.
//
//  3. For a Latin base, the shear is applied to the CONCRETE CASCADE FONT the
//     system already renders those characters with (resolved via
//     `CTFontCreateForString`), the way WebKit computes synthesis per
//     fallback font — matrix inheritance through the cascade is undocumented,
//     so it is not relied on. Latin keeps its true italic face.
//
//  `ItalicShearRenderTests` pins all of this at the PIXEL level (glyphs
//  present + slanted), because attribute-level tests passed twice while the
//  editor rendered nothing.
//

import AppKit
import CoreText

enum ItalicFallback {
    /// Synthetic-oblique skew: tan(14°) — the angle WebKit renders for
    /// `font-synthesis: style` (Chromium skews 0.25), so `*中文*` matches
    /// what Safari/Chrome/Obsidian show.
    static let skew = CGFloat(tan(14.0 * CGFloat.pi / 180.0))

    /// Sheared variant of `font`: the SAME concrete font converted to carry a
    /// slanted matrix — `CTFontCreateCopyWithAttributes` performs a conversion
    /// of the font reference, never descriptor matching, so family, face, and
    /// point size are preserved by construction (size 0.0 = keep). Idempotent.
    static func shearedFont(from font: NSFont) -> NSFont {
        guard !isSheared(font) else { return font }
        var matrix = CGAffineTransform(a: 1, b: 0, c: skew, d: 1, tx: 0, ty: 0)
        return CTFontCreateCopyWithAttributes(font as CTFont, 0.0, &matrix, nil) as NSFont
    }

    /// Whether `font` already carries the synthetic shear (idempotence + tests).
    static func isSheared(_ font: NSFont) -> Bool {
        CTFontGetMatrix(font as CTFont).c != 0
    }

    /// The overlay for one UNCOVERED subrange of an italic run (Latin base):
    /// the concrete font the cascade already renders those characters with —
    /// resolved with `CTFontCreateForString`, exactly what glyph substitution
    /// will pick — sheared only when that font truly lacks an italic face
    /// (WebKit's per-fallback synthesis rule). Pinning the resolved font keeps
    /// the mechanism deterministic on every macOS release.
    static func cascadeOverlay(
        for range: NSRange,
        in ns: NSString,
        base: NSFont
    ) -> [NSAttributedString.Key: Any] {
        let resolved = CTFontCreateForString(
            base as CTFont,
            ns as CFString,
            CFRange(location: range.location, length: range.length)
        ) as NSFont
        if CTFontGetSymbolicTraits(resolved as CTFont).contains(.traitItalic) {
            return [.font: resolved]
        }
        return [.font: shearedFont(from: resolved)]
    }

    /// The single source of truth for the composed-italic shear policy. Given
    /// one ALREADY-COMPOSED run — its resolved `font`, the run's `range`, and
    /// the backing `ns` — return the overlay attribute runs to apply, deciding
    /// between the two branches with the SAME predicate the live styler uses:
    ///
    ///   (a) `noItalicFace` — the family has NO italic face at all (every CJK
    ///       system family: PingFang / Songti / Kaiti), so the trait could not
    ///       bind: shear the WHOLE run's own font (bold still binds through the
    ///       composed font; nested runs are sheared per-run by the callers).
    ///   (b) otherwise, when the font carries a real italic face: pin + shear
    ///       the concrete cascade font on exactly the UNCOVERED subranges — the
    ///       CJK glyphs the italic face can't reach and that would otherwise
    ///       fall back to an upright face. A non-italic run needs nothing.
    static func syntheticItalicOverlays(
        forRun font: NSFont,
        range: NSRange,
        in ns: NSString,
        noItalicFace: Bool
    ) -> [(range: NSRange, attributes: [NSAttributedString.Key: Any])] {
        if noItalicFace {
            return [(range, [.font: shearedFont(from: font)])]
        }
        guard font.fontDescriptor.symbolicTraits.contains(.italic) else { return [] }
        return uncoveredRanges(in: ns, range: range, italicFont: font).map { r in
            (r, cascadeOverlay(for: r, in: ns, base: font))
        }
    }

    /// Shear EVERY font run inside `range` — the whole-subtree synthetic
    /// italic for families with no italic face at all. Per-run (branch (a) of
    /// `syntheticItalicOverlays`), so nested bold/code fonts keep their faces
    /// and only gain the slant.
    static func shearFontRuns(in attributed: NSMutableAttributedString, range: NSRange) {
        let ns = attributed.string as NSString
        var overlays: [(range: NSRange, attributes: [NSAttributedString.Key: Any])] = []
        attributed.enumerateAttribute(.font, in: range, options: []) { value, r, _ in
            guard let font = value as? NSFont, !isSheared(font) else { return }
            overlays += syntheticItalicOverlays(forRun: font, range: r, in: ns, noItalicFace: true)
        }
        for (r, attrs) in overlays {
            attributed.addAttributes(attrs, range: r)
        }
    }

    /// Resolve `descriptor` at `size` with `traits` — the ONE font-composition
    /// seam for emphasis (live styler AND table cells).
    ///
    /// Families with no italic face at all (every CJK system family: PingFang,
    /// Songti, Kaiti) return NO font for ANY italic-containing combination, so
    /// a plain `withSymbolicTraits` + `?? fallback` silently dropped the WHOLE
    /// request — `*x*` stayed upright and `***x***` lost its bold too. Here the
    /// slant is retried without `.italic` so the remaining traits still bind
    /// (bold survives), and `syntheticOblique: true` tells the caller to
    /// overlay `syntheticItalicOverlays` on the whole run.
    static func resolveFont(
        traits: NSFontDescriptor.SymbolicTraits,
        descriptor: NSFontDescriptor,
        size: CGFloat,
        fallback: NSFont
    ) -> (font: NSFont, syntheticOblique: Bool) {
        if let exact = NSFont(descriptor: descriptor.withSymbolicTraits(traits), size: size) {
            // Matching can also degrade silently: an upright face WITHOUT the
            // trait instead of a nil — treat that the same as a missing face.
            let slantDropped = traits.contains(.italic)
                && !exact.fontDescriptor.symbolicTraits.contains(.italic)
            return (exact, slantDropped)
        }
        guard traits.contains(.italic) else { return (fallback, false) }
        let upright = traits.subtracting(.italic)
        let font = NSFont(descriptor: descriptor.withSymbolicTraits(upright), size: size) ?? fallback
        return (font, true)
    }

    /// Maximal subranges of `range` whose characters are NOT covered by
    /// `italicFont` (they will render via an upright fallback face).
    ///
    /// This runs for every italic run on every restyle (including per-keystroke
    /// paragraph restyles), so the common pure-Latin run must cost nothing: a
    /// raw UTF-16 pre-scan bails before ANY bridging or allocation when every
    /// unit sits below U+0300 (CJK and surrogate halves are all above it), and
    /// the real walk decodes scalars by hand instead of substring-ing.
    static func uncoveredRanges(in ns: NSString, range: NSRange, italicFont: NSFont) -> [NSRange] {
        guard range.length > 0, NSMaxRange(range) <= ns.length else { return [] }
        let end = NSMaxRange(range)

        var mightNeedFallback = false
        var probe = range.location
        while probe < end {
            if ns.character(at: probe) >= 0x0300 {
                mightNeedFallback = true
                break
            }
            probe += 1
        }
        guard mightNeedFallback else { return [] }

        let covered = italicFont.coveredCharacterSet as CharacterSet
        var result: [NSRange] = []
        var runStart = -1
        var index = range.location
        while index < end {
            let unit = ns.character(at: index)
            var scalarValue = UInt32(unit)
            var width = 1
            if UTF16.isLeadSurrogate(unit), index + 1 < end,
               UTF16.isTrailSurrogate(ns.character(at: index + 1)) {
                scalarValue = 0x10000
                    + ((UInt32(unit) - 0xD800) << 10)
                    + (UInt32(ns.character(at: index + 1)) - 0xDC00)
                width = 2
            }
            // An unpaired surrogate half has no scalar — treat as uncovered
            // (slanting a broken glyph is harmless).
            let isCovered = UnicodeScalar(scalarValue).map(covered.contains) ?? false
            if !isCovered {
                if runStart < 0 { runStart = index }
            } else if runStart >= 0 {
                result.append(NSRange(location: runStart, length: index - runStart))
                runStart = -1
            }
            index += width
        }
        if runStart >= 0 {
            result.append(NSRange(location: runStart, length: end - runStart))
        }
        return result
    }

    /// Post-process for standalone attributed strings (table cells): walk the
    /// `.font` runs and overlay the cascade-resolved shear on every italic
    /// run's uncovered subranges (branch (b) of `syntheticItalicOverlays`).
    static func applyToItalicRuns(in attributed: NSMutableAttributedString) {
        let ns = attributed.string as NSString
        let full = NSRange(location: 0, length: attributed.length)
        var overlays: [(range: NSRange, attributes: [NSAttributedString.Key: Any])] = []
        attributed.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            guard let font = value as? NSFont else { return }
            overlays += syntheticItalicOverlays(forRun: font, range: range, in: ns, noItalicFace: false)
        }
        for (range, attrs) in overlays {
            attributed.addAttributes(attrs, range: range)
        }
    }
}
