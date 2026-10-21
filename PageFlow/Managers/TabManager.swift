//
//  TabManager.swift
//  PageFlow
//
//  Per-window tab coordinator. Owns the tabs and one TabSession per tab; holds
//  window-singleton state (password sheet queue, edit-mode key monitor, open
//  panel, always-on-top). Per-tab state lives in TabSession.
//

import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os.log
import MarkdownEngine

@Observable
@MainActor
final class TabManager {
    deinit {
        if let monitor = editModeKeyMonitor {
            editModeMonitorRemove(monitor)
        }
        // Each TabSession removes its own undo observers on cleanup()/deinit, so
        // releasing `sessions` here is sufficient — no observer bookkeeping.
        #if DEBUG
        Swift.print("[deinit] TabManager")
        #endif
    }

    // MARK: - Properties

    var tabs: [TabModel] = []
    /// The tab on screen. Every change re-warms the set and re-arms the
    /// edit-mode key monitor.
    var activeTabID: UUID? {
        didSet {
            reconcileRenderedTabs()
            reconcileEditModeKeyMonitor()
            if activeTabID != oldValue { checkActiveMarkdownForExternalChange() }
        }
    }

    /// Tab ids whose views are kept warm so switching back is an instant show, not
    /// a rebuild — most-recently-active first, the active tab always at the head.
    /// Capped at `maxRenderedTabs`: beyond that the least-recently-active tab's
    /// view is torn down and rebuilt on next visit (Safari/Preview-style). The cap
    /// bounds both memory and the window-wide event monitors that would otherwise
    /// accumulate across a long multi-tab session.
    private(set) var renderedTabIDs: [UUID] = []

    /// Internal (not private) so tests assert against the real cap instead of
    /// mirroring the literal.
    static let maxRenderedTabs = 4

    /// Whether this window floats above other apps. Scoped per-window, not persisted.
    var isAlwaysOnTop: Bool = false

    /// Whether openable files are being dragged over this window's document:
    /// `TabContainerView` draws the one window-wide indicator from it, above
    /// the chrome. A Markdown editor's own report wins while a drag is over
    /// its text (doc 26 §9.1).
    var isFileDropHovering: Bool { editorFileDragShowsOverlay ?? isTabSurfaceDropHovering }

    /// Whether files are over a tab surface's SwiftUI drop target (`FileDropTarget`).
    var isTabSurfaceDropHovering = false

    /// A file drag over a Markdown editor's text: `true` for documents only
    /// (the overlay shows), `false` for images (the editor's drop line shows
    /// instead), nil when no file drag is over an editor.
    var editorFileDragShowsOverlay: Bool?

    /// Find presentation belongs to the window, including manually created windows.
    var showingSearch = false {
        didSet {
            if oldValue && !showingSearch { clearAllSearchState() }
        }
    }
    var searchFocusRequest = 0

    /// The single source of truth for per-tab runtime state: one session per tab.
    var sessions: [UUID: TabSession] = [:]  // internal for cross-file decomposition (TabManager+*.swift)

    /// Observability seam (CEO/Eng review F8): a quiet `.debug` trace over the
    /// tab-lifecycle boundaries the upcoming `TabContent` refactor reshapes —
    /// session create/close, warm-set eviction, and tear-off move. Logging only,
    /// no behavior change; visible in Console.app under subsystem `com.pageflow`.
    let logger = Logger(subsystem: "com.pageflow", category: "TabManager")  // internal for cross-file decomposition (TabManager+*.swift)

    @ObservationIgnored var documentOpenedHandler: ((URL, Bool) -> Void)?

    // Edit mode keyboard shortcut monitor (intercepts Cmd+C/V for page copy/paste)
    @ObservationIgnored private var editModeKeyMonitor: Any?

    /// Seam for tests: a real NSEvent local monitor is app-wide test-host state
    /// (exactly what the test-host hazard implicates), so tests inject recorders
    /// here instead of letting the reconcile install the real thing.
    @ObservationIgnored var editModeMonitorInstall: (@escaping (NSEvent) -> NSEvent?) -> Any? = { handler in
        NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
    }
    @ObservationIgnored var editModeMonitorRemove: (Any) -> Void = { monitor in
        NSEvent.removeMonitor(monitor)
    }

    // Track open file picker panel for closing on drag-drop
    private weak var openPanel: NSOpenPanel?

    // Password sheet presentation (window-level). The unlock payload lives on
    // each TabSession; this is the FIFO order of tab ids waiting for the single
    // sheet — the head is the request currently presented.
    var unlockQueue: [UUID] = []  // internal for cross-file decomposition (TabManager+*.swift)

    /// The movable unit when a tab is torn off or merged: the tab model plus its
    /// session (which carries managers, undo history, UI state, and pending
    /// unlock together).
    struct DetachedTab {
        let tab: TabModel
        let session: TabSession
    }

    // MARK: - Computed Properties

