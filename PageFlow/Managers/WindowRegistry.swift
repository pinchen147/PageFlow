//
//  WindowRegistry.swift
//  PageFlow
//
//  Tracks all (TabManager, NSWindow) pairs across the app for app-level
//  operations: routing Finder/open events, dirty-document quit prompts,
//  bringing windows to front, and dismissing transient placeholder windows
//  spawned by external open events.
//
//  Drag-and-drop state lives elsewhere — see `TabDragController`.
//

import AppKit
import Foundation
import Observation

/// A frozen snapshot of one open window's tabs for the cross-window Tab
/// Switcher: everything the dropdown renders (titles, active tab, dirty marks)
/// is captured at query time. `tabManager` is retained only as the *action*
/// handle for "jump to this tab".
struct WindowTabGroup: Identifiable {
    let tabManager: TabManager
    let window: NSWindow
    let tabs: [TabModel]
    let activeTabID: UUID?
    let dirtyTabIDs: Set<UUID>
    /// True for the window the user is currently working in (frontmost).
    let isFrontmost: Bool

    var id: ObjectIdentifier { ObjectIdentifier(tabManager) }
}

@MainActor
final class WindowRegistry {
    static let shared = WindowRegistry()

    private struct Entry {
        let tabManager: TabManager
        weak var window: NSWindow?
        let isUserCreated: Bool
        let registeredAt: Date
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var mainWindowObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    private var closeCoordinators: [ObjectIdentifier: WindowCloseCoordinator] = [:]
    private weak var lastActiveTabManager: TabManager?

    /// Holds a chosen destination until Save As publishes its committed identity.
    /// The weak source follows a transfer without retaining a retired document.
    @MainActor
    private final class PendingSaveAs {
        let token = UUID()
        weak var session: TabSession?
        weak var document: (any TabDocument)?
        weak var originalOwner: TabManager?
        var users = 1

        init(session: TabSession, owner: TabManager) {
            self.session = session
            self.document = session.content.document
            self.originalOwner = owner
        }
    }

    struct SaveAsClaim {
        fileprivate let canonicalURL: URL
        fileprivate let token: UUID
    }

    private var pendingSaveAs: [URL: PendingSaveAs] = [:]

    private var pendingTransientPlaceholderDismissals = 0
    private var transientPlaceholderDismissalLowerBound: Date?
    private var transientPlaceholderDismissalDeadline: Date?

    private init() {}

    // MARK: - Registration

    func register(_ tabManager: TabManager, window: NSWindow?) {
        if entries[ObjectIdentifier(tabManager)]?.window === window, window != nil { return }
        unregister(tabManager)
        entries[ObjectIdentifier(tabManager)] = Entry(
            tabManager: tabManager,
            window: window,
            isUserCreated: window?.identifier == PageFlowWindowIdentifiers.userCreated,
            registeredAt: Date()
        )
        if window?.isMainWindow == true {
            lastActiveTabManager = tabManager
        }

        if let window {
            closeCoordinators[ObjectIdentifier(tabManager)] = WindowCloseCoordinator(window: window, manager: tabManager)
            // One-turn-deferred front-most tracking is harmless (see helper doc).
            let token = NotificationCenter.default.addMainActorObserver(
                forName: NSWindow.didBecomeMainNotification,
                object: window
            ) { [weak self, weak tabManager] in
                guard let self, let tabManager else { return }
                self.lastActiveTabManager = tabManager
                self.publishActiveWindow()
            }
            mainWindowObservers[ObjectIdentifier(tabManager)] = token
        }

        publishActiveWindow()
        dismissPendingTransientPlaceholderWindows()

        // Deliver any URLs buffered during cold launch (before this TabManager existed).
        Task { @MainActor in
            guard let appDelegate = AppDelegate.shared else { return }
            appDelegate.flushPendingURLs(to: tabManager)
        }
    }

    func unregister(_ tabManager: TabManager) {
        closeCoordinators.removeValue(forKey: ObjectIdentifier(tabManager))?.detach()
        entries.removeValue(forKey: ObjectIdentifier(tabManager))
        if lastActiveTabManager === tabManager {
            lastActiveTabManager = nil
        }
        let token = mainWindowObservers.removeValue(forKey: ObjectIdentifier(tabManager))
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
        publishActiveWindow()
    }

    /// Native close is the commit point; Cancel never reaches this path.
    func finishClose(of tabManager: TabManager, window: NSWindow) {
        guard self.window(for: tabManager) === window else { return }
        tabManager.finishWindowClose()
        unregister(tabManager)
        if AppDelegate.shared?.terminationApproved != true { scheduleSessionSave() }
    }

