import AppKit

/// Non-destructive crop overlay: the document retains its layout until Apply.
final class ImageCropView: NSView {
    var onApply: ((CGRect) -> Void)?
    var onClose: ((Bool) -> Void)?
    private let image: NSImage
    private let pixels: CGSize
    private let initialCrop: CGRect
    private let imageRect: () -> NSRect?
    private(set) var crop: CGRect
    private(set) var fullRect = NSRect.zero
    private var entered = ProcessInfo.processInfo.systemUptime
    private var focusedApply = true
    private var closed = false
    private let apply = SelectionBarButton(content: .symbol("checkmark"), tooltip: "Apply crop", hasCaret: false, opensOnMouseDown: false)
    private let cancel = SelectionBarButton(content: .symbol("xmark"), tooltip: "Cancel crop", hasCaret: false, opensOnMouseDown: false)
    private var pill = NSRect.zero
    private var readout = NSRect.zero

    init(image: NSImage, pixels: CGSize, crop: CGRect?, imageRect: @escaping () -> NSRect?) {
        self.image = image; self.pixels = pixels; self.crop = crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        initialCrop = self.crop; self.imageRect = imageRect
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Crop image")
        addSubview(apply); addSubview(cancel)
        apply.onPress = { [weak self] _ in self?.close(applied: true) }
        cancel.onPress = { [weak self] _ in self?.close(applied: false) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func present(in host: NSView) {
        frame = host.bounds; autoresizingMask = [.width, .height]
        host.addSubview(self, positioned: .above, relativeTo: nil)
        host.window?.makeFirstResponder(self); reposition()
    }

    func reposition() {
        guard let host = superview, let image = imageRect() else { return close(applied: false) }
        var rect = convert(image, from: host)
        let fullSize = CGSize(width: rect.width / initialCrop.width, height: rect.height / initialCrop.height)
        rect = NSRect(x: rect.minX - initialCrop.minX * fullSize.width, y: rect.minY - initialCrop.minY * fullSize.height,
                      width: fullSize.width, height: fullSize.height)
        let available = bounds.insetBy(dx: 16, dy: 16)
        if rect.width > available.width || rect.height > available.height {
            let scale = min(available.width / rect.width, available.height / rect.height)
            rect.size = CGSize(width: rect.width * scale, height: rect.height * scale)
            rect.origin = CGPoint(x: available.midX - rect.width / 2, y: available.midY - rect.height / 2)
        }
        rect.origin.x = min(max(rect.minX, available.minX), available.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, available.minY), available.maxY - rect.height)
        fullRect = rect; layoutControls(); needsDisplay = true
    }

    var cropRect: NSRect {
        NSRect(x: fullRect.minX + crop.minX * fullRect.width, y: fullRect.minY + crop.minY * fullRect.height,
               width: crop.width * fullRect.width, height: crop.height * fullRect.height)
    }

    var pixelReadout: String { "\(Int((pixels.width * crop.width).rounded())) × \(Int((pixels.height * crop.height).rounded()))" }

    private func layoutControls() {
        let rect = cropRect
        let y = min(max(rect.maxY + 8, 8), bounds.height - 40)
        pill = NSRect(x: min(max(rect.maxX - 60, 8), bounds.width - 68), y: y, width: 60, height: 32)
        apply.frame = NSRect(x: pill.minX + 3, y: pill.minY + 4, width: 24, height: 24)
        cancel.frame = NSRect(x: pill.minX + 31, y: pill.minY + 4, width: 24, height: 24)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let width = (pixelReadout as NSString).size(withAttributes: [.font: font]).width + 12
        readout = NSRect(x: min(max(rect.midX - width / 2, 8), bounds.width - width - 8), y: min(max(rect.maxY + 8, 8), bounds.height - 26), width: width, height: 18)
        if readout.intersects(pill.insetBy(dx: -8, dy: 0)) {
            readout.origin.x = max(8, pill.minX - width - 8)
            if readout.intersects(pill) { readout.origin.y = max(8, pill.minY - 26) }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: fullRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let rect = cropRect
        let dim = NSBezierPath(rect: bounds); dim.append(NSBezierPath(rect: rect)); dim.windingRule = .evenOdd
        NSColor(calibratedRed: 15 / 255, green: 15 / 255, blue: 15 / 255, alpha: 0.45).setFill(); dim.fill()
        NSColor.labelColor.setStroke(); NSColor.labelColor.setFill()
        let outline = NSBezierPath(rect: rect); outline.lineWidth = 1
        outline.setLineDash([2, 2], count: 2, phase: 0); outline.stroke()
        // Four outside brackets keep every retained pixel visible.
        for (x, y, sx, sy) in [(rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1.0, 1.0),
                               (rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0)] {
            NSRect(x: sx > 0 ? x - 4 : x - 12, y: sy > 0 ? y - 4 : y, width: 16, height: 4).fill()
            NSRect(x: sx > 0 ? x - 4 : x, y: sy > 0 ? y : y - 12, width: 4, height: 12).fill()
        }
        if rect.width >= 48 {
            NSRect(x: rect.midX - 6, y: rect.minY - 4, width: 12, height: 4).fill()
            NSRect(x: rect.midX - 6, y: rect.maxY, width: 12, height: 4).fill()
        }
        if rect.height >= 48 {
            NSRect(x: rect.minX - 4, y: rect.midY - 6, width: 4, height: 12).fill()
            NSRect(x: rect.maxX, y: rect.midY - 6, width: 4, height: 12).fill()
        }
        NSBezierPath(roundedRect: readout, xRadius: 4, yRadius: 4).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                       .foregroundColor: NSColor.textBackgroundColor]
        (pixelReadout as NSString).draw(at: CGPoint(x: readout.minX + 6, y: readout.minY + 2), withAttributes: attributes)
        let surface = NSBezierPath(roundedRect: pill, xRadius: 12, yRadius: 12)
        ChromePalette.surface.setFill(); surface.fill(); ChromePalette.border.setStroke(); surface.lineWidth = 1; surface.stroke()
    }

    private func handle(at p: NSPoint) -> ImageCropGeometry.Handle? {
        let r = cropRect
        let corners: [(ImageCropGeometry.Handle, NSPoint)] = [(.topLeft, CGPoint(x: r.minX, y: r.minY)), (.topRight, CGPoint(x: r.maxX, y: r.minY)),
             (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.bottomRight, CGPoint(x: r.maxX, y: r.maxY))]
        if let hit = corners.first(where: { NSRect(x: $0.1.x - 12, y: $0.1.y - 12, width: 24, height: 24).contains(p) }) { return hit.0 }
        if p.x >= r.minX && p.x <= r.maxX {
            if abs(p.y - r.minY) <= 9 { return .top }
            if abs(p.y - r.maxY) <= 9 { return .bottom }
        }
        if p.y >= r.minY && p.y <= r.maxY {
            if abs(p.x - r.minX) <= 9 { return .left }
            if abs(p.x - r.maxX) <= 9 { return .right }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let handle = handle(at: point), let window else {
            if !cropRect.contains(point), !pill.contains(point), ProcessInfo.processInfo.systemUptime - entered >= 0.5 { close(applied: false) }
            return
        }
        let start = crop
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) {
            if next.type == .leftMouseUp { break }
            if next.type == .keyDown { if next.keyCode == 53 { close(applied: false); return }; continue }
#if DEBUG
            let updateStart = CFAbsoluteTimeGetCurrent()
            defer { PerfTrace.add("image.crop.update", since: updateStart) }
#endif
            let current = convert(next.locationInWindow, from: nil)
            crop = ImageCropGeometry.drag(start, handle: handle,
                delta: CGPoint(x: (current.x - point.x) / fullRect.width, y: (current.y - point.y) / fullRect.height))
            layoutControls(); needsDisplay = true; window.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        let r = cropRect
        addCursorRect(NSRect(x: r.minX - 9, y: r.minY, width: 18, height: r.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: r.maxX - 9, y: r.minY, width: 18, height: r.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: r.minX, y: r.minY - 9, width: r.width, height: 18), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: r.minX, y: r.maxY - 9, width: r.width, height: 18), cursor: .resizeUpDown)
        if #available(macOS 15.0, *) {
            addCursorRect(NSRect(x: r.minX - 12, y: r.minY - 12, width: 24, height: 24), cursor: .frameResize(position: .topLeft, directions: .all))
            addCursorRect(NSRect(x: r.maxX - 12, y: r.minY - 12, width: 24, height: 24), cursor: .frameResize(position: .topRight, directions: .all))
            addCursorRect(NSRect(x: r.minX - 12, y: r.maxY - 12, width: 24, height: 24), cursor: .frameResize(position: .bottomLeft, directions: .all))
            addCursorRect(NSRect(x: r.maxX - 12, y: r.maxY - 12, width: 24, height: 24), cursor: .frameResize(position: .bottomRight, directions: .all))
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: close(applied: true)
        case 53: close(applied: false)
        case 48:
            focusedApply.toggle(); apply.hasKeyboardFocus = focusedApply; cancel.hasKeyboardFocus = !focusedApply
        case 49: close(applied: focusedApply)
        default: break
        }
    }

    func close(applied: Bool) {
        guard !closed else { return }; closed = true
        let window = window
        let main = (superview as? NSScrollView)?.nativeTextView
        removeFromSuperview()
        if let main { window?.makeFirstResponder(main) }
        if applied { onApply?(crop) }
        onClose?(applied)
    }
}