    var activeTab: TabModel? {
        guard let id = activeTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    var activeTabIndex: Int? {
        guard let id = activeTabID else { return nil }
        return tabs.firstIndex { $0.id == id }
    }

    var activeSession: TabSession? {
        guard let id = activeTabID else { return nil }
        return sessions[id]
    }

    var activePDFManager: PDFManager? { activeSession?.pdfManager }

    var activeSearchManager: SearchManager? { activeSession?.searchManager }

    /// The active tab's Markdown backend, if it is a Markdown tab — the handle the
    /// shared toolbar's format buttons and the Format menu post requests through.
    var activeMarkdownContent: MarkdownContent? { activeSession?.content.markdown }

    var activeAnnotationManager: AnnotationManager? { activeSession?.annotationManager }

    var activeCommentManager: CommentManager? { activeSession?.commentManager }

    var activeBookmarkManager: BookmarkManager? { activeSession?.bookmarkManager }

    var activeRuntime: TabRuntime? {
        guard let id = activeTabID,
              case .pdf(let runtime)? = renderModel(for: id) else { return nil }
        return runtime
    }

    /// Content-agnostic render projection for the active tab — the same `TabRender`
    /// the window's mount sites switch over, so content-routed chrome (the shared
    /// toolbar slot) dispatches through the one routing authority instead of by a
    /// nil-proxy chain. `nil` when no tab is active.
    var activeRender: TabRender? {
        activeTabID.flatMap(renderModel)
    }

    /// The PDF runtimes this window keeps mounted, active-first — a filter over the
    /// canonical `renderedTabs` render projection. A just-closed tab whose session
    /// is gone is already absent from `renderedTabs`, so it drops out here too.
    var renderedRuntimes: [TabRuntime] {
        pdfRuntimes(in: renderedTabs)
    }

    /// The PDF runtimes within a content-discriminated render list, order preserved.
    /// The single filter both PDF-only projections compose, so there is one
    /// warm/displayed projection and the PDF list is derived from it.
    private func pdfRuntimes(in renders: [TabRender]) -> [TabRuntime] {
        renders.compactMap { render in
            if case .pdf(let runtime) = render { return runtime }
            return nil
        }
    }

    // MARK: - Content-discriminated render projections (the view-layer iteration)

    /// The warm set as content-discriminated render units, active-first — the
    /// list the single-pane ZStack mounts. PDF and Markdown tabs coexist here;
    /// each routes to its own view via `TabRender`.
    var renderedTabs: [TabRender] {
        renderedTabIDs.compactMap(renderModel)
    }

    /// Projects a tab id onto the render unit for its content, or nil if the
    /// session is gone (a just-closed tab still lingering in an id list).
    private func renderModel(for tabID: UUID) -> TabRender? {
        guard let session = sessions[tabID] else { return nil }
        switch session.content {
        case .pdf:
            return .pdf(runtime(for: session))
        case .markdown(let content):
            return .markdown(MarkdownRuntime(tabID: tabID, content: content))
        }
    }

    private func reconcileRenderedTabs() {
        guard let id = activeTabID else {
            renderedTabIDs.removeAll()
            return
        }
        touchRenderedTab(id)
    }

    /// Promotes `id` to the warm set's head and evicts past the cap. Called when
    /// the active tab changes or an already-warm native editor enters the window.
    private func touchRenderedTab(_ id: UUID?) {
        guard let id else { return }
        renderedTabIDs.removeAll { $0 == id }
        renderedTabIDs.insert(id, at: 0)
        if renderedTabIDs.count > Self.maxRenderedTabs {
            // Re-arm each evicted tab's exact-scroll restore while its live view
            // still exists. The switch-away one-shot was already consumed by the
            // warm (still-mounted) view; without re-arming, the evicted tab's
            // rebuilt view falls back to scroll-to-top and then persists that
            // wrong position over the user's real one.
            let evicted = Array(renderedTabIDs[Self.maxRenderedTabs...])
            for evictedID in evicted {
                guard let session = sessions[evictedID] else { continue }
                switch session.content {
                case .pdf(let c): _ = c.pdfManager.captureViewState()
                case .markdown(let c):
                    // Detach editors with native undo history; pristine editors
                    // can release their surface entirely.
                    c.evictEditorSurface()
                }
            }
            logger.debug("warmset.evict count=\(evicted.count, privacy: .public) cap=\(Self.maxRenderedTabs, privacy: .public)")
            renderedTabIDs.removeLast(renderedTabIDs.count - Self.maxRenderedTabs)
        }
    }

    /// A hover merge can keep the incoming editor inactive. Count its retained
    /// surface in this window's LRU so cancellation cannot bypass the warm cap.
    func retainTransferredEditor(_ tabID: UUID) {
        guard sessions[tabID]?.content.markdown?.retainedEditorSurface != nil,
              !renderedTabIDs.contains(tabID) else { return }
        touchRenderedTab(tabID)
        touchRenderedTab(activeTabID)
    }

    /// Drops a closed/torn-off tab from the warm set so its view tears down.
    func dropRenderedTab(_ id: UUID) {
        renderedTabIDs.removeAll { $0 == id }
    }

    var activeUndoManager: UndoManager? { activeSession?.undoManager }

    var activeCanUndo: Bool { activeSession?.undoAvailability.canUndo ?? false }

    var activeCanRedo: Bool { activeSession?.undoAvailability.canRedo ?? false }

    // MARK: - UI State (Active Tab)

    var showingOutline: Bool {
        get {
            guard let id = activeTabID else { return false }
            return showingOutline(for: id)
        }
        set {
            guard let id = activeTabID else { return }
            setShowingOutline(newValue, for: id)
        }
    }

    var showingComments: Bool {
        get {
            guard let id = activeTabID else { return false }
            return showingComments(for: id)
        }
        set {
            guard let id = activeTabID else { return }
            setShowingComments(newValue, for: id)
        }
    }

    var showingGoToPage: Bool {
        get {
            guard let id = activeTabID else { return false }
            return showingGoToPage(for: id)
        }
        set {
            guard let id = activeTabID else { return }
            setShowingGoToPage(newValue, for: id)
        }
    }

    var isEditingPages: Bool {
        get {
            guard let id = activeTabID else { return false }
            return isEditingPages(for: id)
        }
        set {
            guard let id = activeTabID else { return }
            setIsEditingPages(newValue, for: id)
        }
    }

    /// The tab's content kind for the tab pills — this window's tab strip
    /// (`TabItemView`) and the cross-window tab switcher — the same
    /// `TabSession.content` discriminator every mount site routes on, never a
    /// URL-extension sniff. `nil` for an unknown id (a just-closed tab still
    /// lingering in a strip); callers coalesce to `.pdf` for the legacy look.
    func contentKind(for tabID: UUID) -> ContentKind? {
        sessions[tabID]?.contentKind
    }

    func showingOutline(for tabID: UUID) -> Bool {
        sessions[tabID]?.uiState.showingOutline ?? false
    }

    func showingComments(for tabID: UUID) -> Bool {
        sessions[tabID]?.uiState.showingComments ?? false
    }

    func showingGoToPage(for tabID: UUID) -> Bool {
        sessions[tabID]?.uiState.showingGoToPage ?? false
    }

    func isEditingPages(for tabID: UUID) -> Bool {
        sessions[tabID]?.uiState.isEditingPages ?? false
    }

    func setShowingOutline(_ value: Bool, for tabID: UUID) {
        sessions[tabID]?.uiState.showingOutline = value
    }

    func setShowingComments(_ value: Bool, for tabID: UUID) {
        sessions[tabID]?.uiState.showingComments = value
    }

    func setShowingGoToPage(_ value: Bool, for tabID: UUID) {
        sessions[tabID]?.uiState.showingGoToPage = value
    }

    func setIsEditingPages(_ value: Bool, for tabID: UUID) {
        guard let session = sessions[tabID] else { return }
        session.uiState.isEditingPages = value
        reconcileEditModeKeyMonitor()
    }

    /// Opens NSOpenPanel as a sheet on this manager's registered window.
    func openFilePicker() {
        // Test host: an NSOpenPanel here blocks the main actor that all
        // @MainActor tests need, stalling the suite (see TestEnvironment).
        guard !TestEnvironment.isRunningTests else { return }
        // Prevent duplicate panels (concurrent onAppear calls, retry chains, etc.)
        guard openPanel == nil else { return }

        let panel = NSOpenPanel()
        // PDF plus Markdown — the file kinds the open path routes to a tab. The
        // markdown extensions come from the single shared list so they can't drift
        // from the open gate / content router. `UTType(filenameExtension:)` can be
        // nil on a system without the type registered, so absent types are dropped.
        panel.allowedContentTypes = [.pdf] + URL.pageFlowMarkdownExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Select a PDF or Markdown file to open"

        openPanel = panel  // Set immediately to block concurrent calls
        presentOpenPanel(panel, retryCount: 0)
    }

    private func presentOpenPanel(_ panel: NSOpenPanel, retryCount: Int) {
        // Bail out if closeFilePicker() was called during retry loop
        guard openPanel === panel else { return }

        guard let window = WindowRegistry.shared.window(for: self), window.isVisible else {
            guard retryCount < DesignTokens.maxReadinessRetries else {
                openPanel = nil  // Give up — clean up sentinel
                return
            }
            // Delay: window may not be ready yet during app launch or new window creation
            DispatchQueue.main.asyncAfter(deadline: .now() + DesignTokens.pdfViewReadyRetryInterval) { [weak self] in
                self?.presentOpenPanel(panel, retryCount: retryCount + 1)
            }
            return
        }

        panel.beginSheetModal(for: window) { [weak self] response in
            self?.openPanel = nil
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                self?.openDocument(url: url, isSecurityScoped: true, replaceCurrent: false)
            }
        }
    }

