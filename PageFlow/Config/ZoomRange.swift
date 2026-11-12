//
//  ZoomRange.swift
//  PageFlow
//
//  The one zoom rule every document type steps, gates and clamps by, so a
//  zoom press and its disabled state behave the same in PDF, Markdown and EPUB.
//

import CoreGraphics

nonisolated struct ZoomRange: Equatable, Sendable {
    let minimum: CGFloat
    let maximum: CGFloat

    /// PDF's 10–400%. EPUB pages zoom like PDF pages, so books share it.
    static let pages = ZoomRange(minimum: DesignTokens.pdfMinScale, maximum: DesignTokens.pdfMaxScale)
    /// Markdown's visual zoom, 50–400%.
    static let markdown = ZoomRange(minimum: DesignTokens.markdownMinZoom, maximum: DesignTokens.markdownMaxZoom)

    /// A scale this close to a limit is at it: absorbs the float drift of
    /// repeated ×1.25 steps, so a press always does something.
    static let limitTolerance: CGFloat = 0.001
    /// A scale this close to 100% is actual size: absorbs PDFKit's
    /// re-rounding of the scale.
    static let actualSizeTolerance: CGFloat = 0.005

    var bounds: ClosedRange<CGFloat> { minimum...maximum }

    func clamp(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minimum), maximum)
    }

    func canStepIn(from scale: CGFloat) -> Bool { scale < maximum - Self.limitTolerance }
    func canStepOut(from scale: CGFloat) -> Bool { scale > minimum + Self.limitTolerance }

    /// One multiplicative step, so each press changes the size by the same
    /// proportion at any scale.
    func steppedIn(from scale: CGFloat) -> CGFloat { clamp(scale * DesignTokens.zoomStepFactor) }
    func steppedOut(from scale: CGFloat) -> CGFloat { clamp(scale / DesignTokens.zoomStepFactor) }

    func isActualSize(_ scale: CGFloat) -> Bool { abs(scale - 1) <= Self.actualSizeTolerance }
}
