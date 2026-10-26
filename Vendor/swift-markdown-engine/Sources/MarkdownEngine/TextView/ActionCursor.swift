import AppKit

extension NSView {
    /// Keep hover tracking independent: activeAlways hover areas do not deliver
    /// cursorUpdate. The window restores the surrounding cursor on exit.
    @discardableResult
    func trackActionCursor() -> NSTrackingArea {
        let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        return area
    }
}

/// Native buttons in editor popovers retain their standard appearance and actions.
final class ActionButton: NSButton {
    private var cursorTracking: NSTrackingArea?
    override var isEnabled: Bool { didSet { window?.invalidateCursorRects(for: self) } }
    override func resetCursorRects() { addCursorRect(bounds, cursor: isEnabled ? .pointingHand : .arrow) }
    override func cursorUpdate(with event: NSEvent) { (isEnabled ? NSCursor.pointingHand : .arrow).set() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking, trackingAreas.contains(cursorTracking) { removeTrackingArea(cursorTracking) }
        cursorTracking = trackActionCursor()
    }
}
