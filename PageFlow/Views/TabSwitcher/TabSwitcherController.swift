//
//  TabSwitcherController.swift
//  PageFlow
//
//  Owns the single Tab Switcher dropdown — Chrome's "Search Tabs": one
//  searchable, keyboard-navigable list of every tab in every window, plus
//  recently closed documents. Clicking a row raises that tab's window and
//  selects the tab.
//
//  The dropdown is a non-activating floating NSPanel hosting a SwiftUI view —
//  the Spotlight/Raycast pattern. NSPanel (unlike NSMenu's modal tracking loop)
//  can host a live search field, and (unlike NSPopover) keeps text first-
//  responder and owns its own dismissal.
//

import AppKit
import SwiftUI

@MainActor
final class TabSwitcherController {
    static let shared = TabSwitcherController()

    private var panel: TabSwitcherPanel?
    private var clickMonitor: Any?

    /// Per-window chevron anchors, so a menu/keyboard invocation drops the panel
    /// under the right window's button. Keyed by window identity.
    private var anchors: [ObjectIdentifier: WeakView] = [:]
    /// The anchor the visible panel was launched from — distinguishes "same
    /// chevron → close" from "another window's chevron → move" in `toggle`.
    private weak var launchAnchor: NSView?

    private final class WeakView {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    private init() {}

    var isVisible: Bool { panel?.isVisible == true }

    // MARK: - Anchor registration (called by the chevron)

    func registerAnchor(_ view: NSView, for window: NSWindow) {
        anchors[ObjectIdentifier(window)] = WeakView(view)
    }

    func unregisterAnchor(for window: NSWindow) {
        anchors.removeValue(forKey: ObjectIdentifier(window))
    }

    // MARK: - Show / hide

    func toggle(forWindow window: NSWindow?, hostTabManager: TabManager?) {
        guard isVisible else {
            show(forWindow: window, hostTabManager: hostTabManager)
            return
        }
        // `toggle` is the SOLE owner of the open→closed/moved transition (the
        // click monitor never tears the panel down for a chevron click), so
        // there is no dismiss-then-reopen race. A different DOCUMENT window's
        // chevron moves the panel there; the same window's chevron closes it.
        //
        // `window !== panel` guards the keyboard path: while open, the panel is
        // key, so the ⌘⇧A menu command passes NSApp.keyWindow == the panel. Without
        // this guard `show` would re-anchor off the panel's OWN frame (no chevron
        // is registered for it), walking it down-right on every repeated press.
        if let window, window !== panel, launchAnchor?.window !== window {
            show(forWindow: window, hostTabManager: hostTabManager)
        } else {
            hide()
        }
    }

    func show(forWindow window: NSWindow?, hostTabManager: TabManager?) {
        guard let window else { return }
        hide()  // never stack two

        let groups = WindowRegistry.shared.allOpenTabs()
        let closed = ClosedTabStore.shared.records
        let anchor = anchors[ObjectIdentifier(window)]?.view
        let anchorRect = anchorScreenRect(anchor: anchor, window: window)

        let root = TabSwitcherView(
            groups: groups,
            closed: closed,
            maxListHeight: maxListHeight(below: anchorRect, in: window),
            onJump: { [weak self] tabID, manager in
                WindowRegistry.shared.jumpToTab(tabID, in: manager)
                self?.hide()
            },
            onReopen: { [weak self] record in
                self?.reopen(record, host: hostTabManager)
                self?.hide()
            },
            onClose: { [weak self] in self?.hide() }
        )

        let hosting = NSHostingController(rootView: root)

        let panel = self.panel ?? TabSwitcherPanel()
        panel.onClose = { [weak self] in self?.hide() }
        panel.contentViewController = hosting
        panel.setContentSize(hosting.view.fittingSize)
        self.panel = panel

        positionPanel(panel, below: anchorRect)
        panel.makeKeyAndOrderFront(nil)

        launchAnchor = anchor
        installClickMonitor()
    }

    func hide() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
        panel?.orderOut(nil)
        // Drop the SwiftUI tree so its [WindowTabGroup] snapshot stops pinning
        // those windows' TabManagers/PDFManagers while the panel is hidden.
        panel?.contentViewController = nil
        launchAnchor = nil
    }

