//
//  TabBarMouseView.swift
//  PageFlow
//
//  AppKit gesture source for the tab bar. Owns no drag state — its only
//  job is to convert mouse events into calls on `TabDragController`, and
//  to surface hover / click callbacks back to SwiftUI.
//
//  By keeping the gesture layer below SwiftUI, we get sub-frame mouse
//  response without the layout-thrash that comes from running drag logic
//  inside a SwiftUI body.
//

import AppKit
import SwiftUI

struct TabBarMouseView: NSViewRepresentable {
    let tabManager: TabManager
    let tabFrames: [UUID: CGRect]
    let newTabButtonFrame: CGRect
    let hoveredTabID: UUID?
    let activeTabID: UUID?
    let onHover: (UUID?) -> Void
    let onClick: (CGFloat) -> Void

    func makeNSView(context: Context) -> TabBarMouseNSView {
        let view = TabBarMouseNSView()
        view.apply(
            tabManager: tabManager,
            tabFrames: tabFrames,
            newTabButtonFrame: newTabButtonFrame,
            hoveredTabID: hoveredTabID,
            activeTabID: activeTabID,
            onHover: onHover,
            onClick: onClick
        )
        return view
    }

    func updateNSView(_ nsView: TabBarMouseNSView, context: Context) {
        nsView.apply(
            tabManager: tabManager,
            tabFrames: tabFrames,
            newTabButtonFrame: newTabButtonFrame,
            hoveredTabID: hoveredTabID,
            activeTabID: activeTabID,
            onHover: onHover,
            onClick: onClick
        )
    }
}

@MainActor
final class TabBarMouseNSView: NSView, TabBarHandle {
    private static let dragThreshold: CGFloat = 5

    private weak var tabManagerRef: TabManager?
    private var tabFrames: [UUID: CGRect] = [:]
    private var newTabButtonFrame: CGRect = .zero
    private var hoveredTabID: UUID?
    private var activeTabID: UUID?
    private var onHover: (UUID?) -> Void = { _ in }
    private var onClick: (CGFloat) -> Void = { _ in }

    private var pressOrigin: NSPoint?
    private var pressedTabID: UUID?
    private var dragArmed = false
    /// True only when the current mouseDown was the second click of a
    /// double-click. Tab drag arms only on a held second-click — a plain
    /// single-click + drag is a no-op (the click still selects on
    /// mouseUp).
    private var canDrag = false
    private var trackingArea: NSTrackingArea?
    private var registered = false

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Configuration from SwiftUI

    func apply(
        tabManager: TabManager,
        tabFrames: [UUID: CGRect],
        newTabButtonFrame: CGRect,
        hoveredTabID: UUID?,
        activeTabID: UUID?,
        onHover: @escaping (UUID?) -> Void,
        onClick: @escaping (CGFloat) -> Void
    ) {
        self.tabManagerRef = tabManager
        self.tabFrames = tabFrames
        self.newTabButtonFrame = newTabButtonFrame
        self.hoveredTabID = hoveredTabID
        self.activeTabID = activeTabID
        self.onHover = onHover
        self.onClick = onClick
        registerIfReady()
    }