    /// Mirrors the resolved frontmost manager onto `ActiveWindowModel`, the
    /// reactive surface SwiftUI menu `Commands` read so their action targets
    /// AND enabled state follow the frontmost window. A manually-created ⌘N /
    /// tear-off window holds no focused SwiftUI view, so `@FocusedValue` alone
    /// cannot route to it — commands resolve `focusedTabManager ?? frontmost`.
    private func publishActiveWindow() {
        ActiveWindowModel.shared.update(frontmostTabManager())
    }

    // MARK: - Lookups

    /// The window hosting this TabManager, if registered and still alive.
    /// Used by the edit-mode key monitor to scope app-wide key events to its
    /// own window.
    func window(for tabManager: TabManager) -> NSWindow? {
        entries[ObjectIdentifier(tabManager)]?.window
    }

    /// Content-agnostic dirty aggregation across every open window — the PDF +
    /// Markdown superset of the former `allDirtyPDFManagers()`, used by the quit
    /// save prompt (`applicationShouldTerminate`).
    /// Windows front to back (then in the order they opened), each in tab order,
    /// so the prompts follow what the user sees instead of dictionary order.
    func allDirtyDocuments() -> [DirtyDoc] {
        let stacking = NSApp.orderedWindows
        func rank(_ entry: Entry) -> Int {
            entry.window.flatMap { window in stacking.firstIndex { $0 === window } } ?? stacking.count
        }
        return entries.values
            .filter { $0.window != nil }
            .sorted { (rank($0), $0.registeredAt) < (rank($1), $1.registeredAt) }
            .flatMap { $0.tabManager.dirtyDocuments() }
    }

    /// Persists every open window's active-tab reading position to the store.
    /// Called on app termination so the last position survives a quit.
    func flushAllViewState() {
        for entry in entries.values where entry.window != nil {
            entry.tabManager.flushActiveTabViewState()
        }
    }

    /// Reconciles every open window's markdown editors into their durable text
    /// (fork P1) — the app-wide peer of `flushAllViewState`. Called at the TOP of
    /// `applicationShouldTerminate`, BEFORE `allDirtyDocuments()`, so a tab edited
    /// moments before ⌘Q is judged dirty on its live text rather than the engine's
    /// not-yet-drained ~1s deferred binding write (the quit data-loss fix).
    func flushAllEditors() {
        for entry in entries.values where entry.window != nil {
            entry.tabManager.flushMarkdownEditors()
        }
    }

    /// Lands every admitted save in every window before quit judges dirty state:
    /// approving termination must never cut a background write short.
    var hasPendingDocumentWrites: Bool {
        entries.values.contains { entry in
            entry.window != nil && entry.tabManager.hasPendingDocumentWrites
        }
    }

    func finishAllPendingWrites() {
        for entry in entries.values where entry.window != nil {
            for session in entry.tabManager.sessions.values {
                session.content.document.finishPendingWrites()
            }
        }
    }

    /// Approved quit must not resurrect drafts that the owner saved/discarded.
    func retireMarkdownRecoveryCopies() {
        for entry in entries.values where entry.window != nil {
            for session in entry.tabManager.sessions.values {
                session.content.markdown?.recoverySession?.retire()
            }
        }
        MarkdownRecoveryStore.shared.flush()
    }

    // MARK: - Session Restore (S8 P1)

    private var sessionSaveScheduled = false

    /// Coalesced persist of the app's file-backed tab layout. A burst of tab
    /// mutations (opening a document opens a tab AND stamps its identity, etc.)
    /// writes the store once, on the next main-runloop turn. A no-op under tests —
    /// the layout is a live-window concern and the test host registers none.
    func scheduleSessionSave() {
        guard !TestEnvironment.isRunningTests else { return }
        guard !sessionSaveScheduled else { return }
        sessionSaveScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sessionSaveScheduled = false
            guard AppDelegate.shared?.terminationApproved != true else { return }
            self.persistSessionNow()
        }
    }

    /// Synchronous capture + write. Used at quit (views still live) and by the
    /// coalesced schedule above.
    func persistSessionNow() {
        SessionRestoreStore.shared.save(captureSession())
    }

    /// The app's current file-backed session across every live window, in
    /// registration order. Untitled windows contribute nothing (`captureWindowSession`
    /// returns nil for an all-untitled window).
    func captureSession() -> SessionRestoreState {
        let windows = entries.values
            .filter { $0.window != nil }
            .sorted { $0.registeredAt < $1.registeredAt }
            .compactMap { $0.tabManager.captureWindowSession() }
        return SessionRestoreState(windows: windows)
    }

