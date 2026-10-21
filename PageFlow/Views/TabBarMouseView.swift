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

enum TabBarClickTarget: Equatable {
    case newTab
    case selectTab(UUID)
    case closeTab(UUID)
}

struct TabBarMouseView: NSViewRepresentable {
    let tabManager: TabManager
    let tabFrames: [UUID: CGRect]
    let newTabButtonFrame: CGRect
    let hoveredTabID: UUID?
    let activeTabID: UUID?
    let onHover: (UUID?) -> Void
    let onClick: (TabBarClickTarget) -> Void

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
    private var onClick: (TabBarClickTarget) -> Void = { _ in }

    private var pressOrigin: NSPoint?
    private var pressedTarget: TabBarClickTarget?
    private var pressedButtonFrame: CGRect?
    private var pressGrabOffset: CGPoint?
    private var dragArmed = false
    private var trackingArea: NSTrackingArea?
    private var registered = false
    private var isHoverRefreshScheduled = false

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
        onClick: @escaping (TabBarClickTarget) -> Void
    ) {
        let layoutChanged = self.tabFrames != tabFrames || self.activeTabID != activeTabID
            || self.newTabButtonFrame != newTabButtonFrame
        self.tabManagerRef = tabManager
        self.tabFrames = tabFrames
        self.newTabButtonFrame = newTabButtonFrame
        self.hoveredTabID = hoveredTabID
        self.activeTabID = activeTabID
        self.onHover = onHover
        self.onClick = onClick
        registerIfReady()
        if layoutChanged {
            window?.invalidateCursorRects(for: self)
            scheduleHoverRefresh()
        }
    }

    // MARK: - View Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        // AppKit does NOT reliably re-invoke updateTrackingAreas after a
        // direct window-to-window re-parent — re-arm explicitly (same bug
        // class as the chrome hover sensor).
        updateTrackingAreas()
        registerIfReady()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // Drop the area on ANY window change — its registration belongs to
        // the old window; viewDidMoveToWindow re-arms in the new one.
        if let trackingArea {
            removeTrackingArea(trackingArea)
            self.trackingArea = nil
        }
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
        // Re-create every call (StablePDFView pattern): an area kept across a
        // window re-parent stays registered with the OLD window and goes
        // inert — same bug class as the chrome hover sensor's lost traffic
        // lights. .activeInActiveApp so tab hover works in non-key windows,
        // matching native tab strips.
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        scheduleHoverRefresh()
    }

    // MARK: - Hit Testing (Window Drag Fall-Through)

    /// Empty bar space falls through to the underlying `WindowDragArea`,
    /// so dragging the bar background drags the window — Chrome / Safari
    /// behavior. Tab pills and the `+` button still receive clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Outside this view's frame (e.g. the width a floating toolbar
        // covers) is never ours, even where a tab lies underneath.
        guard frame.contains(point) else { return nil }
        if findTab(at: point) != nil || newTabButtonFrame.contains(point) {
            return self
        }
        return nil
    }

    override func resetCursorRects() {
        for frame in Array(tabFrames.values) + [newTabButtonFrame] {
            let visible = bounds.intersection(frame)
            if !visible.isEmpty { addCursorRect(visible, cursor: .pointingHand) }
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        guard !TabDragController.shared.isActive else { return }
        let point = convert(event.locationInWindow, from: nil)
        (bounds.contains(point) && clickTarget(at: point) != nil ? NSCursor.pointingHand : .arrow).set()
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

    /// A point outside the view (over a toolbar floating past its trailing
    /// edge) hovers nothing, though a tab's frame may run under it.
    private func emitHover(at point: NSPoint) {
        guard !TabDragController.shared.isActive else { return }
        let next = bounds.contains(point) ? findTab(at: point) : nil
        if next != hoveredTabID { onHover(next) }
    }

    /// Tabs can move under a pointer that doesn't (a ⌘1–9 switch re-lays out
    /// the Deck; a floating toolbar narrows the strip), and AppKit sends no
    /// mouse event for that, so a stale hover would keep a card slid out.
    /// Re-read the pointer once the layout has landed — a turn later, never
    /// inside the SwiftUI update that delivered it.
    private func scheduleHoverRefresh() {
        guard !isHoverRefreshScheduled else { return }
        isHoverRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isHoverRefreshScheduled = false
            guard let window else { return }
            emitHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    // MARK: - Mouse Down / Drag / Up

    override func mouseDown(with event: NSEvent) {
        resetMousePressState()
        guard !TabDragController.shared.isActive else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let target = clickTarget(at: point) else { return }
        pressOrigin = point
        pressedTarget = target

        switch target {
        case .selectTab(let tabID):
            // Selection can move or resize the tab synchronously. Keep the
            // original grab point, with y measured from the tab's bottom.
            if let frame = tabFrames[tabID] {
                pressGrabOffset = CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
            }
            onClick(target)
        case .closeTab(let tabID):
            pressedButtonFrame = closeButtonFrame(for: tabID)
        case .newTab:
            pressedButtonFrame = newTabButtonFrame
        }
    }

    override func mouseDragged(with event: NSEvent) {
        // Once the controller's app-level monitor takes over, the
        // synchronous override would double-process events.
        if TabDragController.shared.isActive { return }

        guard !dragArmed,
              let origin = pressOrigin,
              let target = pressedTarget,
              case .selectTab(let tabID) = target,
              let tabManager = tabManagerRef else { return }

        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - origin.x, current.y - origin.y) > Self.dragThreshold else { return }

        guard let snapshot = makeDragSnapshot(for: tabID, in: tabManager),
              let screen = screenPoint(for: current) else {
            return
        }

        dragArmed = true
        TabDragController.shared.beginDrag(
            tabID: tabID,
            in: tabManager,
            snapshot: snapshot,
            screenPoint: screen,
            grabOffset: pressGrabOffset
        )
    }

    override func mouseUp(with event: NSEvent) {
        // Drag-mode mouseUp is handled by the controller's monitor; this
        // override only fires for plain clicks (no threshold crossed).
        defer { resetMousePressState() }
        if TabDragController.shared.isActive { return }
        guard !dragArmed,
              let target = pressedTarget,
              let buttonFrame = pressedButtonFrame,
              buttonFrame.contains(convert(event.locationInWindow, from: nil)) else {
            return
        }
        onClick(target)
    }

    private func resetMousePressState() {
        pressOrigin = nil
        pressedTarget = nil
        pressedButtonFrame = nil
        pressGrabOffset = nil
        dragArmed = false
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

    private func clickTarget(at point: NSPoint) -> TabBarClickTarget? {
        if newTabButtonFrame.contains(point) {
            return .newTab
        }

        guard let tabID = findTab(at: point) else { return nil }
        return isCloseHit(for: tabID, at: point) ? .closeTab(tabID) : .selectTab(tabID)
    }

    private func findTab(at point: NSPoint) -> UUID? {
        guard let tabManager = tabManagerRef else { return nil }
        for tab in tabManager.tabs {
            guard let frame = tabFrames[tab.id] else { continue }
            if frame.contains(point) { return tab.id }
        }
        return nil
    }

    private func isCloseHit(for tabID: UUID, at point: NSPoint) -> Bool {
        closeButtonFrame(for: tabID)?.contains(point) ?? false
    }

    private func closeButtonFrame(for tabID: UUID) -> CGRect? {
        guard let frame = tabFrames[tabID] else { return nil }
        let isCloseVisible = hoveredTabID == tabID || activeTabID == tabID
        guard isCloseVisible else { return nil }
        let closeMaxX = frame.maxX - DesignTokens.spacingSM
        let closeMinX = closeMaxX - DesignTokens.tabCloseButtonSize
        let closeY = frame.midY - DesignTokens.tabCloseButtonSize / 2
        return CGRect(
            x: closeMinX,
            y: closeY,
            width: DesignTokens.tabCloseButtonSize,
            height: DesignTokens.tabCloseButtonSize
        )
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

    func tabScreenFrame(for tabID: UUID) -> CGRect? {
        guard let window, let frame = tabFrames[tabID] else { return nil }
        return window.convertToScreen(convert(frame, to: nil))
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
