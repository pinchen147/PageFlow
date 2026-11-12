import AppKit

@MainActor
final class NativeSemanticImageControls {
    weak var owner: NativeSemanticDocumentCoordinator?
    let bars = ImageResizeBars(frame: .zero)
    let ring = ImageChromeView(frame: .zero)
    let accessibility = ImageResizeAccessibilityView(frame: .zero)
    private var hoveredIndex: Int?
    private var resizing = false

    init(owner: NativeSemanticDocumentCoordinator) {
        self.owner = owner
        for view in [bars, ring, accessibility] { view.isHidden = true; owner.textView.addSubview(view) }
        accessibility.onAdjust = { [weak self] delta in
            guard let self, let owner = self.owner, let hit = self.target(at: owner.textView.selectedRange().location) else { return false }
            return self.commitWidth(hit.rect.width + delta, at: hit.index, expectedRevision: owner.revision)
        }
    }

    func uninstall() { bars.removeFromSuperview(); ring.removeFromSuperview(); accessibility.removeFromSuperview() }

    func hover(at point: NSPoint?) {
        guard let owner, !resizing else { return }
        if let point {
            let index = owner.textView.characterIndexForInsertion(at: point)
            hoveredIndex = [index, index - 1].compactMap { target(at: $0) }
                .first { $0.rect.insetBy(dx: -12, dy: -4).contains(point) }?.index
        } else { hoveredIndex = nil }
        refresh()
    }

    func refresh() {
        guard !resizing, let owner, owner.textView.isEditable, !owner.hasActiveComposition else { return }
        let selection = owner.textView.selectedRange()
        let selected = selection.length == 1 ? target(at: selection.location) : nil
        let shown = selected ?? hoveredIndex.flatMap { target(at: $0) }
        guard let shown else { bars.isHidden = true; ring.isHidden = true; accessibility.isHidden = true; return }
        bars.frame = shown.rect.insetBy(dx: -12, dy: 0)
        bars.imageRect = NSRect(x: 12, y: 0, width: shown.rect.width, height: shown.rect.height)
        bars.isHidden = false
        bars.needsDisplay = true
        ring.frame = ImageChromeView.ringFrame(around: shown.rect)
        ring.isHidden = selected == nil
        accessibility.frame = shown.rect
        accessibility.isHidden = selected == nil
        if let window = owner.textView.window {
            accessibility.update(width: shown.rect.width, screenRect: window.convertToScreen(owner.textView.convert(shown.rect, to: nil)))
        }
    }

    private func target(at index: Int) -> (index: Int, rect: NSRect, alignment: ImageAltTokens.Alignment)? {
        guard let owner, let storage = owner.textView.textStorage, index >= 0, index < storage.length,
              case .image(_, let alt, _)? = storage.attribute(NativeSemanticAttributes.object, at: index, effectiveRange: nil) as? SemanticInlineObject,
              let window = owner.textView.window else { return nil }
        let screen = owner.textView.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
        let rect = owner.textView.convert(window.convertFromScreen(screen), from: nil)
        guard rect.width > 0, rect.height > 0 else { return nil }
        return (index, rect, ImageAltTokens.parse(alt).alignment)
    }

    @discardableResult
    func commitWidth(_ width: CGFloat, at index: Int, expectedRevision: UInt64) -> Bool {
        guard let owner, owner.revision == expectedRevision, !owner.hasActiveComposition,
              width.isFinite, width >= 20 else { return false }
        owner.textView.setSelectedRange(NSRange(location: index, length: 1))
        return owner.editSelectedImage { $0.width = width.rounded() }
    }

    func mouseDown(_ event: NSEvent, nextEvent: (() -> NSEvent?)? = nil) -> Bool {
        guard let owner, owner.textView.isEditable, !owner.hasActiveComposition, !owner.isWritingToolsActive,
              let window = owner.textView.window, let storage = owner.textView.textStorage else { return false }
        let point = owner.textView.convert(event.locationInWindow, from: nil)
        let candidate = hoveredIndex ?? owner.textView.selectedRange().location
        guard let hit = target(at: candidate), hit.rect.insetBy(dx: -12, dy: 0).contains(point),
              min(abs(point.x - hit.rect.minX), abs(point.x - hit.rect.maxX)) <= 12,
              let original = storage.attribute(.attachment, at: hit.index, effectiveRange: nil) as? NSTextAttachment else { return false }
        let expected = owner.revision
        let left = abs(point.x - hit.rect.minX) < abs(point.x - hit.rect.maxX)
        let preview = NSTextAttachment()
        preview.image = original.image
        preview.bounds = original.bounds
        resizing = true; bars.dragging = true
        var width = hit.rect.width
        var cancelled = false
        let events = nextEvent ?? { window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) }
        while let next = events() {
            guard owner.revision == expected else { cancelled = true; break }
            if next.type == .keyDown { if next.keyCode == 53 { cancelled = true; break }; continue }
            if next.type == .leftMouseUp { break }
            let travel = owner.textView.convert(next.locationInWindow, from: nil).x - point.x
            width = ImageResizeGeometry.width(start: hit.rect.width, travel: travel, left: left,
                alignment: hit.alignment, column: owner.textView.textContainer?.size.width ?? 600)
            preview.bounds.size = NSSize(width: width, height: original.bounds.height * width / max(1, hit.rect.width))
            storage.addAttribute(.attachment, value: preview, range: NSRange(location: hit.index, length: 1))
            let rect = ImageResizeGeometry.previewRect(original: hit.rect, width: width, height: preview.bounds.height, alignment: hit.alignment)
            bars.frame = rect.insetBy(dx: -12, dy: 0)
            bars.imageRect = NSRect(x: 12, y: 0, width: rect.width, height: rect.height)
            bars.needsDisplay = true
        }
        if owner.revision == expected {
            storage.addAttribute(.attachment, value: original, range: NSRange(location: hit.index, length: 1))
            if !cancelled, width.rounded() != hit.rect.width.rounded() { _ = commitWidth(width, at: hit.index, expectedRevision: expected) }
        }
        resizing = false; bars.dragging = false; refresh()
        return true
    }
}
