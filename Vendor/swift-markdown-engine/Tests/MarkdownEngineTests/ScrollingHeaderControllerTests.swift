//
//  ScrollingHeaderControllerTests.swift
//  MarkdownEngineTests
//
//  The scroll-away header: build, content refresh, collapse/expand reserved
//  height, and removal — detached and ordered-out native view hierarchies.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("ScrollingHeaderController")
struct ScrollingHeaderControllerTests {

    struct Stack {
        let scrollView: ClampedScrollView
        let container: NativeTextViewContainer
        let textView: NativeTextView
        let controller: ScrollingHeaderController
    }

    private func makeStack(viewport: NSSize = NSSize(width: 600, height: 800)) -> Stack {
        let scrollView = ClampedScrollView(frame: NSRect(origin: .zero, size: viewport))
        let textView = NativeTextView(frame: .zero)
        textView.configuration = .default
        textView.autoresizingMask = []
        let container = NativeTextViewContainer(frame: NSRect(origin: .zero, size: viewport))
        container.autoresizingMask = [.width]
        container.textView = textView
        textView.frame = NSRect(x: 0, y: 0, width: viewport.width, height: 0)
        container.addSubview(textView)
        scrollView.documentView = container
        return Stack(
            scrollView: scrollView, container: container, textView: textView,
            controller: ScrollingHeaderController()
        )
    }

    private func fixedHeightHeader(_ height: CGFloat) -> AnyView {
        AnyView(Color.clear.frame(width: 200, height: height))
    }

