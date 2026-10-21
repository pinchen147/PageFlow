//
//  TabDragController.swift
//  PageFlow
//
//  Single source of truth for tab drag-and-drop. Owns the floating preview,
//  the cross-window drop-target registry, the cursor lifecycle, tear-off
//  into a detached window, live re-merge into any tab bar, and the
//  observable state SwiftUI renders against.
//
//  The mouse-event source (`TabBarMouseView`) calls into this controller
//  as a thin client. SwiftUI views observe `activeDrag` and `isActive` —
//  both are deduped at write time so per-pixel mouse updates only mutate
//  state when the drag actually crosses a tab boundary, window, or phase.
//
//  Phases
//  ------
//  `.pill`   — tab is hidden in `dragHost`'s bar, a floating NSPanel
//              renders the pill under the cursor, hover over any tab bar
//              shows an insertion gap.
//  `.window` — tab has been torn off into a window whose origin follows
//              the cursor: a brand-new NSWindow, or — when the dragged tab
//              is its window's only tab — the source window itself, moved
//              under the cursor (no new window or manager). The rendered pill
//              is hidden. Hover over any other bar re-merges: retire the window
//              if empty, restore the pill, resume `.pill` drag.
//
//  `dragHost` — the TabManager currently holding the dragged tab. Begin:
//  the source bar's manager. After tear-off: the new torn-off manager (or,
//  for a single-tab window, still the source manager).
//  After re-merge: the manager whose bar received the merge. Tracking the
//  CURRENT host (rather than just the original source) is what lets
//  re-merge land directly in the resolved target, and what lets a
//  single-tab tear-off survive its source window closing — the drag
//  doesn't lose its anchor.
//
//  Transitions are driven by `updateDrag`:
//    `.pill → .window`  — cursor is ≥20pt vertically outside the host bar
//                         AND not over any other target bar (Figma's
//                         tear-off threshold).
//    `.window → .pill`  — cursor enters any registered tab bar (except
//                         the torn-off bar itself).
//

import AppKit
import SwiftUI

/// Per-window tab-bar handle. The controller queries each registered bar
/// during a drag to resolve the current drop target and insertion index.
@MainActor
protocol TabBarHandle: AnyObject {
    var window: NSWindow? { get }
    func contains(screenPoint: CGPoint) -> Bool
    func dropIndex(for screenPoint: CGPoint) -> Int?
    /// Full bar rect in screen coordinates. The controller measures
    /// tear-off distance against this rect.
    func screenFrame() -> CGRect
    /// Measured tab rect, including the bar's current scroll position.
    func tabScreenFrame(for tabID: UUID) -> CGRect?
}

extension TabBarHandle {
    func tabScreenFrame(for tabID: UUID) -> CGRect? { nil }
}

@MainActor
@Observable
final class TabDragController {
    static let shared = TabDragController()

    /// Vertical distance from the host bar at which a pill drag flips into
    /// a torn-off window drag (Figma's tear-off threshold).
    private static let tearOffThreshold: CGFloat = 20

    // MARK: - Public Observable State

    /// Toggled when a drag starts/ends. Stored separately from `activeDrag`
    /// so views that only care about the on/off transition don't re-render on
    /// every insertion-index update.
    private(set) var isActive: Bool = false

    /// Drag specifics. Updated only when meaningful state changes — never
    /// per-pixel — so SwiftUI receives at most one transaction per
    /// boundary crossing.
    private(set) var activeDrag: ActiveDrag?

    struct ActiveDrag: Equatable {
        let tabID: UUID
        /// Manager whose tab is replaced by the floating pill. Nil during
        /// window movement, when the real tab stays visible in its own bar.
        var sourceManagerID: ObjectIdentifier?
        let draggedWidth: CGFloat
        var insertionTargetID: ObjectIdentifier?
        var insertionIndex: Int?
    }

    // MARK: - Bar Registry

    private struct Entry {
        weak var tabManager: TabManager?
        weak var handle: TabBarHandle?
    }

    private var bars: [ObjectIdentifier: Entry] = [:]

    func registerBar(_ handle: TabBarHandle, for tabManager: TabManager) {
        bars[ObjectIdentifier(tabManager)] = Entry(tabManager: tabManager, handle: handle)
        if cachedDropEntry?.tabManager === tabManager { cachedDropEntry = nil }
    }

