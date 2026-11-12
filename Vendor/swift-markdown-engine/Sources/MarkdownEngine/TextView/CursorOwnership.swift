import AppKit

extension NSView {
    /// Only visible native surfaces in the event's window may arbitrate its cursor.
    func frontmostCursorHit(for event: NSEvent) -> NSView? {
        guard let window, window.isVisible, event.windowNumber == window.windowNumber,
              !isHiddenOrHasHiddenAncestor,
              visibleRect.contains(convert(event.locationInWindow, from: nil)),
              let root = window.contentView else { return nil }
        let point = root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        return root.hitTest(point)
    }

    /// TextKit may hit a text-owned descendant that forwards to its text view.
    /// Stop at a separate control, scroll surface or cursor-tracking owner.
    func ownsTextCursorHit(_ hit: NSView) -> Bool {
        var candidate: NSView? = hit
        while let view = candidate {
            if view === self { return true }
            if view is NSControl || view is NSScrollView || view is NSTextView
                || view.trackingAreas.contains(where: { $0.options.contains(.cursorUpdate) }) {
                return false
            }
            candidate = view.superview
        }
        return false
    }
}
