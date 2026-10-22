import CoreGraphics

enum ImageResizeGeometry {
    static func width(start: CGFloat, travel: CGFloat, left: Bool, alignment: ImageAltTokens.Alignment, column: CGFloat) -> CGFloat {
        let delta = travel * (left ? -1 : 1) * (alignment == .center ? 2 : 1)
        return min(max((start + delta).rounded(), 40), max(40, column))
    }
}

enum ImageCropGeometry {
    enum Handle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }

    static func drag(_ rect: CGRect, handle: Handle, delta: CGPoint) -> CGRect {
        var l = rect.minX, r = rect.maxX, t = rect.minY, b = rect.maxY
        func snap(_ value: CGFloat) -> CGFloat { value < 0.01 ? 0 : value > 0.99 ? 1 : value }
        if [.topLeft, .left, .bottomLeft].contains(handle) { l = min(max(snap(l + delta.x), 0), r - 0.02) }
        if [.topRight, .right, .bottomRight].contains(handle) { r = max(min(snap(r + delta.x), 1), l + 0.02) }
        if [.topLeft, .top, .topRight].contains(handle) { t = min(max(snap(t + delta.y), 0), b - 0.02) }
        if [.bottomLeft, .bottom, .bottomRight].contains(handle) { b = max(min(snap(b + delta.y), 1), t + 0.02) }
        return CGRect(x: l, y: t, width: r - l, height: b - t)
    }
}