    func unregisterBar(for tabManager: TabManager) {
        bars.removeValue(forKey: ObjectIdentifier(tabManager))
        if cachedDropEntry?.tabManager === tabManager { cachedDropEntry = nil }
    }

    // MARK: - Internal Drag State

    private enum Phase {
        case pill
        case window(NSWindow, cursorOffset: CGPoint)
    }

    private var phase: Phase = .pill
    /// Manager currently holding the dragged tab. Updated on tear-off and
    /// re-merge.
    private weak var dragHost: TabManager?
    /// The original mouse-down window must survive until release, including
    /// when that same window is reused for a one-tab drag and later merged.
    private weak var captureWindow: NSWindow?
    private var originalCollectionBehavior: NSWindow.CollectionBehavior?
    /// Host bar rect in screen coords. Updated whenever `dragHost`
    /// changes so the tear-off threshold uses the correct anchor.
    private var hostBarScreenRect: CGRect = .zero
    /// Host window frame size. Inherited by torn-off windows.
    private var hostWindowFrameSize: NSSize = .zero
    private var grabOffset: CGPoint = .zero
    private var preview: TabDragPreviewWindow?
    private var cachedDropEntry: Entry?
    private var cursorPushed = false

    /// Event monitor lives on the controller (not the originating view) so
    /// it outlives single-tab tear-off — when the source view dies, a
    /// view-owned monitor with `[weak self]` would be nilled out and the
    /// drag would silently freeze in `.window` mode. Owning it here keeps
    /// `mouseDragged` / `mouseUp` flowing until we tear it down ourselves.
    @ObservationIgnored private var eventMonitor: Any?
    @ObservationIgnored private var resignActiveObserver: NSObjectProtocol?

    /// Managers that became empty during the drag and were intentionally
    /// kept alive (so the macOS implicit mouse-grab doesn't break when
    /// their window would otherwise close). Closed in `cleanup`.
    @ObservationIgnored private var deferredCloseManagers: [TabManager] = []

    private init() {}

    // MARK: - Drag Lifecycle

    func beginDrag(
        tabID: UUID,
        in tabManager: TabManager,
        snapshot: TabDragPreviewSnapshot,
        screenPoint: CGPoint,
        grabOffset: CGPoint? = nil
    ) {
        // Defensive: if a previous drag was somehow not torn down, drop it.
        cleanup()

        adoptHost(tabManager)
        captureWindow = bars[ObjectIdentifier(tabManager)]?.handle?.window
            ?? WindowRegistry.shared.window(for: tabManager)
        self.grabOffset = grabOffset ?? CGPoint(x: snapshot.width / 2, y: DesignTokens.tabHeight / 2)

        let preview = TabDragPreviewWindow(snapshot: snapshot, grabOffset: self.grabOffset)
        preview.move(to: screenPoint)
        preview.show()
        self.preview = preview

        pushCursor()

        let hostID = ObjectIdentifier(tabManager)
        let initialIndex = bars[hostID]?.handle?.dropIndex(for: screenPoint)

        activeDrag = ActiveDrag(
            tabID: tabID,
            sourceManagerID: hostID,
            draggedWidth: snapshot.width,
            insertionTargetID: hostID,
            insertionIndex: initialIndex
        )
        isActive = true
        phase = .pill
        installEventMonitor()
    }

    func updateDrag(to screenPoint: CGPoint) {
        guard isActive, let drag = activeDrag else { return }
        switch phase {
        case .pill:
            updatePillPhase(to: screenPoint, drag: drag)
        case .window(let window, let offset):
            updateWindowPhase(to: screenPoint, drag: drag, window: window, offset: offset)
        }
    }

    func endDrag(at screenPoint: CGPoint) {
        guard isActive else {
            cleanup()
            return
        }

        // Mouse-up can carry a newer position than the last drag event.
        // Resolve it before committing so the release point decides the host.
        let phaseBeforeRelease = phase
        updateDrag(to: screenPoint)
        guard let drag = activeDrag else {
            cleanup()
            return
        }

        switch phase {
        case .pill:
            if case .window = phaseBeforeRelease, let host = dragHost {
                // This event already resolved the target and moved the tab.
                // A retained torn-off window must not change that decision
                // merely because the transfer changed the drag phase.
                host.selectTab(drag.tabID)
                WindowRegistry.shared.bringToFront(for: host)
            } else {
                commitPillDrop(drag: drag, at: screenPoint)
            }
        case .window(let window, _):
            finalizeTornOffWindow(window, at: screenPoint)
        }
        cleanup()
    }

