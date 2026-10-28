import AppKit
import PDFKit

enum PDFUserZoomIntent {
    case manual
    case autoScaling(Bool)
}

extension StablePDFView {
    /// Resolve the actual event point and require the PDF subtree to own the hit.
    /// Overlays keep their scroll events, even inside the PDF's geometric bounds.
    func frontmostEventPoint(_ event: NSEvent) -> NSPoint? {
        guard !isHiddenOrHasHiddenAncestor, let window,
              event.window == nil || event.window === window,
              let content = window.contentView else { return nil }
        let windowPoint = event.window == nil
            ? window.convertPoint(fromScreen: NSEvent.mouseLocation)
            : event.locationInWindow
        let point = convert(windowPoint, from: nil)
        guard bounds.contains(point) else { return nil }
        // NSView.hitTest takes coordinates in the receiver's parent.
        let hitPoint = content.superview?.convert(windowPoint, from: nil) ?? windowPoint
        guard let hit = content.hitTest(hitPoint),
              hit === self || hit.isDescendant(of: self) else { return nil }
        return point
    }

    override func zoomIn(_ sender: Any?) {
        guard canZoomIn, acceptsUserZoom() else { return }
        super.zoomIn(sender)
    }

    override func zoomOut(_ sender: Any?) {
        guard canZoomOut, acceptsUserZoom() else { return }
        super.zoomOut(sender)
    }

    @objc func actualSize(_ sender: Any?) {
        guard acceptsUserZoom() else { return }
        scaleFactor = DesignTokens.pdfDefaultScale
    }

    @objc func automaticallyResize(_ sender: Any?) {
        _ = acceptsUserZoom(.autoScaling(true))
    }

    /// PDFKit's internal scroll view receives the gesture; the existing local
    /// monitor admits it before native delivery without replacing native sizing.
    func beginUserMagnification(with event: NSEvent) -> Bool {
        guard event.magnification.isFinite, event.magnification != 0,
              frontmostEventPoint(event) != nil else { return false }
        return acceptsUserZoom()
    }

    private func acceptsUserZoom(_ intent: PDFUserZoomIntent = .manual) -> Bool {
        guard document != nil, window != nil, !isHiddenOrHasHiddenAncestor,
              onUserZoom?(intent) == true else { return false }
        switch intent {
        case .manual: autoScales = false
        case .autoScaling(let enabled): autoScales = enabled
        }
        return true
    }
}