    /// Closes any open file picker panel
    func closeFilePicker() {
        openPanel?.close()
        openPanel = nil
    }

    /// Content-agnostic dirty aggregation — the `DirtyDoc` handle set the unified
    /// quit/close save flow iterates; clean tabs are excluded. `isDirty` and the
    /// save recipe are the content's own (`TabDocument`), so this doesn't branch.
    /// Tab-strip order, so a quit walks a window's documents as they appear.
    func dirtyDocuments() -> [DirtyDoc] {
        tabs.compactMap { sessions[$0.id] }.compactMap { session -> DirtyDoc? in
            session.isDirty ? DirtyDoc(session: session, owner: self) : nil
        }
    }

    /// Reconciles every markdown tab's live editor text into its durable document
    /// (fork P1) BEFORE the dirty/content gates are consulted — the quit-time peer
    /// of the per-open reconcile in `openDocument`. Called from
    /// `WindowRegistry.flushAllEditors()` at the top of `applicationShouldTerminate`
    /// so `dirtyDocuments()`/`allDirtyDocuments()` see the trailing keystroke that
    /// the engine's ~1s deferred binding write would otherwise still be holding.
    func flushMarkdownEditors() {
        for session in sessions.values {
            guard let content = session.content.markdown else { continue }
            content.reconcileLiveText()
            // A vanished backing file makes the tab unsaved, so quit and window
            // close offer to write it back instead of dropping the only copy.
            content.documentManager.noteMissingBackingFile()
        }
    }