    /// `dropPoint` is the cursor location when the cancel was driven by an ESC
    /// keystroke; nil for app-resign-active or source-window-close, where the
    /// inaccessible torn-off chrome is recovered using the window's own screen.
    func cancelDrag(at dropPoint: CGPoint? = nil) {
        // ESC during `.window`: drop the window where it is (option 5b).
        // Everywhere else cancel is a pure state reset.
        if case .window(let window, _) = phase {
            finalizeTornOffWindow(window, at: dropPoint)
        }
        cleanup()
    }

    /// Cancels the drag only if its current host is the given manager.
    /// Used by `TabBarMouseView.viewWillMove(toWindow: nil)` so closing
    /// an unrelated window — or the original source after a single-tab
    /// tear-off — doesn't abort an in-flight drag.
    func cancelDragIfSource(_ tabManager: TabManager) {
        guard dragHost === tabManager else { return }
        cancelDrag()
    }

    // MARK: - Pill Phase

    private func updatePillPhase(to screenPoint: CGPoint, drag: ActiveDrag) {
        preview?.move(to: screenPoint)

        // Resolution wins over threshold: hovering any non-host bar
        // (or the host bar itself) is a reorder/merge target, even if
        // the cursor is technically far from the host vertically.
        if let resolution = resolveDropTarget(at: screenPoint) {
            applyResolution(resolution, drag: drag)
            return
        }

        // Off all bars. Tear off when cursor is ≥20pt vertically outside
        // the host bar's vertical extent (Figma's threshold). Horizontal
        // motion alone never tears off — it just stays in pill mode.
        let dy = verticalDistanceFromHostBar(screenPoint)
        if dy >= Self.tearOffThreshold, let host = dragHost {
            tearOff(at: screenPoint, drag: drag, host: host)
            return
        }

        clearInsertion(drag: drag)
    }

    private func applyResolution(_ resolution: Resolution, drag: ActiveDrag) {
        let nextTargetID = ObjectIdentifier(resolution.tabManager)
        let nextIndex = resolution.index
        guard drag.insertionTargetID != nextTargetID
            || drag.insertionIndex != nextIndex else {
            return
        }
        var next = drag
        next.insertionTargetID = nextTargetID
        next.insertionIndex = nextIndex
        activeDrag = next
    }

    private func clearInsertion(drag: ActiveDrag) {
        guard drag.insertionTargetID != nil || drag.insertionIndex != nil else { return }
        var next = drag
        next.insertionTargetID = nil
        next.insertionIndex = nil
        activeDrag = next
    }

