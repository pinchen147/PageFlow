//
//  ItalicFallbackTests.swift
//  MarkdownEngineTests
//
//  CJK italic: `*中文*` must not render upright. The mechanism (see
//  ItalicFallback's header) is WebKit-style synthetic oblique: shear the
//  CONCRETE font — CTFontCreateCopyWithAttributes, never descriptor
//  matching — pinned to the cascade font that already renders the glyphs.
//
//  Two prior implementations passed attribute-level tests while rendering
//  wrong (ignored .obliqueness; Times/1pt descriptor re-matching), so the
//  assertions here are deliberately paranoid: font IDENTITY (family, size)
//  is asserted everywhere, and ItalicShearRenderTests verifies glyph
//  PRESENCE + slant at the pixel level.
//

import AppKit
import CoreText
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Italic fallback for CJK")
struct ItalicFallbackTests {

    private var italicSystemFont: NSFont {
        let base = NSFont.systemFont(ofSize: 16)
        return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.italic), size: 16) ?? base
    }

    private func isShearOverlay(_ attrs: [NSAttributedString.Key: Any]) -> Bool {
        (attrs[.font] as? NSFont).map(ItalicFallback.isSheared) ?? false
    }

    // MARK: - Mechanism

    @Test func skewMatchesBrowserSyntheticObliqueAngle() {
        // tan(14°) — WebKit's synthetic-oblique angle.
        #expect(abs(ItalicFallback.skew - 0.2493) < 0.001)
    }

    @Test func shearedFontPreservesIdentityAndSlantsTheMatrix() {
        let base = NSFont.systemFont(ofSize: 16)
        let sheared = ItalicFallback.shearedFont(from: base)
        #expect(ItalicFallback.isSheared(sheared))
        #expect(!ItalicFallback.isSheared(base))
        // The system font's ALIAS name (.AppleSystemUIFont) canonicalizes to
        // the PostScript name (.SFNS-Regular) through the CTFont conversion —
        // same physical font. Family is the identity that must survive.
        #expect(sheared.familyName == base.familyName, "conversion must not re-match the font (Times trap)")
        #expect(sheared.familyName?.contains("Times") != true)
        #expect(sheared.pointSize == base.pointSize, "conversion must not collapse the size (1pt trap)")
        // Idempotent: shearing a sheared font is a pass-through.
        #expect(ItalicFallback.shearedFont(from: sheared) === sheared)
    }

    @Test func shearedFontOnNamedCJKFamilyPreservesSize() throws {
        // Field regression: the descriptor round-trip collapsed PingFang to
        // 1pt — invisible glyphs. The CTFont conversion must keep 16pt.
        let pingfang = try #require(NSFont(name: "PingFang SC", size: 16))
        let sheared = ItalicFallback.shearedFont(from: pingfang)
        #expect(sheared.pointSize == 16)
        #expect(sheared.familyName == pingfang.familyName)
        #expect(ItalicFallback.isSheared(sheared))
    }

    @Test func cascadeOverlayPinsTheShearedCascadeFont() {
        let ns = "中文" as NSString
        let attrs = ItalicFallback.cascadeOverlay(
            for: NSRange(location: 0, length: 2), in: ns, base: italicSystemFont
        )
        let font = attrs[.font] as? NSFont
        #expect(font != nil)
        #expect(font.map(ItalicFallback.isSheared) == true, "CJK cascade font has no italic → sheared")
        #expect(font?.pointSize == 16)
        // The pinned font must be the one that actually renders Han glyphs.
        let covers = (font?.coveredCharacterSet as CharacterSet?)?.contains("中") ?? false
        #expect(covers, "pinned cascade font must cover the characters it is pinned for")
    }

    @Test func uncoveredRangesIsolateCJKOnly() {
        let ns = "abc中文字def" as NSString
        let ranges = ItalicFallback.uncoveredRanges(
            in: ns, range: NSRange(location: 0, length: ns.length), italicFont: italicSystemFont
        )
        #expect(ranges == [ns.range(of: "中文字")])
    }

    @Test func pureLatinNeedsNoFallback() {
        let ns = "abcdef" as NSString
        let ranges = ItalicFallback.uncoveredRanges(
            in: ns, range: NSRange(location: 0, length: ns.length), italicFont: italicSystemFont
        )
        #expect(ranges.isEmpty)
    }

    // MARK: - Live-preview styler

    @Test func styledDocumentShearsCJKEmphasisOnly() {
        let text = "plain *中文斜体* and *latin* tail"
        let ns = text as NSString
        let attrs = MarkdownStyler.styleAttributes(
            text: text,
            fontName: NSFont.systemFont(ofSize: 16).fontName,
            fontSize: 16,
            caretLocation: -1,
            activeTokenIndices: [],
            configuration: .default
        )
        let cjk = ns.range(of: "中文斜体")
        let latin = ns.range(of: "latin")
        let cjkLastFont = attrs.last {
            NSIntersectionRange($0.range, cjk).length > 0 && $0.attributes[.font] is NSFont
        }?.attributes[.font] as? NSFont
        let latinSheared = attrs.contains {
            NSIntersectionRange($0.range, latin).length > 0 && isShearOverlay($0.attributes)
        }
        #expect(cjkLastFont.map(ItalicFallback.isSheared) == true, "CJK emphasis must end sheared")
        #expect(cjkLastFont?.pointSize == 16)
        #expect(!latinSheared, "Latin emphasis keeps its real italic face")
    }

    @Test func nestedBoldInsideItalicKeepsCJKShear() {
        // `**中文**` inside `*…*` composes a bold-italic font whose append
        // clobbers the outer overlay — the nested node must re-apply it.
        let text = "*前 **中文** 后*"
        let ns = text as NSString
        let attrs = MarkdownStyler.styleAttributes(
            text: text,
            fontName: NSFont.systemFont(ofSize: 16).fontName,
            fontSize: 16,
            caretLocation: -1,
            activeTokenIndices: [],
            configuration: .default
        )
        let nested = ns.range(of: "中文")
        let last = attrs.last {
            NSIntersectionRange($0.range, nested).length > 0 && $0.attributes[.font] is NSFont
        }
        #expect(last.map { isShearOverlay($0.attributes) } == true,
                "nested bold-italic CJK must keep the sheared overlay")
    }

    @Test func cjkBaseFamilyShearsTheWholeItalicRun() throws {
        // A base family with NO italic face at all (reachable via the host
        // font picker): the trait can't bind, so the WHOLE run is sheared —
        // Latin included (browser behavior), same family throughout.
        try #require(NSFont(name: "PingFang SC", size: 16) != nil, "PingFang ships with macOS")
        let text = "plain *中文 latin* tail"
        let ns = text as NSString
        let attrs = MarkdownStyler.styleAttributes(
            text: text,
            fontName: "PingFang SC",
            fontSize: 16,
            caretLocation: -1,
            activeTokenIndices: [],
            configuration: .default
        )
        for probe in ["中文", "latin"] {
            let range = ns.range(of: probe)
            let last = attrs.last {
                NSIntersectionRange($0.range, range).length > 0 && $0.attributes[.font] is NSFont
            }?.attributes[.font] as? NSFont
            #expect(last.map(ItalicFallback.isSheared) == true,
                    "'\(probe)' must be sheared under a no-italic-face base family")
            #expect(last?.familyName == "PingFang SC",
                    "'\(probe)' must stay in the chosen family (uniform slant, no face swap)")
            #expect(last?.pointSize == 16)
        }
    }

    // MARK: - Table cells

    @Test func tableCellsGetTheSameShear() {
        let cell = MarkdownStyler.formattedCellString(
            "*中文* x",
            baseFont: NSFont.systemFont(ofSize: 16),
            header: false,
            theme: .default,
            codeBackgroundColor: .gray,
            latex: MarkdownEditorConfiguration.default.services.latex
        )
        var found = false
        cell.enumerateAttributes(in: NSRange(location: 0, length: cell.length)) { attrs, range, _ in
            if (cell.string as NSString).substring(with: range).contains("中"),
               isShearOverlay(attrs),
               (attrs[.font] as? NSFont)?.pointSize == 16 {
                found = true
            }
        }
        #expect(found, "table-cell CJK emphasis must get the sheared overlay at full size")
    }

    @Test func shearFontRunsPreservesNestedFaces() {
        // Whole-subtree shear must slant each run's OWN font, not blanket one.
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: "普通", attributes: [.font: NSFont.systemFont(ofSize: 16)]))
        out.append(NSAttributedString(string: "code", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)]))
        ItalicFallback.shearFontRuns(in: out, range: NSRange(location: 0, length: out.length))
        let first = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let mono = out.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        #expect(first.map(ItalicFallback.isSheared) == true)
        #expect(mono.map(ItalicFallback.isSheared) == true)
        #expect(mono?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true,
                "nested faces keep their identity, only gaining the slant")
        #expect(first?.pointSize == 16)
        #expect(mono?.pointSize == 16)
    }
}

