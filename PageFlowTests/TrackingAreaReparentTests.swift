//
//  TrackingAreaReparentTests.swift
//  PageFlowTests
//
//  The tracking-area re-registration contract: AppKit calls
//  updateTrackingAreas when a view needs fresh tracking (window move,
//  scroll, resize) and expects the area to be RE-CREATED — an area kept
//  across a window re-parent stays registered with the old window and goes
//  inert (the tear-off "traffic lights gone" bug). Windows here are never
//  ordered front (test-host hazard).
//

import AppKit
import Testing
@testable import PageFlow

@MainActor
struct TrackingAreaReparentTests {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    /// A DIRECT window-to-window move, the way SwiftUI re-hosts platform
    /// views: one viewWillMove(toWindow: B) with no nil hop — so cleanup
    /// paths keyed on "leaving to nil" never fire. (Adding removeFromSuperview
    /// first would introduce that nil hop and mask the bug.) Deliberately no
    /// explicit updateTrackingAreas() call: AppKit does not reliably invoke
    /// it on re-parent, so re-arming must happen via viewDidMoveToWindow —
    /// that gap is exactly what this test pins.
    private func reparent(_ view: NSView, to b: NSWindow) {
        b.contentView?.addSubview(view)
    }

    @Test
    func chromeHoverSensorReRegistersItsAreaAcrossAWindowMove() {
        let windowA = makeWindow()
        let windowB = makeWindow()
        let sensor = ChromeHoverNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))

        windowA.contentView?.addSubview(sensor)
        sensor.updateTrackingAreas()
        let original = sensor.trackingAreas.first
        #expect(original != nil)

        reparent(sensor, to: windowB)

        #expect(sensor.trackingAreas.count == 1)
        #expect(sensor.trackingAreas.first !== original)
    }

    @Test
    func tabBarMouseViewReRegistersItsAreaAcrossAWindowMove() {
        let windowA = makeWindow()
        let windowB = makeWindow()
        let view = TabBarMouseNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))

        windowA.contentView?.addSubview(view)
        view.updateTrackingAreas()
        let original = view.trackingAreas.first
        #expect(original != nil)

        reparent(view, to: windowB)

        #expect(view.trackingAreas.count == 1)
        #expect(view.trackingAreas.first !== original)
    }
}
