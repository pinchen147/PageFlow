import AppKit
import Testing
@testable import PageFlow

@MainActor
@Suite("Click cursors", .serialized)
struct ClickCursorTests {
    @Test("native chrome uses a hand over tab actions and an arrow over empty drag space")
    func nativeChromeCursor() throws {
        let manager = TabManager()
        let previous = NSCursor.current
        defer { previous.set() }
        let chevron = TabSwitcherChevronView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        chevron.tabManager = manager
        let bar = TabBarMouseNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        let id = try #require(manager.tabs.first?.id)
        bar.apply(tabManager: manager, tabFrames: [id: CGRect(x: 10, y: 0, width: 90, height: 30)],
                  newTabButtonFrame: CGRect(x: 110, y: 0, width: 24, height: 24),
                  hoveredTabID: nil, activeTabID: id, onHover: { _ in }, onClick: { _ in })
        for (view, point, expected) in [(chevron as NSView, NSPoint(x: 12, y: 12), NSCursor.pointingHand),
            (bar, NSPoint(x: 30, y: 12), .pointingHand),
            (bar, NSPoint(x: 120, y: 12), .pointingHand),
            (bar, NSPoint(x: 180, y: 12), .arrow)] {
            let event = try #require(NSEvent.enterExitEvent(with: .cursorUpdate, location: point,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, trackingNumber: 0, userData: nil))
            NSCursor.arrow.set()
            view.cursorUpdate(with: event)
            #expect(NSCursor.current == expected)
        }
    }
}