    // MARK: - Actions

    private func reopen(_ record: ClosedTabStore.Record, host: TabManager?) {
        let target = host ?? WindowRegistry.shared.frontmostTabManager()
        target?.openDocument(url: record.url, isSecurityScoped: record.isSecurityScoped)
        ClosedTabStore.shared.remove(record)
    }

    // MARK: - Geometry

    /// The chevron's rect in screen coordinates, or a leading-edge fallback when
    /// no anchor is registered (e.g. a keyboard invocation while the top bar is
    /// hidden).
    private func anchorScreenRect(anchor: NSView?, window: NSWindow) -> NSRect {
        if let anchor, anchor.window === window {
            let inWindow = anchor.convert(anchor.bounds, to: nil)
            return window.convertToScreen(inWindow)
        }
        let frame = window.frame
        let x = frame.minX + DesignTokens.trafficLightClusterWidth + DesignTokens.spacingSM
        let topY = frame.maxY - DesignTokens.spacingMD
        return NSRect(x: x, y: topY - 24, width: 28, height: 24)
    }

    /// The tallest the list may be while keeping the dropdown contained within
    /// the originating WINDOW (and never off-screen) — so it extends as far as the
    /// window allows, with no arbitrary cap.
    private func maxListHeight(below anchorRect: NSRect, in window: NSWindow) -> CGFloat {
        let screenBottom = (window.screen ?? NSScreen.main)?.visibleFrame.minY ?? 0
        // Bound by whichever bottom is higher — the window's edge or the screen's.
        let bottom = max(window.frame.minY, screenBottom)
        let chrome = TabSwitcherMetrics.headerHeight + 1  // search header + divider
        // Keep the glass (and its drop shadow) clear of the window's bottom edge.
        let bottomInset = TabSwitcherMetrics.shadowPadding
        let available = (anchorRect.minY - TabSwitcherMetrics.anchorGap) - bottom - chrome - bottomInset
        return max(available, TabSwitcherMetrics.minListHeight)
    }

    private func positionPanel(_ panel: NSPanel, below anchorRect: NSRect) {
        // The panel's visible glass sits inside `shadowPadding` of transparent
        // margin (room for the SwiftUI drop shadow). Offset so the glass — not the
        // panel edge — lines up just below and left-aligned with the chevron.
        let pad = TabSwitcherMetrics.shadowPadding
        let topLeft = NSPoint(x: anchorRect.minX - pad, y: anchorRect.minY - TabSwitcherMetrics.anchorGap + pad)
        panel.setFrameTopLeftPoint(topLeft)

        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
        if frame.minX < visible.minX { frame.origin.x = visible.minX }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        panel.setFrame(frame, display: false)
    }

    // MARK: - Dismissal

    /// A local mouse-down monitor dismisses the panel on a click outside it.
    /// Out-of-app clicks are handled by the panel's `hidesOnDeactivate`.
    private func installClickMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }

            // Click inside the switcher → keep it open.
            if event.window === panel { return event }

            // A LEFT click on ANY window's chevron is owned by that button's
            // `toggle` (move or close) — don't also dismiss here, or the two
            // paths would race. Right-clicks fall through and dismiss.
            if event.type == .leftMouseDown, isChevronClick(event) {
                return event
            }

            self.hide()
            return event
        }
    }

    private func isChevronClick(_ event: NSEvent) -> Bool {
        for box in anchors.values {
            guard let anchor = box.view, anchor.window === event.window else { continue }
            let point = anchor.convert(event.locationInWindow, from: nil)
            if anchor.bounds.contains(point) { return true }
        }
        return false
    }
}

// MARK: - Panel

/// A borderless, non-activating floating panel. `canBecomeKey` is overridden so
/// the search field can take first responder (the #1 cause of a panel whose
/// field "won't type"); dismissal is owned by the controller's click monitor
/// plus `hidesOnDeactivate` and Escape.
final class TabSwitcherPanel: NSPanel {
    var onClose: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false  // the SwiftUI glass panel draws its own elevation shadow
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape from anywhere in the panel closes it (the search field also routes
    /// Escape here via its delegate).
    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }
}