    /// TabManager whose window was most recently main. Stays correct even
    /// after Settings or another panel has stolen `keyWindow`/`mainWindow`.
    func frontmostTabManager() -> TabManager? {
        let tracked = lastActiveTabManager
        let values = entries.values.filter { $0.window != nil }

        if let tracked, values.contains(where: { $0.tabManager === tracked }) {
            return tracked
        }

        if let main = NSApp.mainWindow,
           let entry = values.first(where: { $0.window === main }) {
            return entry.tabManager
        }

        if let key = NSApp.keyWindow,
           let entry = values.first(where: { $0.window === key }) {
            return entry.tabManager
        }

        return values
            .sorted { $0.registeredAt > $1.registeredAt }
            .first?
            .tabManager
    }

    /// Any registered TabManager — used by Finder open routing.
    func anyTabManager() -> TabManager? {
        let values = entries.values.filter { $0.window != nil }
        return preferredEntry(from: values)?.tabManager
    }

    /// Whether `url`'s document is already open in any registered window. A
    /// read-only counterpart to `activateExistingDocument` — it never changes focus.
    func isDocumentOpen(_ url: URL) -> Bool {
        let canonicalURL = url.pageFlowCanonicalDocumentURL
        if pendingSaveAsOwner(for: canonicalURL) != nil { return true }
        for entry in entries.values where entry.window != nil {
            if entry.tabManager.tabID(for: canonicalURL) != nil { return true }
        }
        return false
    }

    /// A local-link continuation can await an open deduplicated into another window.
    func pendingMarkdownOpenTask(for url: URL) -> Task<Void, Never>? {
        for entry in entries.values where entry.window != nil {
            if let id = entry.tabManager.tabID(for: url),
               let request = entry.tabManager.sessions[id]?.pendingMarkdownOpen {
                return request.task
            }
        }
        return nil
    }

    /// Activates an existing tab for the given URL if already open. Returns
    /// `true` if handled (caller should not create a new tab/window).
    func activateExistingDocument(for url: URL, bringsToFront: Bool = true, pdfPageIndex: Int? = nil) -> Bool {
        let canonicalURL = url.pageFlowCanonicalDocumentURL
        if let (owner, session) = pendingSaveAsOwner(for: canonicalURL) {
            owner.selectTab(session.id)
            if let pdfPageIndex, let pdf = session.pdfManager, let sourceURL = pdf.documentURL {
                pdf.followPageLink(pdfPageIndex, for: sourceURL)
            }
            if bringsToFront { bringToFront(for: owner) }
            return true
        }
        let match: (TabManager, UUID, NSWindow?)? = {
            for entry in entries.values {
                guard let window = entry.window else { continue }
                if let tabID = entry.tabManager.tabID(for: canonicalURL) {
                    return (entry.tabManager, tabID, window)
                }
            }
            return nil
        }()

        guard let (tabManager, tabID, _) = match else { return false }
        if bringsToFront { activate(tabID, in: tabManager) }
        else { tabManager.selectTab(tabID) }
        tabManager.followPDFPageLink(pdfPageIndex, to: url)
        return true
    }

    /// Resolve exact content ownership again after a modal panel or window move.
    /// The fallback keeps the same boundary usable by a not-yet-hosted manager.
    func owner(of session: TabSession, document: any TabDocument, fallback: TabManager? = nil) -> TabManager? {
        guard session.content.document === document else { return nil }
        if let markdown = session.content.markdown, markdown.documentManager.isClosed { return nil }
        @MainActor func owns(_ manager: TabManager) -> Bool {
            manager.sessions[session.id] === session && manager.tabs.contains { $0.id == session.id }
        }
        if let fallback, owns(fallback) { return fallback }
        return entries.values.first { $0.window != nil && owns($0.tabManager) }?.tabManager
    }