    var hasMultipleTabs: Bool {
        tabs.count > 1
    }

    var tabCount: Int {
        tabs.count
    }

    // MARK: - Initialization

    init(createInitialTab: Bool = true) {
        // `createInitialTab: false` is for tear-off — caller will attach the
        // detached tab immediately so the new window opens with state already
        // in place.
        guard createInitialTab else { return }

        let initialTab = TabModel()
        tabs = [initialTab]
        activeTabID = initialTab.id
        createSession(for: initialTab)
    }

    /// This window's restorable session (S8 P1): the ordered canonical paths of its
    /// file-backed tabs plus which one is active, or `nil` when the window has no
    /// file-backed tab (a lone untitled buffer). Untitled tabs are excluded — they
    /// have no on-disk source to reopen from (ADR-0012 D7).
    func captureWindowSession() -> WindowSessionState? {
        let orderedTabs: [RestoreTab?] = tabs.map { restoreTab(for: $0) }
        let activeListIndex = activeTabID.flatMap { id in tabs.firstIndex { $0.id == id } }
        return WindowSessionState.capturing(orderedTabs: orderedTabs, activeListIndex: activeListIndex)
    }

    /// The persisted restore entry for one tab, or `nil` for an untitled/URL-less
    /// tab (nothing to reopen). The reopen source is a security-scoped bookmark so
    /// the sandboxed build can read the file next launch; the chain (ADR-0012 D7):
    /// the tab content's own bookmark → else one minted from the live document URL
    /// (works for a still-accessible user-selected file, matching RecentFilesManager)
    /// → else `nil` (non-sandboxed build), where the canonical path is the fallback.
    private func restoreTab(for tab: TabModel) -> RestoreTab? {
        guard let url = tab.documentURL ?? sessions[tab.id]?.pendingMarkdownOpen?.url else { return nil }
        let path = url.pageFlowCanonicalDocumentURL.path
        let bookmark = sessions[tab.id]?.restoreBookmark
            ?? sessions[tab.id]?.pendingMarkdownOpen?.access.securityScopedBookmark
            ?? mintedRestoreBookmark(for: url, path: path)
        return RestoreTab(path: path, bookmark: bookmark)
    }

    /// Minting is an XPC round trip and a session save runs on every tab change,
    /// so each file's fallback bookmark is minted once per window.
    private func mintedRestoreBookmark(for url: URL, path: String) -> Data? {
        if let minted = mintedRestoreBookmarks[path] { return minted }
        let bookmark = url.pageFlowSecurityScopedBookmark
        mintedRestoreBookmarks[path] = bookmark
        return bookmark
    }

    /// The engine `documentId`s of this window's warm (mounted) markdown tabs — the
    /// retained set the editors receive so each keeps its scroll across a switch
    /// (S8 P2). A content's `documentId` is per load (`TabSession.markdown(id:)`).
    var renderedDocumentIds: Set<String> {
        Set(renderedTabIDs.compactMap { sessions[$0]?.content.markdown?.documentId })
    }

    /// Notifies the app-wide session store that this window's file-backed tab set
    /// or order changed (S8 P1). Coalesced + test-gated inside the registry.
    func scheduleSessionSave() {
        WindowRegistry.shared.scheduleSessionSave()
    }

    /// Returns the tab ID if this TabManager has a tab with the given URL open.
    func tabID(for url: URL) -> UUID? {
        let canonicalURL = url.pageFlowCanonicalDocumentURL

        if let tabID = tabAwaitingPassword(for: canonicalURL) {
            return tabID
        }

        return tabs.first {
            $0.documentURL?.pageFlowCanonicalDocumentURL == canonicalURL ||
                sessions[$0.id]?.pendingMarkdownOpen?.url.pageFlowCanonicalDocumentURL == canonicalURL
        }?.id
    }

    // MARK: - Tab Operations

    @ObservationIgnored var pendingTabCloses: [UUID: Task<Void, Never>] = [:]

    func closeTab(_ tabID: UUID, using prompt: DocumentClosePrompt? = nil) {
        guard pendingTabCloses[tabID] == nil, tabs.contains(where: { $0.id == tabID }),
              let session = sessions[tabID] else { return }
        session.content.markdown?.reconcileLiveText()
        session.content.markdown?.documentManager.noteMissingBackingFile()
        if session.content.document.isDirty || session.content.document.hasPendingWrites {
            beginClosingTab(session, using: prompt)
            return
        }
        finishClosingTab(tabID)
    }

    /// Called immediately after approval; no suspension separates its final
    /// identity/source check from removing the tab.
    func finishClosingTab(_ tabID: UUID) {
        // A modal prompt may run queued tab mutations; resolve the index again.
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }

        // Archive into the Recently Closed history (Tab Switcher) before teardown.
        // Placed after the dirty-confirm guard so a cancelled close isn't recorded;
        // URL-less tabs are ignored by the store (nothing to reopen).
        ClosedTabStore.shared.record(tabs[index])

