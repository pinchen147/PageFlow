import CoreGraphics

/// the reference editor's selection bar placement (`Zdt` / `Nj`, doc 24 §6.2), in
/// points, in a top-down space whose origin is the editor's top-left.
enum MarkdownSelectionBarPlacement {
    static let gap: CGFloat = 10
    static let margin: CGFloat = 8

    /// The bar's top edge: 10 above the anchor; else 10 below it; else pinned
    /// to the top margin, moved below the head caret when the caret is under it.
    /// `below` picks the pop that drops instead of rises.
    static func top(anchor r: CGRect, barHeight h: CGFloat, top: CGFloat, bottom: CGFloat,
                    caret: CGRect?) -> (y: CGFloat, below: Bool) {
        if r.minY - gap - h >= top { return (r.minY - gap - h, false) }
        if r.maxY + gap + h <= bottom - margin { return (r.maxY + gap, true) }
        if let c = caret, c.maxY > top, c.minY < top + h { return (c.maxY + gap, false) }
        return (top, false)
    }

    /// The bar's centre x: the anchor's centre, kept 8 from both sides.
    static func centerX(_ cx: CGFloat, width w: CGFloat, left: CGFloat, right: CGFloat) -> CGFloat {
        max(min(cx, right - w / 2 - margin), left + w / 2 + margin)
    }
}