    /// Canonical admission happens before either synchronous or asynchronous I/O.
    /// A conflicting destination only changes focus; neither draft is written.
    func claimSaveAs(to url: URL, session: TabSession, document: any TabDocument, owner: TabManager) -> SaveAsClaim? {
        guard self.owner(of: session, document: document, fallback: owner) === owner else { return nil }
        let canonicalURL = url.pageFlowCanonicalDocumentURL
        if let (existingOwner, existingSession) = pendingSaveAsOwner(for: canonicalURL),
           let pending = pendingSaveAs[canonicalURL] {
            guard existingSession === session else {
                existingOwner.selectTab(existingSession.id)
                bringToFront(for: existingOwner)
                return nil
            }
            pending.users += 1
            return SaveAsClaim(canonicalURL: canonicalURL, token: pending.token)
        }
        let managers = [owner] + entries.values.filter { $0.window != nil }.map(\.tabManager)
        for manager in managers {
            if let id = manager.tabID(for: canonicalURL), manager.sessions[id] !== session {
                manager.selectTab(id)
                bringToFront(for: manager)
                return nil
            }
        }
        let pending = PendingSaveAs(session: session, owner: owner)
        pendingSaveAs[canonicalURL] = pending
        return SaveAsClaim(canonicalURL: canonicalURL, token: pending.token)
    }

    func releaseSaveAs(_ claim: SaveAsClaim) {
        guard let pending = pendingSaveAs[claim.canonicalURL], pending.token == claim.token else { return }
        pending.users -= 1
        if pending.users == 0 { pendingSaveAs.removeValue(forKey: claim.canonicalURL) }
    }

    private func pendingSaveAsOwner(for canonicalURL: URL) -> (TabManager, TabSession)? {
        guard let pending = pendingSaveAs[canonicalURL] else { return nil }
        guard let session = pending.session, let document = pending.document,
              let owner = owner(of: session, document: document, fallback: pending.originalOwner) else {
            pendingSaveAs.removeValue(forKey: canonicalURL)
            return nil
        }
        return (owner, session)
    }

    // MARK: - Tab Switcher (cross-window)

    /// Every open window's tabs, frontmost window first. Dead (closed) windows
    /// are excluded. The Tab Switcher re-queries this each time it opens, so the
    /// list never goes stale.
    func allOpenTabs() -> [WindowTabGroup] {
        let frontmost = frontmostTabManager()
        return entries.values
            .filter { $0.window != nil }
            .sorted { lhs, rhs in
                // Frontmost window first, then most-recently-registered.
                if (lhs.tabManager === frontmost) != (rhs.tabManager === frontmost) {
                    return lhs.tabManager === frontmost
                }
                return lhs.registeredAt > rhs.registeredAt
            }
            .compactMap { entry in
                guard let window = entry.window else { return nil }
                let manager = entry.tabManager
                return WindowTabGroup(
                    tabManager: manager,
                    window: window,
                    tabs: manager.tabs,
                    activeTabID: manager.activeTabID,
                    dirtyTabIDs: Set(manager.tabs.lazy.filter { manager.isTabDirty($0.id) }.map(\.id)),
                    isFrontmost: manager === frontmost
                )
            }
    }

    /// Selects `tabID` in its window and brings that window to the front — the
    /// click-to-jump action for the Tab Switcher.
    func jumpToTab(_ tabID: UUID, in tabManager: TabManager) {
        activate(tabID, in: tabManager)
    }

    /// Archives every document-backed tab of `window` into Recently Closed.
    /// Window teardown (the red close button, or closing a multi-tab window)
    /// never routes through `TabManager.closeTab`, so the per-tab archival there
    /// would miss them. `ClosedTabStore.record` dedups by URL, so a tab already
    /// archived by a per-tab close stays single.
    func recordClosedTabs(forWindow window: NSWindow) {
        guard let entry = entries.values.first(where: { $0.window === window }) else { return }
        for tab in entry.tabManager.tabs {
            ClosedTabStore.shared.record(tab)
        }
    }

    // MARK: - Window Front/Close

    func closeWindow(for tabManager: TabManager, onlyIfEmpty: Bool = false) {
        scheduleWindowClose(for: tabManager) { !onlyIfEmpty || $0.tabs.isEmpty }
    }

    func closePlaceholderWindow(for tabManager: TabManager) {
        scheduleWindowClose(for: tabManager) { $0.hasOnlyPlaceholderTab }
    }

    /// A queued dismissal loses authority if its owner moves to another window
    /// or its empty/placeholder state changes before AppKit receives the close.
    private func scheduleWindowClose(
        for tabManager: TabManager, when shouldClose: @escaping @MainActor (TabManager) -> Bool
    ) {
        guard let window = self.window(for: tabManager) else { return }
        DispatchQueue.main.async { [weak self, weak tabManager, weak window] in
            guard let self, let tabManager, let window,
                  self.window(for: tabManager) === window, shouldClose(tabManager) else { return }
            window.close()
        }
    }

