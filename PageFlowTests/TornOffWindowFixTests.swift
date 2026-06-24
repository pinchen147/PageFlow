//
//  TornOffWindowFixTests.swift
//  PageFlowTests
//
//  Guards the tear-off / ⌘N "no traffic lights" fix and the torn-off-window
//  sizing/positioning policy.
//
//  Root cause was z-order: hosting SwiftUI via `NSWindow(contentViewController:)`
//  left the hosting view ABOVE the titlebar container, so opaque content painted
//  over the native traffic-light buttons. The fix hosts the SwiftUI view as the
//  window's content view (`NSHostingView`), which keeps it behind the titlebar
//  AND bridges scene/focus state to the window. These tests pin that structural
//  invariant (host-safe — the window is never ordered front, which would
//  self-terminate the test host) plus the pure sizing and on-screen-fit helpers.
//

import AppKit
import SwiftUI
import Testing
@testable import PageFlow

@MainActor
struct CreateNewWindowHostingTests {
    /// Walks up from `view` until the next step would leave `themeFrame`, so the
    /// titlebar container is found by structure, not a hard-coded superview depth.
    private func directChild(of themeFrame: NSView, containing view: NSView) -> NSView? {
        var node: NSView? = view
        while let current = node, current.superview !== themeFrame { node = current.superview }
        return node
    }

    @Test
    func hostsContentBehindTitlebarSoTrafficLightsComposite() {
        let window = AppDelegate.makeHostedWindow(
            contentView: Color.clear,
            contentSize: NSSize(width: 400, height: 300)
        )
        defer { window.close() }

        // The SwiftUI view IS the window's content view (WWDC23 form) — which is
        // what bridges scene/focus state (e.g. the ⌘T/⌘W menu commands' focused
        // values) to a manually-created NSWindow.
        #expect(window.contentView.map { String(describing: type(of: $0)).contains("NSHostingView") } == true)

        // The titlebar container (which owns the traffic-light buttons) must be
        // z-ordered ABOVE the content view in the theme frame.
        guard let content = window.contentView,
              let themeFrame = content.superview,
              let closeButton = window.standardWindowButton(.closeButton),
              let titlebarContainer = directChild(of: themeFrame, containing: closeButton),
              let contentIndex = themeFrame.subviews.firstIndex(of: content),
              let titlebarIndex = themeFrame.subviews.firstIndex(of: titlebarContainer) else {
            Issue.record("expected a theme frame containing the content view and titlebar container")
            return
        }
        #expect(titlebarIndex > contentIndex)

        // The window controller owns the lifetime, so the window must not also
        // release itself on close.
        #expect(window.isReleasedWhenClosed == false)
    }
}

@MainActor
struct TornOffWindowSizeTests {
    private let visible = NSSize(width: 1728, height: 1084)

    @Test
    func nearlyMaximizedSourceFallsBackToDefaultSize() {
        let size = TabDragController.tornOffWindowSize(visible, visibleFrame: visible)
        #expect(size == NSSize(width: DesignTokens.defaultWindowWidth, height: DesignTokens.defaultWindowHeight))
    }

    @Test
    func normalSourceIsInheritedUnchanged() {
        let source = NSSize(width: 1000, height: 700)
        #expect(TabDragController.tornOffWindowSize(source, visibleFrame: visible) == source)
    }

    @Test
    func wideButNotMaximizedSourceIsInheritedUnchanged() {
        // 1700 ≥ 0.92·1728 (≈1589) but 700 < 0.92·1084 (≈997) → not "maximized",
        // and 1700 ≤ 1728 → fits, so the source size passes through untouched
        // (no arbitrary margin haircut).
        let size = TabDragController.tornOffWindowSize(NSSize(width: 1700, height: 700), visibleFrame: visible)
        #expect(size == NSSize(width: 1700, height: 700))
    }

    @Test
    func oversizedNonMaximizedSourceIsClampedToVisible() {
        // Wider than the screen but short (not maximized) → width clamps to the
        // visible frame, height passes through.
        let size = TabDragController.tornOffWindowSize(NSSize(width: 2000, height: 700), visibleFrame: visible)
        #expect(size.width == visible.width)
        #expect(size.height == 700)
    }

    @Test
    func noResolvableScreenInheritsSource() {
        let source = NSSize(width: 1200, height: 800)
        #expect(TabDragController.tornOffWindowSize(source, visibleFrame: nil) == source)
    }
}

@MainActor
struct OnScreenFrameTests {
    private let visible = NSRect(x: 0, y: 0, width: 1280, height: 800)

    @Test
    func fullyOnScreenFrameIsUnchanged() {
        let frame = NSRect(x: 100, y: 100, width: 900, height: 600)
        #expect(NSScreen.onScreenFrame(frame, in: visible) == frame)
    }

    @Test
    func offEdgeFrameIsClampedNotResized() {
        // Hanging off the right + top; fits by size, so only the origin moves.
        let frame = NSRect(x: 1000, y: 500, width: 600, height: 400)
        let fitted = NSScreen.onScreenFrame(frame, in: visible)
        #expect(fitted.size == frame.size)
        #expect(fitted.maxX <= visible.maxX)
        #expect(fitted.maxY <= visible.maxY)
        #expect(fitted.minX >= visible.minX && fitted.minY >= visible.minY)
    }

    @Test
    func tooLargeFrameIsShrunkToFit() {
        // Dropped on a screen smaller than it was sized for (the cross-display
        // crash case): must shrink, never hang the titlebar off-screen.
        let frame = NSRect(x: -50, y: -50, width: 1500, height: 950)
        let fitted = NSScreen.onScreenFrame(frame, in: visible)
        #expect(fitted.width == visible.width)
        #expect(fitted.height == visible.height)
        #expect(fitted.origin == visible.origin)
    }

    @Test
    func respectsNonZeroVisibleOrigin() {
        // visibleFrame excludes the menu bar / Dock, so its origin isn't (0,0).
        let shifted = NSRect(x: 200, y: 25, width: 1280, height: 779)
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let fitted = NSScreen.onScreenFrame(frame, in: shifted)
        #expect(fitted.minX >= shifted.minX && fitted.minY >= shifted.minY)
        #expect(fitted.maxX <= shifted.maxX && fitted.maxY <= shifted.maxY)
    }
}