        // Capture the closing tab's reading position before teardown, but only
        // when it's the active tab (its live view still exists for an exact scroll
        // point); background tabs were already persisted when switched away from.
        // Content-routed: the SAME chokepoint as switch-away and quit.
        if activeTabID == tabID, let session = sessions[tabID] {
            persistReadingState(of: session)
        }

        let fallbackTabID = fallbackTabIDAfterClosing(tabID, at: index)

        // closeSession() performs the ordered teardown (close document, clear
        // markup, drop undo history + observers) before dropping the session.
        closeSession(for: tabID)
        tabs.remove(at: index)

        // Handle tab selection after close
        if tabs.isEmpty {
            activeTabID = nil
            WindowRegistry.shared.closeWindow(for: self, onlyIfEmpty: true)
        } else if activeTabID == tabID {
            activeTabID = fallbackTabID
        }

        // Closing a background tab leaves activeTabID unchanged (no didSet), so
        // reconcile here too; idempotent when the didSet already ran.
        reconcileEditModeKeyMonitor()

        // The window's file-backed tab set shrank — refresh the restore store (S8 P1).
        scheduleSessionSave()
    }

    func fallbackTabIDAfterClosing(_ tabID: UUID, at index: Int) -> UUID? {
        if let activeTabID, activeTabID != tabID {
            return activeTabID
        }

        let remainingCount = tabs.count - 1
        guard remainingCount > 0 else { return nil }
        let fallbackIndex = min(index, remainingCount - 1)
        return tabs[fallbackIndex >= index ? fallbackIndex + 1 : fallbackIndex].id
    }

    func closeActiveTab() {
        guard let id = activeTabID else { return }
        closeTab(id)
    }

    func selectTab(_ tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }),
              tabID != activeTabID else { return }

        // Exit edit mode before switching to ensure keyboard monitor stops
        if isEditingPages {
            isEditingPages = false
        }

        saveCurrentTabState()
        activeTabID = tabID
        restoreTabState(tabID)
    }

    func selectTabByIndex(_ index: Int) {
        let tabsCopy = tabs
        guard index >= 0, index < tabsCopy.count else { return }
        selectTab(tabsCopy[index].id)
    }

    func selectNextTab() {
        let tabsCopy = tabs
        let count = tabsCopy.count
        guard count > 0,
              let currentIndex = activeTabIndex,
              currentIndex < count else { return }
        let nextIndex = (currentIndex + 1) % count
        selectTab(tabsCopy[nextIndex].id)
    }

    func selectPreviousTab() {
        let tabsCopy = tabs
        let count = tabsCopy.count
        guard count > 0,
              let currentIndex = activeTabIndex,
              currentIndex < count else { return }
        let previousIndex = (currentIndex - 1 + count) % count
        selectTab(tabsCopy[previousIndex].id)
    }

    func moveTab(fromIndex: Int, toIndex: Int) {
        guard fromIndex >= 0, fromIndex < tabs.count,
              toIndex >= 0, toIndex <= tabs.count,
              fromIndex != toIndex else { return }

        let tab = tabs.remove(at: fromIndex)
        let adjustedIndex = toIndex > fromIndex ? toIndex - 1 : toIndex
        tabs.insert(tab, at: adjustedIndex)
        // Tab order is part of the restored session — persist the reorder (S8 P1).
        scheduleSessionSave()
    }

    /// In-bar reorder driven by drag commit. Looks up the source index from
    /// the tab id so callers don't have to track it themselves.
    func commitTabReorder(_ tabID: UUID, toIndex: Int) {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let clampedTarget = min(max(toIndex, 0), tabs.count)
        let adjustedTarget = clampedTarget > sourceIndex ? clampedTarget - 1 : clampedTarget
        guard adjustedTarget != sourceIndex else { return }
        moveTab(fromIndex: sourceIndex, toIndex: clampedTarget)
    }

    @discardableResult
    func moveTab(
        _ tabID: UUID,
        to destination: TabManager,
        at index: Int,
        select: Bool = true,
        closeIfEmpty: Bool = true
    ) -> Bool {
        guard destination !== self,
              let detachedTab = detachTab(tabID, closeIfEmpty: closeIfEmpty) else {
            return false
        }

        destination.attachDetachedTab(detachedTab, at: index, select: select)
        if select {
            WindowRegistry.shared.bringToFront(for: destination)
        }
        return true
    }

    // MARK: - Document Operations

    var isPlaceholderWindow: Bool {
        hasOnlyPlaceholderTab
    }

    var hasOnlyPlaceholderTab: Bool {
        guard tabs.count == 1,
              let activeTabID,
              let activeTab = activeTab,
              let pdf = sessions[activeTabID]?.content.pdf else {
            return false
        }

        // An untitled Markdown tab is a document even before its first edit.
        // Only the empty PDF-backed New Tab can be dismissed without approval,
        // and not while a password or a download is about to fill it.
        return !activeTab.hasDocument && !pdf.pdfManager.hasDocument &&
            !pdf.pdfManager.isDirty && !isAwaitingPassword(for: activeTabID) &&
            downloadingURLs.isEmpty && sessions[activeTabID]?.pendingMarkdownOpen == nil
    }

    func updateTabDocument(_ tabID: UUID, url: URL) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].documentURL = url
    }

    func clearAllSearchState() {
        for session in sessions.values {
            // Content-aware: clear the PDF backend (+ its snapshot) or the Markdown
            // Find backend (which posts findClearHighlights to drop highlights).
            // Exhaustive over `TabContent` so a new content type must define its
            // Find teardown rather than silently leaving stale highlights.
            switch session.content {
            case .pdf(let content):
                content.searchManager.clearSearch()
                content.clearSearchSnapshot()
            case .markdown(let content):
                content.searchManager.clear()
            }
        }
    }

    private func runtime(for session: TabSession) -> TabRuntime {
        // Builds the PDF runtime only — the single PDF-runtime construction path.
        // Content routing happens upstream: `renderModel(for:)` is the sole caller
        // and invokes this exclusively for `.pdf` sessions, projecting a markdown
        // tab to a `MarkdownRuntime` instead. The guard pins that precondition
        // rather than force-unwrapping the optional manager accessors.
        guard let content = session.content.pdf else {
            preconditionFailure("runtime(for:) requires PDF content; markdown tabs use MarkdownRuntime")
        }
        return TabRuntime(
            tabID: session.id,
            pdfManager: content.pdfManager,
            searchManager: content.searchManager,
            annotationManager: content.annotationManager,
            commentManager: content.commentManager,
            bookmarkManager: content.bookmarkManager,
            undoManager: content.undoManager
        )
    }

    // MARK: - State Management

    func clearSearchState(for tabID: UUID) {
        guard let session = sessions[tabID] else { return }
        session.searchManager?.clearSearch()
        session.clearSearchSnapshot()
    }

    func saveCurrentTabState() {
        guard let id = activeTabID, let session = sessions[id] else { return }
        session.captureViewSnapshot()
        persistReadingState(of: session)
    }

    // MARK: - Reading-Position Persistence

    /// Persists the active tab's reading state to the shared store — page/zoom
    /// for PDF, scroll offset for Markdown. Safe to call at any lifecycle
    /// boundary (window close, quit).
    func flushActiveTabViewState() {
        guard let id = activeTabID, let session = sessions[id] else { return }
        persistReadingState(of: session)
    }

    /// Content-routed reading-state persistence — exhaustive, so a new content
    /// type must decide what it remembers across launches.
    private func persistReadingState(of session: TabSession) {
        switch session.content {
        case .pdf(let content):
            persistViewState(for: content.pdfManager)
        case .markdown(let content):
            content.persistReadingPosition()
        }
    }

    private func persistViewState(for pdfManager: PDFManager) {
        guard let url = pdfManager.documentURL,
              let state = pdfManager.captureViewState() else { return }
        DocumentStateStore.shared.save(state, for: url)
    }

    // MARK: - External-change reload (ADR-0012 D5, S9)

    /// Re-entrancy latch so a burst of activation notifications can't stack multiple
    /// external-change prompts for the same tab.
    @ObservationIgnored private var isPresentingExternalChangePrompt = false
    /// The Reload-vs-Keep alert; a seam so tests can answer it without a modal.
    @ObservationIgnored var externalChangePrompt: (_ title: String, _ isDirty: Bool) -> MarkdownExternalChangeChoice
        = presentMarkdownExternalChangePrompt
    /// The Keep Open-vs-Close alert for a deleted or moved file; a test seam too.
    @ObservationIgnored var missingFilePrompt: (_ title: String, _ isDirty: Bool) -> MarkdownMissingFileChoice
        = presentMarkdownMissingFilePrompt
    /// Asks before opening a note large enough to be slow; a test seam too.
    @ObservationIgnored var largeNoteOpenPrompt: (_ title: String, _ byteCount: Int) -> Bool
        = presentMarkdownLargeNotePrompt
    /// Whether a file's bytes live only with its cloud provider; a test seam too.
    @ObservationIgnored var isCloudOnly: (URL) -> Bool = \.pageFlowIsDataless
    /// Cloud-only files downloading before they open, so a repeated open waits.
    @ObservationIgnored var downloadingURLs: Set<URL> = []
    @ObservationIgnored var downloadingTasks: [URL: Task<Void, Never>] = [:]
    /// The newest drop owns automatic selection while cloud batches overlap.
    @ObservationIgnored var currentDropBatch: DroppedDocumentBatch?
    /// Latest explicit page reference while one download is in flight.
    @ObservationIgnored var downloadingPDFPageIndices: [URL: Int] = [:]
    /// Asks before a link opens a local file in its own app; a test seam too.
    @ObservationIgnored var localFileLinkPrompt: (_ fileName: String) -> Bool = presentMarkdownLocalFileLinkPrompt
    /// Asks before a save writes U+FFFD over damaged UTF-8 bytes; a test seam too.
    @ObservationIgnored var invalidUTF8SavePrompt: (_ title: String) -> Bool = presentMarkdownInvalidUTF8SavePrompt
    /// Fallback restore bookmarks by canonical path (see `restoreTab(for:)`).
    @ObservationIgnored private var mintedRestoreBookmarks: [String: Data?] = [:]
    /// Only the newest focus check may prompt; older reads finish and are dropped.
    @ObservationIgnored private var externalChangeCheckGeneration: UInt64 = 0

    @ObservationIgnored private var isExternalChangeCheckScheduled = false

    /// Coalesce selection changes and check the latest active session after the
    /// native host has updated. Defer modal work while another panel or drag owns input.
    private func scheduleMarkdownExternalChangeCheck(after delay: TimeInterval = 0) {
        guard !TestEnvironment.isRunningTests, !isPresentingExternalChangePrompt,
              !isExternalChangeCheckScheduled else { return }
        isExternalChangeCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.isExternalChangeCheckScheduled = false
            self.performMarkdownExternalChangeCheck()
        }
    }

    /// Application activation and tab selection share the same guarded decision.
    /// This is a focus-based check, not a continuous filesystem watcher.
    func checkActiveMarkdownForExternalChange() {
        scheduleMarkdownExternalChangeCheck()
    }

    /// Reads the disk off the main thread (a slow share or an iCloud download
    /// must never freeze a tab switch), then decides on main.
    private func performMarkdownExternalChangeCheck() {
        guard !TestEnvironment.isRunningTests, !isPresentingExternalChangePrompt,
              let session = activeSession, let content = session.content.markdown,
              WindowRegistry.shared.window(for: self)?.isVisible == true,
              // A save landing mid-read would look external; its receipt re-checks.
              !content.documentManager.hasPendingWrites, !content.isReloadingFromDisk,
              let probe = content.documentManager.diskProbe() else { return }
        externalChangeCheckGeneration &+= 1
        let generation = externalChangeCheckGeneration
        Task { [weak self] in
            let observation = await Task.detached(priority: .userInitiated) {
                MarkdownDocumentManager.observe(probe)
            }.value
            self?.finishMarkdownExternalChangeCheck(observation, probe: probe, session: session, generation: generation)
        }
    }

    private func finishMarkdownExternalChangeCheck(
        _ observation: MarkdownDocumentManager.DiskObservation,
        probe: MarkdownDocumentManager.DiskProbe,
        session: TabSession,
        generation: UInt64
    ) {
        guard generation == externalChangeCheckGeneration, !isPresentingExternalChangePrompt,
              activeSession === session, let content = session.content.markdown,
              !content.documentManager.hasPendingWrites else { return }
        guard !TabDragController.shared.isActive, NSApp.modalWindow == nil else {
            scheduleMarkdownExternalChangeCheck(after: 0.1)
            return
        }
        let change = content.documentManager.resolve(observation, for: probe)
        guard change != .unchanged else { return }
        isPresentingExternalChangePrompt = true
        defer {
            isPresentingExternalChangePrompt = false
            if activeSession !== session { scheduleMarkdownExternalChangeCheck() }
        }
        switch change {
        case .modified:
            let checked = MarkdownDocumentManager.DiskCheck(observation: observation, probe: probe)
            if let decision = MarkdownExternalChangeDecision(content: content, session: session, owner: self, checked: checked) {
                decision.applyAfterFocusPrompt()
            }
        case .missing: presentMissingFilePrompt(for: content, session: session)
        case .unchanged: break
        }
    }

    /// Keep Open leaves the tab unsaved so close and quit still ask, and Save
    /// writes the file back; Close closes it like ⌘W.
    private func presentMissingFilePrompt(for content: MarkdownContent, session: TabSession) {
        content.reconcileLiveText()
        let manager = content.documentManager
        let choice = missingFilePrompt(manager.documentTitle, manager.isDirty)
        guard activeSession === session, session.content.markdown === content, !manager.isClosed else { return }
        switch choice {
        case .keepOpen: manager.keepAfterMissingFile()
        case .close: closeTab(session.id)
        }
    }

    /// A file read with damaged UTF-8 bytes saves them as U+FFFD; ask once, before
    /// the first save. A saved file is valid UTF-8, so later saves never ask.
    func confirmReplacingInvalidUTF8(_ content: MarkdownContent) -> Bool {
        guard content.documentManager.hasInvalidUTF8 else { return true }
        return invalidUTF8SavePrompt(content.documentManager.documentTitle)
    }

    /// The activation check covers only the frontmost window's active tab, so a
    /// save re-reads the disk first and never writes over an unseen external
    /// change. Returns whether the save may write: Keep writes this version over
    /// the change; Reload leaves nothing to save; Cancel stops.
    func confirmSaveOverExternalChange(_ content: MarkdownContent, session: TabSession) -> Bool {
        guard !isPresentingExternalChangePrompt else { return false }
        let manager = content.documentManager
        guard let probe = manager.diskProbe() else { return !manager.isClosed }
        let observation = MarkdownDocumentManager.observe(probe)
        guard observation.hasReadableSourceOrMissingFile else { return false }
        let change = manager.resolve(observation, for: probe)
        if change == .missing { manager.keepAfterMissingFile() }
        guard change == .modified else { return true }
        isPresentingExternalChangePrompt = true
        defer { isPresentingExternalChangePrompt = false }
        selectTab(session.id)
        WindowRegistry.shared.bringToFront(for: self)
        let checked = MarkdownDocumentManager.DiskCheck(observation: observation, probe: probe)
        guard let decision = MarkdownExternalChangeDecision(content: content, session: session, owner: self, checked: checked) else {
            return false
        }
        return decision.applySynchronously()
    }

    /// Command Save and native close/quit observe disk off main, after earlier
    /// accepted writes. Explicit synchronous replacement boundaries remain separate.
    func confirmSaveOverExternalChangeInBackground(_ content: MarkdownContent, session: TabSession,
                                                  selectingForClose: Bool = false,
                                                  whileApproved: @escaping () -> Bool = { true }) async -> Bool {
        guard !Task.isCancelled, whileApproved() else { return false }
        let manager = content.documentManager
        guard let checked = await manager.observeDiskForSave(), !Task.isCancelled, whileApproved(),
              let owner = WindowRegistry.shared.owner(of: session, document: content, fallback: self) else { return false }
        guard checked.observation.hasReadableSourceOrMissingFile else {
            owner.postTransientToast("Couldn’t read “\(manager.documentTitle)”. Your edits are still open.")
            return false
        }
        content.reconcileLiveText()
        let change = manager.resolve(checked.observation, for: checked.probe)
        if change == .missing { manager.keepAfterMissingFile() }
        guard change == .modified else { return true }
        // A prompt must still refer to the displayed, exact document. Selecting
        // another tab during a slow check must not expose it to this overwrite.
        guard !owner.isPresentingExternalChangePrompt, selectingForClose || owner.activeSession === session else { return false }
        if selectingForClose {
            owner.selectTab(session.id)
            WindowRegistry.shared.bringToFront(for: owner)
        }
        owner.isPresentingExternalChangePrompt = true
        defer { owner.isPresentingExternalChangePrompt = false }
        guard let decision = MarkdownExternalChangeDecision(content: content, session: session, owner: owner, checked: checked, whileApproved: whileApproved) else {
            return false
        }
        return await decision.applyInBackground()
    }

    private func restoreTabState(_ tabID: UUID) {
        sessions[tabID]?.restoreViewSnapshot()
    }

    // MARK: - Dirty State

    func isTabDirty(_ tabID: UUID) -> Bool {
        sessions[tabID]?.isDirty ?? false
    }

    // MARK: - Save Operations

    enum SaveResult {
        case success(message: String)
        case cancelled
        case failure(message: String)
    }

    // MARK: - Transient toast (this window's pill)

    /// The latest transient pill event for THIS window. Typed + observable, so
    /// the overlay observes its own manager and multi-window scoping is
    /// structural — no notification bus, no sender filtering.
    private(set) var transientToast: TransientToast?

    /// Shows a transient pill in THIS window (see `TransientToastOverlay` —
    /// the fresh id re-triggers equal messages).
    func postTransientToast(_ message: String) {
        transientToast = TransientToast(id: UUID(), message: message)
    }

    // MARK: - Edit Mode Keyboard Monitor

    /// Maintains the invariant: the edit-mode key monitor is installed iff this
    /// window's active tab is in page-edit mode. Every path that changes either
    /// input funnels here — `activeTabID`'s `didSet` and `setIsEditingPages` —
    /// so call sites never start/stop the monitor themselves. Idempotent, and
    /// safe during init (no session yet resolves to "not editing").
    private func reconcileEditModeKeyMonitor() {
        let shouldBeInstalled = activeTabID.flatMap { sessions[$0]?.uiState.isEditingPages } ?? false
        if shouldBeInstalled, editModeKeyMonitor == nil {
            editModeKeyMonitor = editModeMonitorInstall { [weak self] event in
                self?.handleEditModeKeyEvent(event) ?? event
            }
        } else if !shouldBeInstalled, let monitor = editModeKeyMonitor {
            editModeKeyMonitor = nil
            editModeMonitorRemove(monitor)
        }
    }

    /// Handles one keyDown while edit mode is active. Returns nil to swallow
    /// the event, or the event unmodified to pass it down the monitor chain.
    private func handleEditModeKeyEvent(_ event: NSEvent) -> NSEvent? {
        // Local monitors are application-wide and chain in nondeterministic
        // order: without this guard, whichever window entered edit mode would
        // swallow Cmd+C/V typed in *other* windows (and their Edit-menu key
        // equivalents). Apple's documented scoping pattern: compare event.window.
        guard let window = WindowRegistry.shared.window(for: self),
              event.window === window else {
            return event
        }

        guard isEditingPages else { return event }

        // Don't intercept when text field/view is focused - let normal copy/paste work
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSTextView || responder is NSTextField {
            return event
        }

        // Check configured shortcuts for copy/cut/paste page operations
        let copyShortcut = ShortcutModel.current(for: "copyPage")
        let cutShortcut = ShortcutModel.current(for: "cutPage")
        let pasteShortcut = ShortcutModel.current(for: "pastePage")

        if copyShortcut.matches(event: event) {
            if let pdfManager = activePDFManager {
                pdfManager.copyPage(at: pdfManager.currentPageIndex)
            }
            return nil
        }

        if cutShortcut.matches(event: event) {
            if let pdfManager = activePDFManager,
               pdfManager.pageCount > 1 {
                pdfManager.cutPage(at: pdfManager.currentPageIndex)
            }
            return nil
        }

        if pasteShortcut.matches(event: event) {
            if let pdfManager = activePDFManager, pdfManager.canPaste {
                _ = pdfManager.pastePage(after: pdfManager.currentPageIndex)
            }
            return nil
        }

        // Enter/Return exits edit mode
        if event.keyCode == 36 {
            isEditingPages = false
            return nil
        }

        return event
    }
}
