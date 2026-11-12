//
//  LatexTypeset.swift
//  MarkdownEngineLatex
//
//  A formula typeset once and drawn as vectors at any size and colour,
//  for hosts that lay formulas out themselves (the EPUB reader).
//

import AppKit
import SwiftMath

/// A formula typeset by SwiftMath, with the same compatibility rewrite and
/// repairs as ``SwiftMathBridge``. Drawing needs no view and is safe off the
/// main thread; typesetting is not (SwiftMath lays out through a view).
public final class LatexTypeset: @unchecked Sendable {
    public let width: CGFloat
    /// Ascent plus descent, at least half the font size.
    public let height: CGFloat
    /// How far the formula reaches below its baseline.
    public let descent: CGFloat
    private let display: MTMathListDisplay

    private init(display: MTMathListDisplay, width: CGFloat, height: CGFloat, descent: CGFloat) {
        self.display = display
        self.width = width
        self.height = height
        self.descent = descent
    }

    /// Typesets `latex` at `fontSize`, in display style (a block formula)
    /// or text style (inline). Nil when SwiftMath can't read it.
    @MainActor
    public static func make(_ latex: String, fontSize: CGFloat, displayStyle: Bool) -> LatexTypeset? {
        // A formula missing a symbol reads wrong: the caller shows its text instead.
        guard !LatexCompatibility.dropsSymbols(in: latex) else { return nil }
        let source = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        let native = LatexNativeText.split(source)
        guard !source.isEmpty, !native.requiresSourceFallback, native.annotations.isEmpty,
              let list = SwiftMathBridge.parse(native.latex) else { return nil }
        SwiftMathBridge.normalizeBinaryOperators(in: list)
        let label = MTMathUILabel()
        label.mathList = list
        label.fontSize = fontSize
        if let font = mathFont(size: fontSize) { label.font = font }
        label.textColor = .black
        label.textAlignment = .left
        label.labelMode = displayStyle ? .display : .text
        label.layoutSubtreeIfNeeded()
        guard let measured = label.displayList, measured.width > 0, measured.ascent + measured.descent > 0 else {
            return nil
        }
        // A frame this tall puts the baseline exactly `descent` above its bottom.
        let height = max(measured.ascent + measured.descent, fontSize / 2)
        label.frame = CGRect(x: 0, y: 0, width: ceil(measured.width), height: height)
        label.needsLayout = true
        label.layoutSubtreeIfNeeded()
        guard let display = label.displayList else { return nil }
        return LatexTypeset(display: display, width: display.width, height: height, descent: display.descent)
    }

    @MainActor private static var fonts: [CGFloat: MTFont] = [:]

    /// Latin Modern Math, loaded once per size.
    @MainActor private static func mathFont(size: CGFloat) -> MTFont? {
        if let font = fonts[size] { return font }
        let font = MTFontManager().font(withName: "latinmodern-math", size: size)
        fonts[size] = font
        return font
    }

    /// Draws with the formula's bottom-left corner at the context's origin,
    /// y up, in `color`: the ink is drawn, then filled with the colour. Paper
    /// has no source-in blend (the fill would cover the layer), so printing
    /// and PDF draw the ink as typeset, in black.
    public func draw(in context: CGContext, color: CGColor) {
        let slack = height
        // A flipped view leaves a flipped text matrix, which isn't part of
        // the graphics state: glyphs would draw upside down.
        let textMatrix = context.textMatrix
        context.textMatrix = .identity
        defer { context.textMatrix = textMatrix }
        if NSGraphicsContext.current?.isDrawingToScreen == false {
            display.draw(context)
            return
        }
        context.saveGState()
        let bounds = CGRect(x: -slack, y: -slack, width: width + slack * 2, height: height + slack * 2)
        context.beginTransparencyLayer(in: bounds, auxiliaryInfo: nil)
        display.draw(context)
        context.setBlendMode(.sourceIn)
        context.setFillColor(color)
        context.fill(bounds)
        context.endTransparencyLayer()
        context.restoreGState()
    }
}