    private func commitPillDrop(drag: ActiveDrag, at screenPoint: CGPoint) {
        guard let host = dragHost else { return }
        guard let resolution = resolveDropTarget(at: screenPoint) else {
            // No target and we never crossed the threshold — snap back.
            return
        }
        if resolution.tabManager === host {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                host.commitTabReorder(drag.tabID, toIndex: resolution.index)
            }
            // Live re-merge preserves the target's selection while hovering.
            // Once dropped, the transferred document becomes the active tab.
            host.selectTab(drag.tabID)
            WindowRegistry.shared.bringToFront(for: host)
        } else {
            // Not animated: a cross-window move does session detach/attach,
            // state persistence, and a view-state restore — wrapping all of
            // that in withAnimation animates every observable mutation in the
            // pass (the destination's PDF view included), which reads as a
            // hitch on drop. The destination bar's insertion gap has already
            // previewed the landing slot.
            _ = host.moveTab(drag.tabID, to: resolution.tabManager, at: resolution.index)
        }
    }

    // MARK: - Window Phase

    private func updateWindowPhase(
        to screenPoint: CGPoint,
        drag: ActiveDrag,
        window: NSWindow,
        offset: CGPoint
    ) {
        if let resolution = resolveDropTarget(at: screenPoint) {
            remerge(to: screenPoint, drag: drag, window: window, resolution: resolution)
            return
        }

        let origin = CGPoint(
            x: screenPoint.x + offset.x,
            y: screenPoint.y + offset.y
        )
        window.setFrameOrigin(origin)
        clearInsertion(drag: drag)
    }

    private func finalizeTornOffWindow(_ window: NSWindow, at dropPoint: CGPoint?) {
        restoreCollectionBehavior(of: window)
        recoverInaccessibleWindow(window, at: dropPoint)
    }

    private func restoreCollectionBehavior(of window: NSWindow) {
        guard let originalCollectionBehavior else { return }
        window.collectionBehavior = originalCollectionBehavior
        self.originalCollectionBehavior = nil
    }

    private func beginWindowPhase(_ window: NSWindow, offset: CGPoint, drag: ActiveDrag) {
        originalCollectionBehavior = window.collectionBehavior
        window.collectionBehavior.insert(.canJoinAllSpaces)
        preview?.hide()
        cachedDropEntry = nil
        phase = .window(window, cursorOffset: offset)
        var next = drag
        next.sourceManagerID = nil
        next.insertionTargetID = nil
        next.insertionIndex = nil
        activeDrag = next
    }

    /// A user-placed window may extend beyond a display without losing its
    /// draggable chrome. Preserve that placement; fitting the entire frame at
    /// release would make the window jump away from the cursor. Check every
    /// display so a window spanning a boundary is not pulled onto just one.
    /// If the bar is unavailable or inaccessible, retain the existing recovery
    /// path for cancellation, display changes, and offscreen placement.
    private func recoverInaccessibleWindow(_ window: NSWindow, at dropPoint: CGPoint?) {
        if let handle = bars.values.compactMap(\.handle).first(where: { $0.window === window }) {
            let chrome = handle.screenFrame()
            let isReachable = chrome.width > 0 && chrome.height > 0 && NSScreen.screens.contains { screen in
                let visibleChrome = chrome.intersection(screen.visibleFrame)
                return !visibleChrome.isNull && visibleChrome.width >= min(80, chrome.width) &&
                    visibleChrome.height >= chrome.height - 1
            }
            if isReachable { return }
        }
        let screen = dropPoint.flatMap { NSScreen.containing($0) } ?? window.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let fitted = NSScreen.onScreenFrame(window.frame, in: visible)
        guard fitted != window.frame else { return }
        window.setFrame(fitted, display: true)
    }

    // MARK: - Tear Off

    private func tearOff(at screenPoint: CGPoint, drag: ActiveDrag, host: TabManager) {
        let rawSize = hostWindowFrameSize == .zero
            ? NSSize(width: DesignTokens.defaultWindowWidth, height: DesignTokens.defaultWindowHeight)
            : hostWindowFrameSize
        let frameSize = Self.tornOffWindowSize(
            rawSize,
            visibleFrame: NSScreen.containing(screenPoint)?.visibleFrame.size
        )

        let sourceWindow = WindowRegistry.shared.window(for: host)
        var offset = cursorToWindowOffset(for: drag, in: host, windowHeight: frameSize.height)
        let origin = CGPoint(
            x: screenPoint.x + offset.x,
            y: screenPoint.y + offset.y
        )
        let frame = NSRect(origin: origin, size: frameSize)

        if host.tabs.count == 1, let sourceWindow, sourceWindow.isVisible,
           !sourceWindow.styleMask.contains(.fullScreen), sourceWindow.attachedSheet == nil {
            // A sole tab already owns the complete native surface it needs.
            // Preserve its actual slot, including any remaining scroll offset.
            if let tabFrame = bars[ObjectIdentifier(host)]?.handle?.tabScreenFrame(for: drag.tabID) {
                offset.x = -(tabFrame.minX - sourceWindow.frame.minX + grabOffset.x)
            }
            let reusedFrame = NSRect(
                origin: CGPoint(x: screenPoint.x + offset.x, y: screenPoint.y + offset.y), size: frameSize
            )
            beginWindowPhase(sourceWindow, offset: offset, drag: drag)
            withoutOrderingAnimation(of: sourceWindow) {
                WindowRegistry.shared.bringToFront(for: host)
            }
            if sourceWindow.frame.size == reusedFrame.size {
                sourceWindow.setFrameOrigin(reusedFrame.origin)
            } else {
                sourceWindow.setFrame(reusedFrame, display: false)
            }
            return
        }

        guard let appDelegate = AppDelegate.shared else { return }
        // Move the tab into a fresh empty manager. `closeIfEmpty: false`
        // keeps the original host's window alive even if it just lost its
        // last tab — closing it now would break the macOS implicit
        // mouse-grab from the original `mouseDown` and silently freeze
        // the drag. We close it ourselves in `cleanup` after mouseUp.
        let newTabManager = TabManager(createInitialTab: false)
        guard host.moveTab(
            drag.tabID,
            to: newTabManager,
            at: 0,
            closeIfEmpty: false
        ) else { return }
        if host.tabs.isEmpty {
            deferredCloseManagers.append(host)
        }

        // Transfer event ownership before mounting the new root: its layout can
        // tear down the old bar synchronously and invoke cancelDragIfSource.
        adoptHost(newTabManager)
        guard let newWindow = appDelegate.createNewWindow(
            with: newTabManager, frame: frame, animatePresentation: false
        ) else {
            // Window creation failed — put the tab back where it came from so
            // it (and any unsaved edits) can't strand in an unanchored manager.
            _ = newTabManager.moveTab(drag.tabID, to: host, at: 0)
            adoptHost(host)
            return
        }
        if let tabFrame = bars[ObjectIdentifier(newTabManager)]?.handle?.tabScreenFrame(for: drag.tabID),
           !tabFrame.isEmpty {
            offset = CGPoint(
                x: -(tabFrame.minX - newWindow.frame.minX + grabOffset.x),
                y: -(tabFrame.minY - newWindow.frame.minY + grabOffset.y)
            )
            newWindow.setFrameOrigin(CGPoint(x: screenPoint.x + offset.x, y: screenPoint.y + offset.y))
        }

        adoptHost(newTabManager)
        beginWindowPhase(newWindow, offset: offset, drag: drag)

        // Keep the mouse-down window alive until release, but remove its empty
        // content and shadow once the detached document has a visible home.
        if host.tabs.isEmpty, let sourceWindow {
            withoutOrderingAnimation(of: sourceWindow) { sourceWindow.orderOut(nil) }
        }
    }

    // MARK: - Re-merge

    private func remerge(
        to screenPoint: CGPoint,
        drag: ActiveDrag,
        window: NSWindow,
        resolution: Resolution
    ) {
        guard let host = dragHost, let preview else { return }

        // Cover the held tab before moving its session or retiring its window.
        // Reuse the rendered pickup surface so merge has no new SwiftUI mount.
        preview.move(to: screenPoint)
        preview.show()

        // Move tab from torn-off manager directly into the resolved
        // target. `select: false` so the target's active tab isn't
        // disturbed mid-drag. If no other tabs remain, moving the tab also
        // schedules the torn-off window to close.
        guard host.moveTab(
            drag.tabID,
            to: resolution.tabManager,
            at: resolution.index,
            select: false,
            closeIfEmpty: window !== captureWindow
        ) else {
            preview.hide()
            return
        }

        // Empty windows close asynchronously; hide them as soon as they retire.
        // A window that gained another tab stays open with normal placement.
        if host.tabs.isEmpty {
            if window === captureWindow, !deferredCloseManagers.contains(where: { $0 === host }) {
                deferredCloseManagers.append(host)
            }
            restoreCollectionBehavior(of: window)
            withoutOrderingAnimation(of: window) { window.orderOut(nil) }
        } else {
            finalizeTornOffWindow(window, at: screenPoint)
            // The retained window stops following the cursor. Keep the
            // destination bar exposed for later pill-drag events.
            WindowRegistry.shared.bringToFront(for: resolution.tabManager)
        }

        adoptHost(resolution.tabManager)
        phase = .pill
        cachedDropEntry = nil

        // Update activeDrag so the new host's view hides the dragged tab
        // at its inserted position; insertion gap stays where the cursor
        // resolved.
        var next = drag
        next.sourceManagerID = ObjectIdentifier(resolution.tabManager)
        next.insertionTargetID = ObjectIdentifier(resolution.tabManager)
        next.insertionIndex = resolution.index
        activeDrag = next
    }

    /// Native ordering animations can make the next ordered-window query wait
    /// for their transition. Keep drag handoffs immediate without changing the
    /// window's behavior for later ordinary open/close operations.
    private func withoutOrderingAnimation(of window: NSWindow, _ operation: () -> Void) {
        let original = window.animationBehavior
        window.animationBehavior = .none
        defer { window.animationBehavior = original }
        operation()
    }

    // MARK: - Host Tracking

    private func adoptHost(_ tabManager: TabManager) {
        dragHost = tabManager
        if let handle = bars[ObjectIdentifier(tabManager)]?.handle {
            hostBarScreenRect = handle.screenFrame()
            hostWindowFrameSize = handle.window?.frame.size ?? hostWindowFrameSize
        }
    }

    // MARK: - Drop Resolution

    private struct Resolution {
        let tabManager: TabManager
        let index: Int
    }

    private func resolveDropTarget(at screenPoint: CGPoint) -> Resolution? {
        let tornOffWindow: NSWindow? = {
            if case .window(let w, _) = phase { return w }
            return nil
        }()

        // Native order can change without a mouse move. Resolve the first
        // input-receiving window before consulting the cached bar; its content
        // also occludes lower bars. The dragged window and preview are excluded.
        var frontWindow: NSWindow?
        NSApp.enumerateWindows(options: .orderedFrontToBack) { window, stop in
            guard window.isVisible, window !== tornOffWindow, !window.ignoresMouseEvents,
                  window.frame.contains(screenPoint) else { return }
            frontWindow = window
            stop.pointee = true
        }
        guard let frontWindow else {
            cachedDropEntry = nil
            return nil
        }

        let candidate: Entry?
        if let cached = cachedDropEntry, cached.handle?.window === frontWindow {
            candidate = cached
        } else {
            candidate = entry(for: frontWindow)
        }
        guard let candidate, let handle = candidate.handle,
              let manager = candidate.tabManager, canAcceptDrop(in: manager),
              handle.contains(screenPoint: screenPoint),
              let index = handle.dropIndex(for: screenPoint) else {
            cachedDropEntry = nil
            return nil
        }
        cachedDropEntry = candidate
        return Resolution(tabManager: manager, index: index)
    }

    private func canAcceptDrop(in manager: TabManager) -> Bool {
        !manager.tabs.isEmpty || deferredCloseManagers.contains { $0 === manager }
    }

    private func entry(for window: NSWindow) -> Entry? {
        for entry in bars.values {
            if entry.handle?.window === window {
                return entry
            }
        }
        return nil
    }

    // MARK: - Geometry

    /// A source window at or above this fraction of the visible frame (in both
    /// dimensions) counts as maximized — a tab torn off it opens at the default
    /// size instead of inheriting the full maximized size.
    static let tornOffMaximizedThreshold: CGFloat = 0.92

    /// Size for a torn-off window. Torn-off windows inherit the source window's
    /// size; but a tab dragged out of a (near-)maximized window should become a
    /// normal, movable window — not another maximized one (Chrome/Safari
    /// behavior) — so fall back to the default size when the source nearly fills
    /// the screen. Otherwise inherit the source size, clamped so it cannot be
    /// larger than the visible frame. `visibleFrame` nil (no resolvable screen)
    /// means inherit the source size unchanged. Pure (no `NSScreen` lookup) so
    /// it is unit-testable.
    static func tornOffWindowSize(_ source: NSSize, visibleFrame: NSSize?) -> NSSize {
        guard let visible = visibleFrame else { return source }
        let nearlyMaximized = source.width >= visible.width * tornOffMaximizedThreshold
            && source.height >= visible.height * tornOffMaximizedThreshold
        if nearlyMaximized {
            return NSSize(width: DesignTokens.defaultWindowWidth, height: DesignTokens.defaultWindowHeight)
        }
        return NSSize(
            width: min(source.width, visible.width),
            height: min(source.height, visible.height)
        )
    }

    /// Vertical distance from `point.y` to the host bar's vertical extent.
    /// 0 if the point's Y is inside the bar's vertical band.
    private func verticalDistanceFromHostBar(_ point: CGPoint) -> CGFloat {
        let rect = hostBarScreenRect
        guard !rect.isEmpty else { return .greatestFiniteMagnitude }
        if point.y >= rect.minY && point.y <= rect.maxY { return 0 }
        return min(abs(point.y - rect.minY), abs(point.y - rect.maxY))
    }

    /// Preserve the grabbed point when the tab becomes the first tab in a
    /// fresh window. Measure chrome insets instead of assuming its button widths.
    private func cursorToWindowOffset(
        for drag: ActiveDrag,
        in host: TabManager,
        windowHeight: CGFloat
    ) -> CGPoint {
        let handle = bars[ObjectIdentifier(host)]?.handle
        let windowFrame = handle?.window?.frame
        let barFrame = handle?.screenFrame()
        let tabFrame = handle?.tabScreenFrame(for: drag.tabID)
        let leftInset: CGFloat
        if let windowFrame, let barFrame, !barFrame.isEmpty {
            leftInset = barFrame.minX - windowFrame.minX + DesignTokens.spacingXS
        } else {
            leftInset = DesignTokens.tabBarLeftMargin + DesignTokens.spacingXS
        }
        let topInset: CGFloat
        if let windowFrame, let tabFrame, !tabFrame.isEmpty {
            topInset = windowFrame.maxY - tabFrame.maxY
        } else {
            topInset = DesignTokens.windowDragRegionHeight + DesignTokens.spacingXS
        }
        return CGPoint(
            x: -(leftInset + grabOffset.x),
            y: -(windowHeight - topInset - DesignTokens.tabHeight + grabOffset.y)
        )
    }

    // MARK: - Cleanup

    private func cleanup() {
        if case .window(let window, _) = phase { restoreCollectionBehavior(of: window) }
        removeEventMonitor()
        preview?.close()
        preview = nil
        dragHost = nil
        captureWindow = nil
        hostWindowFrameSize = .zero
        hostBarScreenRect = .zero
        grabOffset = .zero
        cachedDropEntry = nil
        phase = .pill
        popCursor()
        activeDrag = nil
        isActive = false
        flushDeferredCloses()
    }

    /// Closes any TabManager whose window we kept alive during the drag
    /// purely to preserve the implicit mouse-grab. If the user re-merged
    /// the tab back into one of these (so it's no longer empty), the
    /// window stays open.
    private func flushDeferredCloses() {
        let pending = deferredCloseManagers
        deferredCloseManagers.removeAll()
        for manager in pending where manager.tabs.isEmpty {
            WindowRegistry.shared.closeWindow(for: manager, onlyIfEmpty: true)
        }
    }

    // MARK: - Event Monitor

    private func installEventMonitor() {
        if eventMonitor == nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDragged, .leftMouseUp, .keyDown]
            ) { [weak self] event in
                self?.handleMonitoredEvent(event) ?? event
            }
        }
        if resignActiveObserver == nil {
            // Cancelling the drag one turn later is fine (see helper doc).
            resignActiveObserver = NotificationCenter.default.addMainActorObserver(
                forName: NSApplication.willResignActiveNotification
            ) { [weak self] in
                self?.cancelDrag()
            }
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }
    }

    private func handleMonitoredEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDragged:
            updateDrag(to: Self.screenPoint(forEvent: event))
            return event
        case .leftMouseUp:
            endDrag(at: Self.screenPoint(forEvent: event))
            return event
        case .keyDown where event.keyCode == 53:  // ESC
            cancelDrag(at: Self.screenPoint(forEvent: event))
            return nil  // consume so the keystroke doesn't leak through
        default:
            return event
        }
    }

    private static func screenPoint(forEvent event: NSEvent) -> CGPoint {
        guard event.type == .leftMouseDragged || event.type == .leftMouseUp else {
            return NSEvent.mouseLocation
        }
        // Queued events keep their original window-local position even if we
        // moved that window in the previous callback. The backing event's
        // global point preserves the drag/release location independently.
        if let location = event.cgEvent?.location, let primaryScreen = NSScreen.screens.first {
            return CGPoint(x: location.x, y: primaryScreen.frame.maxY - location.y)
        }
        if let eventWindow = event.window {
            return eventWindow.convertPoint(toScreen: event.locationInWindow)
        }
        return event.locationInWindow
    }

    // MARK: - Cursor

    private func pushCursor() {
        guard !cursorPushed else { return }
        NSCursor.closedHand.push()
        cursorPushed = true
    }

    private func popCursor() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }
}

// MARK: - Floating Preview Window

private final class TabDragPreviewWindow {
    private let panel: NSPanel
    private let grabOffset: CGPoint

    init(snapshot: TabDragPreviewSnapshot, grabOffset: CGPoint) {
        self.grabOffset = grabOffset
        let size = NSSize(width: snapshot.width, height: DesignTokens.tabHeight)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: TabDragPreviewView(snapshot: snapshot))
    }

    func show() {
        #if DEBUG
        guard !QAPresentation.runsInBackground else { return }
        #endif
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func move(to screenPoint: CGPoint) {
        let origin = CGPoint(
            x: screenPoint.x - grabOffset.x,
            y: screenPoint.y - grabOffset.y
        )
        panel.setFrameOrigin(origin)
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }
}