    // MARK: - View Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        registerIfReady()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            // Window torn down mid-drag — abort only if this view's
            // manager is the drag's current host. (Single-tab tear-off
            // closes the original source window; the drag is by then
            // hosted by the new torn-off manager and must not be killed.)
            if let tabManager = tabManagerRef {
                TabDragController.shared.cancelDragIfSource(tabManager)
            }
            unregister()
        }
    }

    private func registerIfReady() {
        guard !registered, window != nil, let tabManager = tabManagerRef else { return }
        TabDragController.shared.registerBar(self, for: tabManager)
        registered = true
    }

    private func unregister() {
        guard registered, let tabManager = tabManagerRef else { return }
        TabDragController.shared.unregisterBar(for: tabManager)
        registered = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Hit Testing (Window Drag Fall-Through)

    /// Empty bar space falls through to the underlying `WindowDragArea`,
    /// so dragging the bar background drags the window — Chrome / Safari
    /// behavior. Tab pills and the `+` button still receive clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview?.convert(point, to: self) ?? point
        if findTab(at: local.x) != nil || newTabButtonFrame.contains(local) {
            return self
        }
        return nil
    }

    // MARK: - Hover

    override func mouseEntered(with event: NSEvent) {
        emitHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        emitHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        guard !TabDragController.shared.isActive else { return }
        if hoveredTabID != nil { onHover(nil) }
    }

    private func emitHover(at point: NSPoint) {
        guard !TabDragController.shared.isActive else { return }
        let next = findTab(at: point.x)
        if next != hoveredTabID { onHover(next) }
    }

    // MARK: - Mouse Down / Drag / Up

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressOrigin = point
        pressedTabID = findTab(at: point.x)
        dragArmed = false
        canDrag = event.clickCount >= 2
    }

    override func mouseDragged(with event: NSEvent) {
        // Once the controller's app-level monitor takes over, the
        // synchronous override would double-process events.
        if TabDragController.shared.isActive { return }

        // Single-click drags are intentionally ignored — only a held
        // second click of a double-click can initiate a tab drag.
        guard canDrag,
              !dragArmed,
              let origin = pressOrigin,
              let tabManager = tabManagerRef else { return }

        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - origin.x, current.y - origin.y) >= Self.dragThreshold else { return }

        guard let tabID = pressedTabID,
              !isCloseHit(for: tabID, x: origin.x),
              let snapshot = makeDragSnapshot(for: tabID, in: tabManager),
              let screen = screenPoint(for: current) else {
            return
        }

        dragArmed = true
        TabDragController.shared.beginDrag(
            tabID: tabID,
            in: tabManager,
            snapshot: snapshot,
            screenPoint: screen
        )
    }

    override func mouseUp(with event: NSEvent) {
        // Drag-mode mouseUp is handled by the controller's monitor; this
        // override only fires for plain clicks (no threshold crossed).
        defer { resetMousePressState() }
        if TabDragController.shared.isActive { return }
        guard let origin = pressOrigin, !dragArmed else { return }
        onClick(origin.x)
    }

    private func resetMousePressState() {
        pressOrigin = nil
        pressedTabID = nil
        dragArmed = false
        canDrag = false
    }

    // MARK: - Coordinate Conversion

    private func screenPoint(for localPoint: NSPoint) -> CGPoint? {
        guard let window else { return nil }
        return window.convertPoint(toScreen: convert(localPoint, to: nil))
    }

    private func localPoint(for screenPoint: CGPoint) -> NSPoint? {
        guard let window else { return nil }
        return convert(window.convertPoint(fromScreen: screenPoint), from: nil)
    }

    // MARK: - Hit Test Helpers

    private func findTab(at x: CGFloat) -> UUID? {
        guard let tabManager = tabManagerRef else { return nil }
        for tab in tabManager.tabs {
            guard let frame = tabFrames[tab.id] else { continue }
            if x >= frame.minX && x <= frame.maxX { return tab.id }
        }
        return nil
    }

    private func isCloseHit(for tabID: UUID, x: CGFloat) -> Bool {
        guard let frame = tabFrames[tabID] else { return false }
        let isCloseVisible = hoveredTabID == tabID || activeTabID == tabID
        guard isCloseVisible else { return false }
        let closeMaxX = frame.maxX - DesignTokens.spacingSM
        let closeMinX = closeMaxX - DesignTokens.tabCloseButtonSize
        return x >= closeMinX && x <= closeMaxX
    }

    private func makeDragSnapshot(for tabID: UUID, in tabManager: TabManager) -> TabDragPreviewSnapshot? {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabID }) else { return nil }
        let baseWidth = tabFrames[tabID]?.width ?? DesignTokens.tabMinWidth
        let width = min(max(baseWidth, DesignTokens.tabMinWidth), DesignTokens.tabMaxWidth)
        return TabDragPreviewSnapshot(
            title: tab.displayTitle,
            isDirty: tabManager.isTabDirty(tabID),
            width: width
        )
    }

    // MARK: - TabBarHandle

    func contains(screenPoint: CGPoint) -> Bool {
        guard let local = localPoint(for: screenPoint) else { return false }
        return bounds.contains(local)
    }

    func screenFrame() -> CGRect {
        guard let window else { return .zero }
        let windowRect = convert(bounds, to: nil)
        return window.convertToScreen(windowRect)
    }

    func dropIndex(for screenPoint: CGPoint) -> Int? {
        guard let tabManager = tabManagerRef,
              let local = localPoint(for: screenPoint),
              bounds.contains(local) else {
            return nil
        }

        for (index, tab) in tabManager.tabs.enumerated() {
            guard let frame = tabFrames[tab.id] else { continue }
            if local.x < frame.midX { return index }
        }
        return tabManager.tabs.count
    }
}
