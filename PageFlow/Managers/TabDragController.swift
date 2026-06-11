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
//  `.window` — tab has been torn off into a brand-new NSWindow whose
//              origin follows the cursor. The pill panel is gone. Hover
//              over any other bar re-merges: destroy the window, restore
//              the pill, resume `.pill` drag.
//
//  `dragHost` — the TabManager currently holding the dragged tab. Begin:
//  the source bar's manager. After tear-off: the new torn-off manager.
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
        /// Identifier of the manager currently holding the dragged tab.
        /// In `.pill` mode the tab is hidden (opacity 0) in this manager's
        /// bar; views key off this to know which slot to vacate. Updated
        /// on re-merge so the new host vacates the correct slot.
        var sourceManagerID: ObjectIdentifier
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
    }

    func unregisterBar(for tabManager: TabManager) {
        bars.removeValue(forKey: ObjectIdentifier(tabManager))
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
    /// Host bar rect in screen coords. Updated whenever `dragHost`
    /// changes so the tear-off threshold uses the correct anchor.
    private var hostBarScreenRect: CGRect = .zero
    /// Host window frame size. Inherited by torn-off windows.
    private var hostWindowFrameSize: NSSize = .zero
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
        screenPoint: CGPoint
    ) {
        // Defensive: if a previous drag was somehow not torn down, drop it.
        cleanup()

        adoptHost(tabManager)

        let preview = TabDragPreviewWindow(snapshot: snapshot)
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
        guard isActive, let drag = activeDrag else {
            cleanup()
            return
        }

        switch phase {
        case .pill:
            commitPillDrop(drag: drag, at: screenPoint)
        case .window(let window, _):
            finalizeTornOffWindow(window)
        }
        cleanup()
    }

    func cancelDrag() {
        // ESC during `.window`: drop the window where it is (option 5b).
        // Everywhere else cancel is a pure state reset.
        if case .window(let window, _) = phase {
            finalizeTornOffWindow(window)
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

    private func finalizeTornOffWindow(_ window: NSWindow) {
        window.collectionBehavior.remove(.canJoinAllSpaces)
    }

    // MARK: - Tear Off

    private func tearOff(at screenPoint: CGPoint, drag: ActiveDrag, host: TabManager) {
        guard let appDelegate = AppDelegate.shared else { return }

        let frameSize = hostWindowFrameSize == .zero
            ? NSSize(width: DesignTokens.defaultWindowWidth, height: DesignTokens.defaultWindowHeight)
            : hostWindowFrameSize

        let offset = Self.cursorToWindowOffset(
            draggedWidth: drag.draggedWidth,
            windowHeight: frameSize.height
        )
        let origin = CGPoint(
            x: screenPoint.x + offset.x,
            y: screenPoint.y + offset.y
        )
        let frame = NSRect(origin: origin, size: frameSize)

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

        guard let newWindow = appDelegate.createNewWindow(with: newTabManager, frame: frame) else {
            // Window creation failed — put the tab back where it came from so
            // it (and any unsaved edits) can't strand in an unanchored manager.
            _ = newTabManager.moveTab(drag.tabID, to: host, at: 0)
            return
        }
        newWindow.collectionBehavior.insert(.canJoinAllSpaces)

        preview?.close()
        preview = nil
        cachedDropEntry = nil

        adoptHost(newTabManager)
        // The tab is now visibly in the torn-off window — sourceManagerID
        // intentionally stays the original host so the new bar's view
        // doesn't try to render the tab as hidden.
        phase = .window(newWindow, cursorOffset: offset)
        clearInsertion(drag: drag)
    }

    // MARK: - Re-merge

    private func remerge(
        to screenPoint: CGPoint,
        drag: ActiveDrag,
        window: NSWindow,
        resolution: Resolution
    ) {
        guard let host = dragHost else { return }

        // Move tab from torn-off manager directly into the resolved
        // target. `select: false` so the target's active tab isn't
        // disturbed mid-drag. This also closes the torn-off window
        // (its only tab is now gone).
        guard host.moveTab(
            drag.tabID,
            to: resolution.tabManager,
            at: resolution.index,
            select: false
        ) else {
            return
        }

        // Rebuild pill UI for the next pill-phase pass.
        if let snapshot = makePreviewSnapshot(for: drag, in: resolution.tabManager) {
            let preview = TabDragPreviewWindow(snapshot: snapshot)
            preview.move(to: screenPoint)
            preview.show()
            self.preview = preview
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

    private func makePreviewSnapshot(
        for drag: ActiveDrag,
        in tabManager: TabManager
    ) -> TabDragPreviewSnapshot? {
        guard let tab = tabManager.tabs.first(where: { $0.id == drag.tabID }) else {
            return nil
        }
        return TabDragPreviewSnapshot(
            title: tab.displayTitle,
            isDirty: tabManager.isTabDirty(tab.id),
            width: drag.draggedWidth
        )
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

        // Fast path: still inside the bar we last hovered.
        if let cached = cachedDropEntry,
           let handle = cached.handle,
           let manager = cached.tabManager,
           handle.window !== tornOffWindow,
           !manager.tabs.isEmpty,
           handle.contains(screenPoint: screenPoint),
           let index = handle.dropIndex(for: screenPoint) {
            return Resolution(tabManager: manager, index: index)
        }

        // Otherwise walk windows in z-order; first matching bar wins.
        for window in NSApp.orderedWindows {
            if window === tornOffWindow { continue }
            guard window.frame.contains(screenPoint) else { continue }
            guard let entry = entry(for: window),
                  let handle = entry.handle,
                  let manager = entry.tabManager else {
                // Window matched (likely the dragging preview NSPanel or
                // some other non-bar window) but has no registered bar —
                // keep walking.
                continue
            }
            // Skip managers whose last tab was just detached — the window
            // is about to close but hasn't fully unregistered yet.
            if manager.tabs.isEmpty { continue }
            guard handle.contains(screenPoint: screenPoint),
                  let index = handle.dropIndex(for: screenPoint) else {
                continue
            }
            cachedDropEntry = entry
            return Resolution(tabManager: manager, index: index)
        }

        cachedDropEntry = nil
        return nil
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

    /// Vertical distance from `point.y` to the host bar's vertical extent.
    /// 0 if the point's Y is inside the bar's vertical band.
    private func verticalDistanceFromHostBar(_ point: CGPoint) -> CGFloat {
        let rect = hostBarScreenRect
        guard !rect.isEmpty else { return .greatestFiniteMagnitude }
        if point.y >= rect.minY && point.y <= rect.maxY { return 0 }
        return min(abs(point.y - rect.minY), abs(point.y - rect.maxY))
    }

    /// Offset from cursor to a torn-off window's origin such that the
    /// window's first tab pill sits directly under the cursor. Tab-bar
    /// geometry approximated from `TopChromeView` layout.
    private static func cursorToWindowOffset(
        draggedWidth: CGFloat,
        windowHeight: CGFloat
    ) -> CGPoint {
        let tabCenterX = DesignTokens.tabBarLeftMargin
            + DesignTokens.spacingXS
            + draggedWidth / 2
        let tabCenterYFromTop = DesignTokens.windowDragRegionHeight
            + DesignTokens.spacingXS
            + DesignTokens.tabHeight / 2
        return CGPoint(
            x: -tabCenterX,
            y: -(windowHeight - tabCenterYFromTop)
        )
    }

    // MARK: - Cleanup

    private func cleanup() {
        removeEventMonitor()
        preview?.close()
        preview = nil
        dragHost = nil
        hostWindowFrameSize = .zero
        hostBarScreenRect = .zero
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
            WindowRegistry.shared.closeWindow(for: manager)
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
            cancelDrag()
            return nil  // consume so the keystroke doesn't leak through
        default:
            return event
        }
    }

    private static func screenPoint(forEvent event: NSEvent) -> CGPoint {
        if let eventWindow = event.window {
            return eventWindow.convertPoint(toScreen: event.locationInWindow)
        }
        return NSEvent.mouseLocation
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
    private static let cursorOffset = CGPoint(x: 0, y: 18)

    private let panel: NSPanel
    private let size: NSSize

    init(snapshot: TabDragPreviewSnapshot) {
        size = NSSize(width: snapshot.width, height: DesignTokens.tabHeight)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: TabDragPreviewView(snapshot: snapshot))
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func move(to screenPoint: CGPoint) {
        let origin = CGPoint(
            x: screenPoint.x - size.width / 2 + Self.cursorOffset.x,
            y: screenPoint.y - size.height / 2 - Self.cursorOffset.y
        )
        panel.setFrameOrigin(origin)
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }
}