    func bringToFront(for tabManager: TabManager) {
        let window = entries[ObjectIdentifier(tabManager)]?.window
        bringWindowToFront(window)
    }

    /// The canonical "go to this tab" action: select it in its window and raise
    /// that window. Both `activateExistingDocument` (URL-resolved) and
    /// `jumpToTab` (direct) funnel through here, so the sequence lives once.
    private func activate(_ tabID: UUID, in tabManager: TabManager) {
        guard let window = entries[ObjectIdentifier(tabManager)]?.window else { return }
        tabManager.selectTab(tabID)
        bringWindowToFront(window)
    }

    private func bringWindowToFront(_ window: NSWindow?) {
        #if DEBUG
        if QAPresentation.runsInBackground {
            if let window { QAPresentation.show(window) }
            return
        }
        #endif
        // Raise the target window FIRST, so the opened document's first paint never
        // waits on app-level activation timing.
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        // DO NOT "modernize" this to the no-arg cooperative `NSApp.activate()`:
        // although `ignoringOtherApps:` is advisory-deprecated, on macOS 26 the
        // cooperative form is best-effort and is DROPPED right after a sandboxed
        // NSOpenPanel (powerbox) resigns key — deferring the SwiftUI redraw that
        // paints a freshly opened document by ~5s. `ignoringOtherApps: true` still
        // force-activates and drives that redraw immediately.
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Transient Placeholder Cleanup

    /// Closes one transient placeholder window created by an external open
    /// event that rerouted into an existing PageFlow window.
    func dismissTransientPlaceholderWindowForExternalOpen(within seconds: TimeInterval = 1.0) {
        let now = Date()
        pendingTransientPlaceholderDismissals = 1
        transientPlaceholderDismissalLowerBound = now.addingTimeInterval(-seconds)
        transientPlaceholderDismissalDeadline = now.addingTimeInterval(seconds)
        dismissPendingTransientPlaceholderWindows()
    }

    private func dismissPendingTransientPlaceholderWindows() {
        let tabManagers: [TabManager] = {
            pruneExpiredTransientPlaceholderDismissals()

            guard pendingTransientPlaceholderDismissals > 0,
                  let lowerBound = transientPlaceholderDismissalLowerBound else {
                return []
            }

            return entries.values
                .filter { $0.window != nil }
                .filter { !$0.isUserCreated }
                .filter { $0.registeredAt >= lowerBound }
                .sorted { $0.registeredAt > $1.registeredAt }
                .map(\.tabManager)
        }()

        for tabManager in tabManagers {
            if tabManager.dismissPlaceholderWindowIfNeeded() {
                pendingTransientPlaceholderDismissals = max(0, pendingTransientPlaceholderDismissals - 1)
                if pendingTransientPlaceholderDismissals == 0 {
                    transientPlaceholderDismissalLowerBound = nil
                    transientPlaceholderDismissalDeadline = nil
                }
                break
            }
        }
    }

    private func pruneExpiredTransientPlaceholderDismissals() {
        guard let deadline = transientPlaceholderDismissalDeadline,
              deadline < Date() else {
            return
        }

        pendingTransientPlaceholderDismissals = 0
        transientPlaceholderDismissalLowerBound = nil
        transientPlaceholderDismissalDeadline = nil
    }

    // MARK: - Helpers

    private func preferredEntry(from values: [Entry]) -> Entry? {
        if let keyWindow = NSApp.keyWindow,
           let keyEntry = values.first(where: { $0.window === keyWindow }) {
            return keyEntry
        }

        if let mainWindow = NSApp.mainWindow,
           let mainEntry = values.first(where: { $0.window === mainWindow }) {
            return mainEntry
        }

        return values.first
    }
}

/// Reactive projection of "which window is frontmost," kept in sync by
/// `WindowRegistry` (its single writer) on every register / unregister and
/// `didBecomeMain`. SwiftUI menu `Commands` read `tabManager` so they
/// re-evaluate when the main window changes; resolve it as
/// `focusedTabManager ?? ActiveWindowModel.shared.tabManager` so a command
/// still targets a manual (⌘N / tear-off) window that holds no focused view.
@MainActor
@Observable
final class ActiveWindowModel {
    static let shared = ActiveWindowModel()

    private(set) var tabManager: TabManager?

    private init() {}

    func update(_ tabManager: TabManager?) {
        // Skip a redundant Observation mutation when the frontmost is unchanged,
        // so menu Commands don't re-evaluate on every window-registry churn.
        guard self.tabManager !== tabManager else { return }
        self.tabManager = tabManager
    }
}