// MARK: - Render regression (why every claim above must also hold in pixels)

@MainActor
@Suite("Italic shear rendering")
struct ItalicShearRenderTests {

    /// Renders CJK text with `font` in a REAL TextKit 2 view. Pixel-level,
    /// because two prior implementations passed attribute-level tests while
    /// rendering wrong: TextKit 2 ignores `.obliqueness` entirely, and
    /// descriptor re-matching produced Times Latin + invisible 1pt CJK.
    private func render(_ font: NSFont) -> NSBitmapImageRep? {
        _ = NSApplication.shared
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 220, height: 70))
        tv.string = "永永永永"
        tv.backgroundColor = .white
        tv.drawsBackground = true
        tv.textStorage?.setAttributes(
            [.font: font, .foregroundColor: NSColor.black],
            range: NSRange(location: 0, length: (tv.string as NSString).length)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 70),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = tv
        window.orderBack(nil)
        tv.textLayoutManager?.ensureLayout(for: tv.textLayoutManager!.documentRange)
        tv.layoutSubtreeIfNeeded()
        guard let rep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds) else { return nil }
        tv.cacheDisplay(in: tv.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }

    private func darkCount(_ rep: NSBitmapImageRep) -> Int {
        var dark = 0
        for x in stride(from: 0, to: 220, by: 2) {
            for y in stride(from: 0, to: 70, by: 2) {
                if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.5 { dark += 1 }
            }
        }
        return dark
    }

    private func diffCount(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        var diff = 0
        for x in stride(from: 0, to: 220, by: 2) {
            for y in stride(from: 0, to: 70, by: 2) {
                let p = a.colorAt(x: x, y: y)?.brightnessComponent ?? 1
                let q = b.colorAt(x: x, y: y)?.brightnessComponent ?? 1
                if abs(p - q) > 0.2 { diff += 1 }
            }
        }
        return diff
    }

    /// The invariant pair every synthetic-italic render must satisfy:
    /// glyphs PRESENT (dark mass preserved — catches blank/1pt/Times) and
    /// SLANTED (pixels moved vs the upright render).
    private func assertSlantedAndPresent(_ sheared: NSFont, against plainFont: NSFont) throws {
        let plain = try #require(render(plainFont))
        let plainDark = darkCount(plain)
        try #require(plainDark > 50, "render harness must paint text")

        let treated = try #require(render(sheared))
        let treatedDark = darkCount(treated)
        #expect(treatedDark > plainDark / 2 && treatedDark < plainDark * 2,
                "glyphs must remain PRESENT (dark \(treatedDark) vs plain \(plainDark)) — blank/1pt/Times all fail this")
        #expect(diffCount(plain, treated) > 20,
                "glyphs must be visibly SLANTED vs the upright render")
    }

    @Test func cascadeOverlayFontRendersPresentAndSlanted() throws {
        // The per-subrange path (Latin base): pinned + sheared cascade font.
        let base = NSFont.systemFont(ofSize: 32)
        let italic = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.italic), size: 32) ?? base
        let ns = "永永永永" as NSString
        let overlay = ItalicFallback.cascadeOverlay(
            for: NSRange(location: 0, length: ns.length), in: ns, base: italic
        )
        let font = try #require(overlay[.font] as? NSFont)
        try assertSlantedAndPresent(font, against: base)
    }

    @Test func shearedCJKBaseFamilyRendersPresentAndSlanted() throws {
        // The whole-run path (CJK base family from the font picker).
        let pingfang = try #require(NSFont(name: "PingFang SC", size: 32))
        try assertSlantedAndPresent(ItalicFallback.shearedFont(from: pingfang), against: pingfang)
    }
}