    /// Yield the main actor until `condition` holds (or ~2s passes), laying
    /// out the container each turn. Native animation and completion callbacks
    /// must run between passes, including when the test starts on the main queue.
    private func spinUntil(_ container: NativeTextViewContainer, _ condition: () -> Bool) async throws {
        let deadline = Date(timeIntervalSinceNow: 2.0)
        while !condition() && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
            container.layoutSubtreeIfNeeded()
        }
    }

    /// Animated settles go through the clip-frame observer, which carries a
    /// small deadband — compare with a matching tolerance, not exact equality.
    private func nearly(_ value: CGFloat, _ target: CGFloat) -> Bool {
        abs(value - target) <= 0.25
    }

    @Test func buildReservesCollapsedHeightWhenCollapsed() {
        let stack = makeStack()

        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 30, expanded: false,
            container: stack.container
        )
        stack.container.layoutSubtreeIfNeeded()

        #expect(stack.controller.clipView != nil)
        #expect(stack.controller.reservedHeight == 30)
        #expect(stack.container.headerHeight == 30)
        #expect(stack.textView.frame.origin.y == 30)
    }

    @Test func buildTracksContentHeightWhenExpanded() {
        let stack = makeStack()

        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 30, expanded: true,
            container: stack.container
        )
        stack.container.layoutSubtreeIfNeeded()

        #expect(stack.controller.reservedHeight == 120)
        #expect(stack.container.headerHeight == 120)
    }

    @Test func reconcileRefreshesHeaderContentWithinSameDocument() async throws {
        let stack = makeStack()
        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 30, expanded: true,
            container: stack.container
        )
        stack.container.layoutSubtreeIfNeeded()
        #expect(stack.container.headerHeight == 120)

        // Same document, new content (e.g. the user renamed the title): the
        // hosted rootView must refresh — the reserved band tracks the new
        // intrinsic height without any document switch.
        stack.controller.reconcile(
            header: fixedHeightHeader(90), collapsedHeight: 30, expanded: true,
            container: stack.container
        )
        try await spinUntil(stack.container) { nearly(stack.container.headerHeight, 90) }

        #expect(nearly(stack.container.headerHeight, 90))
    }

    @Test func collapsedSteadyTracksCollapsedHeightChanges() {
        let stack = makeStack()
        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 30, expanded: false,
            container: stack.container
        )
        stack.container.layoutSubtreeIfNeeded()

        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 44, expanded: false,
            container: stack.container
        )
        stack.container.layoutSubtreeIfNeeded()

        #expect(stack.controller.reservedHeight == 44)
        #expect(stack.container.headerHeight == 44)
    }

    @Test func expandAnimatesToContentHeightAndSettles() async throws {
        let stack = makeStack()
        stack.controller.animationDuration = 0.05
        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 30, expanded: false,
            container: stack.container
        )
        stack.container.layoutSubtreeIfNeeded()
        #expect(stack.container.headerHeight == 30)

        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 30, expanded: true,
            container: stack.container
        )
        try await spinUntil(stack.container) { nearly(stack.container.headerHeight, 120) }

        #expect(nearly(stack.container.headerHeight, 120))
        // After settling, the live-tracking equality constraint governs again.
        #expect(stack.controller.reservedHeight == 120)
    }

    @Test func collapseAnimatesBackToCollapsedHeight() async throws {
        let stack = makeStack()
        stack.controller.animationDuration = 0.05
        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 30, expanded: true,
            container: stack.container
        )
        stack.container.layoutSubtreeIfNeeded()

        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 30, expanded: false,
            container: stack.container
        )
        try await spinUntil(stack.container) { nearly(stack.container.headerHeight, 30) }

        #expect(nearly(stack.container.headerHeight, 30))
        #expect(stack.controller.reservedHeight == 30)
    }

    @Test(arguments: [false, true])
    func detachedHeaderSettlesSynchronously(expanded: Bool) throws {
        let stack = makeStack()
        try #require(stack.container.window == nil)
        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 30, expanded: !expanded,
            container: stack.container
        )
        stack.container.layoutSubtreeIfNeeded()
        try #require(stack.container.headerHeight == (expanded ? 30 : 120))

        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 30, expanded: expanded,
            container: stack.container
        )

        // Detached state must be final before returning, without an event-loop
        // pass or a display-driven animation completion.
        try expectSettledHeader(stack, expanded: expanded)
    }

    @Test(arguments: [false, true])
    func orderedOutWindowSettlesSynchronously(expanded: Bool) throws {
        _ = NSApplication.shared
        let stack = makeStack()
        let window = NSWindow(
            contentRect: stack.scrollView.frame,
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = stack.scrollView
        window.orderOut(nil)
        defer { window.close() }
        try #require(stack.container.window === window)
        try #require(!window.isVisible)
        try #require(!window.occlusionState.contains(.visible))

        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 30, expanded: !expanded,
            container: stack.container
        )
        stack.container.layoutSubtreeIfNeeded()
        try #require(stack.container.headerHeight == (expanded ? 30 : 120))

        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 30, expanded: expanded,
            container: stack.container
        )

        // This is a real attached window, deliberately ordered out. No source
        // edits or fabricated visibility state are needed to settle its header.
        try expectSettledHeader(stack, expanded: expanded)
    }

    private func expectSettledHeader(_ stack: Stack, expanded: Bool) throws {
        let target: CGFloat = expanded ? 120 : 30
        let clip = try #require(stack.controller.clipView)
        let host = try #require(stack.controller.hostingView)
        #expect(stack.controller.reservedHeight == target)
        #expect(stack.container.headerHeight == target)
        #expect(clip.frame.height == target)
        #expect(stack.textView.frame.origin.y == target)

        let heightConstraints = clip.constraints.filter {
            $0.isActive && $0.firstItem === clip && $0.firstAttribute == .height
                && ($0.secondItem == nil || $0.secondItem === host)
        }
        let heightConstraint = try #require(heightConstraints.count == 1 ? heightConstraints.first : nil)
        if expanded {
            #expect(heightConstraint.secondItem === host)
            #expect(heightConstraint.secondAttribute == .height)
        } else {
            #expect(heightConstraint.secondItem == nil)
            #expect(heightConstraint.constant == target)
        }
    }

    @Test func bodyClippingIsGatedOnHeaderPresence() {
        let stack = makeStack()
        // Header-less editors keep AppKit's defaults — no clipping or redraw-policy
        // change for embedders that never pass a header. (TextKit 2 text views are
        // layer-backed by default; that part was never a change.)
        #expect(stack.textView.clipsToBounds == false)

        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 30, expanded: false,
            container: stack.container
        )

        // With a header, the body must be layer-backed, clipped, and redrawn on
        // explicit invalidation so responsive-scroll overdraw can't bleed into the
        // band above it.
        #expect(stack.textView.wantsLayer == true)
        #expect(stack.textView.clipsToBounds == true)
        #expect(stack.textView.layerContentsRedrawPolicy == .onSetNeedsDisplay)
    }

    @Test func removeRestoresHeaderlessStacking() {
        let stack = makeStack()
        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 30, expanded: false,
            container: stack.container
        )
        stack.container.layoutSubtreeIfNeeded()
        #expect(stack.container.headerHeight == 30)

        stack.controller.remove(from: stack.container)

        #expect(stack.controller.clipView == nil)
        #expect(stack.container.headerHeight == 0)
        #expect(stack.textView.frame.origin.y == 0)
        #expect(stack.container.subviews.count == 1)   // text view only
    }
}
