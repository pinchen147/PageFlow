import AppKit

/// The mouse side of image object selection (doc 26 §3.2, §10.8): a press on a
/// rendered image selects it before NSTextView can place a caret in its hidden
/// source, and the pointer over an image is an arrow, not an I-beam.
extension NativeTextView {

    /// The rect the image anchored at `anchor` draws in, in view coordinates;
    /// nil unless its fragment is laid out (nothing is laid out to find it).
    func renderedImageRect(at anchor: Int) -> NSRect? {
        guard (delegate as? NativeTextViewCoordinator)?.foldLayout.hiddenRange(containing: anchor) == nil else { return nil }
        guard let storage = textStorage, anchor >= 0, anchor < storage.length,
              storage.attribute(.renderedBlockImage, at: anchor, effectiveRange: nil) != nil,
              let layout = textLayoutManager, let content = layout.textContentManager,
              let location = content.location(layout.documentRange.location, offsetBy: anchor),
              let fragment = layout.textLayoutFragment(for: location) as? MarkdownTextLayoutFragment,
              fragment.state == .layoutAvailable,
              let frame = fragment.blockImageFrame(at: anchor) else { return nil }
        return frame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// The rendered image under `point` (view coordinates) in the laid-out viewport.
    func renderedImage(at point: NSPoint) -> (image: ObjectSelection, rect: NSRect)? {
#if DEBUG
        let hoverStart = CFAbsoluteTimeGetCurrent()
        defer { PerfTrace.add("hover.imageLookup", since: hoverStart) }
#endif
        guard let storage = textStorage, let viewport = viewportCharacterRange else { return nil }
        let scope = NSIntersectionRange(viewport, NSRange(location: 0, length: storage.length))
        var hit: (ObjectSelection, NSRect)?
        storage.enumerateAttribute(.markdownBlockSourceRange, in: scope) { value, range, stop in
            guard let value = value as? NSValue,
                  storage.attribute(.markdownBlockKind, at: range.location, effectiveRange: nil) as? String
                      == MarkdownBlockKind.image.rawValue,
                  let rect = renderedImageRect(at: range.location), rect.contains(point) else { return }
            hit = (ObjectSelection(token: AnchorRelativeRange.decode(value, anchorLocation: range.location),
                                   anchor: range.location), rect)
            stop.pointee = true
        }
        return hit
    }

    /// Repaint the image anchored at `anchor`: its fragment hides the selection
    /// band under an object-selected image, and TextKit does not redraw a
    /// fragment for a selection change.
    func redisplayRenderedImage(at anchor: Int) {
        guard let rect = renderedImageRect(at: anchor), rect.intersects(visibleRect) else { return }
        // TextKit draws each layout fragment in its own view under this one.
        func mark(_ view: NSView) {
            for child in view.subviews where convert(child.bounds, from: child).intersects(rect) {
                child.needsDisplay = true
                mark(child)
            }
        }
        mark(self)
    }

    /// A primary press on a rendered image selects it at once (no caret ever
    /// lands); the press is then tracked to mouse-up so no text selection
    /// sweeps. A drag past the slop is the image's body drag, which belongs to
    /// the block move (owner decision O15, doc 26 Phase 8). Double- and
    /// triple-clicks act as a click. Shift-clicks extend the text selection.
    /// Event acquisition and native drag presentation are independent boundaries: replaying
    /// a press sequence can record its drag intent without starting an OS tracking session.
    func routeMouseDownToBlocks(
        _ event: NSEvent,
        dragPresenter: ((ObjectSelection, NSEvent, NSPoint) -> Void)? = nil,
        nextEvent: (() -> NSEvent?)? = nil
    ) -> Bool {
        if event.type == .leftMouseDown, let coordinator = delegate as? NativeTextViewCoordinator,
           coordinator.imageControls?.routeResizeMouseDown(event, nextEvent: nextEvent) == true { return true }
        guard isEditable, event.type == .leftMouseDown, !event.modifierFlags.contains(.shift),
              let coordinator = delegate as? NativeTextViewCoordinator, let window,
              let hit = renderedImage(at: convert(event.locationInWindow, from: nil)) else { return false }
        if window.firstResponder !== self { window.makeFirstResponder(self) }
        coordinator.selectImage(hit.image, in: self)
        coordinator.selectionBar?.imageClicked()
        let start = event.locationInWindow
        let events = nextEvent ?? { window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) }
        var dragging = false
        while let next = events() {
            if next.type == .leftMouseUp { break }
            if !dragging, hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > Self.imageDragSlop {
                dragging = true
                if let dragPresenter { dragPresenter(hit.image, next, start) }
                else { imageBodyDragDidBegin(hit.image, with: next, pressPoint: start) }
                return true // The native dragging session now owns drag and mouse-up events.
            }
        }
        return true
    }

    /// How far a press on an image moves before it is a drag (the browser's slop, doc 26 §10.2).
    static let imageDragSlop: CGFloat = 4

    /// A drag that started on an image's body enters the same native mover as its grip.
    func imageBodyDragDidBegin(_ image: ObjectSelection, with event: NSEvent, pressPoint: NSPoint? = nil) {
        (delegate as? NativeTextViewCoordinator)?.blockMover.begin(range: image.token, kind: .image, event: event, rect: renderedImageRect(at: image.anchor), pressPoint: pressPoint)
    }

    /// Edit mode: the pointer over a rendered image is an arrow (doc 26 §3.5).
    /// True when it set the cursor.
    @discardableResult
    func applyImageCursor(for event: NSEvent) -> Bool {
#if DEBUG
        let hoverStart = CFAbsoluteTimeGetCurrent()
        defer { PerfTrace.add("hover.cursorRoute", since: hoverStart) }
#endif
        if let coordinator = delegate as? NativeTextViewCoordinator,
           coordinator.imageControls?.applyCursor(at: convert(event.locationInWindow, from: nil)) == true { return true }
        guard isEditable, renderedImage(at: convert(event.locationInWindow, from: nil)) != nil else { return false }
        NSCursor.arrow.set()
        return true
    }
}
