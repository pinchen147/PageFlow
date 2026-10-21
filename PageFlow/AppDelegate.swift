//
//  AppDelegate.swift
//  PageFlow
//
//  Handles app-level termination prompts for unsaved documents.
//

import AppKit
import SwiftUI

enum PageFlowWindowIdentifiers {
    static let userCreated = NSUserInterfaceItemIdentifier("PageFlowUserCreatedWindow")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The adaptor instance. On macOS 26 SwiftUI installs its own proxy as
    /// `NSApp.delegate` and only forwards callbacks here, so
    /// `NSApp.delegate as? AppDelegate` returns nil — every call site must use
    /// this instead (verified by AppDelegateInstallTests).
    private(set) static weak var shared: AppDelegate?

    override init() {
        super.init()
        AppDelegate.shared = self
        let recentFiles = recentFilesManager
        windowContentBuilder = { tabManager in
            AnyView(TabContainerView(tabManager: tabManager).environment(recentFiles))
        }
    }

    struct PendingDocumentOpen {
        let url: URL
        let isSecurityScoped: Bool
    }

    private let firstLaunchManager = FirstLaunchManager()
    let recentFilesManager = RecentFilesManager()
    private var didFinishLaunching = false
    private var recoveryRestoreTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private(set) var terminationApproved = false
    private var windowControllers: [NSWindowController] = []
    private var windowCloseObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// Builds the SwiftUI root view for a new window, wrapping the passed-in
    /// (pre-populated) TabManager. Installed before any scene appears so a
    /// Finder launch can create its document window without a default scene.
    var windowContentBuilder: ((TabManager) -> AnyView)?

    /// URLs received before any TabManager registered (cold launch from Finder)
    private(set) var pendingDocumentOpens: [PendingDocumentOpen] = []

    /// The previous session's windows (S8 P1), buffered at launch and materialized
    /// UNIFORMLY once the window builder is installed (`flushPendingRestoreWindows`):
    /// each becomes a fresh pre-populated window honoring its `activeIndex`, and the
    /// leftover empty default WindowGroup window is reaped. Finder launch-opens stay
    /// in `pendingDocumentOpens` (the default window) and de-dup by canonical URL.
    private(set) var pendingRestoreWindows: [WindowSessionState] = []

    var pendingURLs: [URL] {
        pendingDocumentOpens.map(\.url)
    }

    func enqueuePendingURLs(_ urls: [URL], isSecurityScoped: Bool = false) {
        let documentURLs = urls
            .filter(\.pageFlowIsOpenableDocument)
            .map(\.pageFlowCanonicalDocumentURL)
        pendingDocumentOpens.append(contentsOf: documentURLs.map {
            PendingDocumentOpen(url: $0, isSecurityScoped: isSecurityScoped)
        })
    }

    /// Builds the chrome-less window that hosts `contentView`, without showing,
    /// positioning, or registering it (`createNewWindow` does that).
    ///
    /// The SwiftUI view is hosted as the window's `contentView` via `NSHostingView`
    /// (the WWDC23-blessed form), NOT by installing an `NSHostingController` as the
    /// window's `contentViewController`. A hosting controller keeps re-asserting its
    /// view to the FRONT of the theme frame — above the `NSTitlebarContainerView` —
    /// so opaque content paints over the native traffic-light buttons and they are
    /// invisible (the tear-off / ⌘N "no traffic lights" bug). An `NSHostingView`
    /// set as the content view stays BEHIND the titlebar like SwiftUI's own
    /// WindowGroup, AND bridges scene state (notably the focused values the ⌘T/⌘W
    /// menu commands read) to the window — which a nested hosting subview does not.
    /// `isReleasedWhenClosed` is false because the `NSWindowController` owns the
    /// window's lifetime (see `createNewWindow`).
    static func makeHostedWindow(contentView: some View, contentSize: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // Host the SwiftUI view directly AS the window's content view (WWDC23):
        // this is what bridges scene state — including focused values, which the
        // ⌘T/⌘W menu commands read via `.focusedSceneValue` — to a manually
        // created NSWindow. (A nested hosting subview does not bridge.)
        window.contentView = NSHostingView(rootView: contentView)
        // Canonical hidden-titlebar chrome (adds .fullSizeContentView). Applied
        // here at construction so the window never flashes a solid titlebar
        // before WindowChromeController installs via the SwiftUI content.
        WindowChromeController.applyHiddenTitlebarChrome(to: window)
        window.identifier = PageFlowWindowIdentifiers.userCreated
        return window
    }

    @discardableResult
    func createNewWindow(
        with contentView: some View,
        screenPoint: CGPoint? = nil,
        frame: NSRect? = nil,
        animatePresentation: Bool = true
    ) -> NSWindow {
        let contentSize = frame?.size
            ?? NSSize(width: DesignTokens.defaultWindowWidth, height: DesignTokens.defaultWindowHeight)

        let window = Self.makeHostedWindow(contentView: contentView, contentSize: contentSize)
        if let frame {
            window.setFrame(frame, display: false)
        } else {
            positionWindow(window, near: screenPoint)
        }

        let windowController = NSWindowController(window: window)
        windowControllers.append(windowController)
        let controllerID = ObjectIdentifier(windowController)

        // Clean up when window closes
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak windowController] notification in
            guard let self = self else { return }
            if let wc = windowController {
                self.windowControllers.removeAll { $0 === wc }
            }
            if let token = self.windowCloseObservers.removeValue(forKey: controllerID) {
                NotificationCenter.default.removeObserver(token)
            }
        }
        windowCloseObservers[controllerID] = observer

        // A dragged tab already supplies its own visual handoff. Avoid a
        // native order-in transition that later window-order queries must wait for.
        let originalAnimationBehavior = window.animationBehavior
        defer { window.animationBehavior = originalAnimationBehavior }
        if !animatePresentation { window.animationBehavior = .none }
        #if DEBUG
        if QAPresentation.runsInBackground { QAPresentation.show(window) }
        else { windowController.showWindow(nil) }
        #else
        windowController.showWindow(nil)
        #endif
        return window
    }

    /// Creates a window hosting the given (pre-populated) TabManager. Used
    /// by tear-off: caller detaches the tab into a fresh empty TabManager,
    /// then hands it to us so the window opens with the tab already in place.
    @discardableResult
    func createNewWindow(
        with tabManager: TabManager,
        screenPoint: CGPoint? = nil,
        frame: NSRect? = nil,
        animatePresentation: Bool = true
    ) -> NSWindow? {
        guard let builder = windowContentBuilder else {
            assertionFailure("windowContentBuilder not installed")
            return nil
        }
        return createNewWindow(with: builder(tabManager), screenPoint: screenPoint, frame: frame,
                               animatePresentation: animatePresentation)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        QAPresentation.prepare()
        #endif
        if !TestEnvironment.isRunningTests { firstLaunchManager.handleFirstLaunch() }
        ShortcutMenuRefresh.install()
        #if DEBUG
        RestoreOpenQA.prepareIfRequested(delegate: self)
        #endif
        restorePreviousSessionIfNeeded()
        didFinishLaunching = true
        openPendingDocumentWindowIfNeeded()
        flushPendingRestoreWindows()
        restoreUnsavedMarkdownCopies()
        #if DEBUG
        WindowCloseQA.startIfRequested()
        OpenDocumentQA.startIfRequested()
        QAReplay.startIfRequested()
        RecoveryQA.startIfRequested(delegate: self, recoveryTask: recoveryRestoreTask)
        #endif
    }

    private func restoreUnsavedMarkdownCopies() {
        guard !TestEnvironment.isRunningTests else { return }
        #if DEBUG
        if !RecoveryQA.isRequested, QAPresentation.runsInBackground || QAReplay.isRequested || WindowCloseQA.isRequested { return }
        #endif
        recoveryRestoreTask = Task { [weak self] in
            let records = await MarkdownRecoveryStore.shared.load()
            guard !Task.isCancelled, let self, !records.isEmpty, !self.terminationApproved else { return }
            let manager = TabManager()
            for record in records { manager.restoreRecoveredMarkdown(record) }
            guard let window = self.createNewWindow(with: manager) else { return }
            WindowRegistry.shared.register(manager, window: window)
            manager.postTransientToast("Recovered \(records.count) unsaved note(s). Save to keep these copies.")
            WindowRegistry.shared.dismissTransientPlaceholderWindowForExternalOpen()
        }
    }

    /// The v1 external-change hook (ADR-0012 D5, S9): when PageFlow returns to the
    /// foreground, check the frontmost window's active Markdown tab for an on-disk
    /// change and prompt Reload-vs-Keep. Catches the common "edit the file in another
    /// app, switch back" case; a change while PageFlow stays frontmost is caught on
    /// the next refocus. No-op in the test host (the check itself guards on that).
    func applicationDidBecomeActive(_ notification: Notification) {
        WindowRegistry.shared.frontmostTabManager()?.checkActiveMarkdownForExternalChange()
    }

    // MARK: - Session Restore (S8 P1)

    /// Buffers the previous session's windows on launch for uniform materialization
    /// by `flushPendingRestoreWindows` once the window builder is installed. No
    /// bare-path pre-filter here: each tab is reopened via its security-scoped
    /// bookmark, and the existence check must run INSIDE the resolved scope (a bare
    /// `fileExists` denies outside the sandbox container), so filtering is deferred
    /// to the per-tab resolve at materialization.
    private func restorePreviousSessionIfNeeded() {
        guard !TestEnvironment.isRunningTests else { return }
        #if DEBUG
        // A QA replay run measures one document from a clean window; the
        // previous session's tabs would only add noise to its numbers.
        if QAReplay.isRequested || WindowCloseQA.isRequested { return }
        #endif

        let saved = SessionRestoreStore.shared.load()
        guard !saved.isEmpty else { return }
        pendingRestoreWindows = saved.windows
    }

    /// A restore tab resolved to a live, in-scope URL, ready to hand to
    /// `openDocument`. `stopAccess()` releases the transient scope this resolve
    /// started for the existence check; the subsequent load re-acquires and holds
    /// its own, so the two start/stop pairs stay balanced.
    private struct ResolvedRestoreURL {
        let url: URL
        let isSecurityScoped: Bool
        let scopedURL: URL?
        func stopAccess() { scopedURL?.stopAccessingSecurityScopedResource() }
    }

    /// Resolves a persisted `RestoreTab` to a reopenable URL, mirroring
    /// `RecentFilesManager.resolveRecentFile`: resolve the security-scoped bookmark
    /// with `[.withSecurityScope, .withoutUI]`, start the scope, and confirm the
    /// file exists — the existence check performed INSIDE the started scope so it is
    /// valid outside the sandbox container. Returns `nil` (skip this tab) when the
    /// bookmark can't resolve or the file is gone. A stale bookmark self-heals: the
    /// reopened tab re-mints a fresh one on the next coalesced session save
    /// (`openDocument` → `scheduleSessionSave`), which rewrites the whole store, so
    /// no in-place refresh is needed at launch. Without a bookmark (non-sandboxed
    /// build) it falls back to the canonical path.
    private func resolveRestoreTab(_ tab: RestoreTab) -> ResolvedRestoreURL? {
        guard let bookmark = tab.bookmark else {
            let url = URL(fileURLWithPath: tab.path).pageFlowCanonicalDocumentURL
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return ResolvedRestoreURL(url: url, isSecurityScoped: false, scopedURL: nil)
        }

        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        let canonical = resolved.pageFlowCanonicalDocumentURL
        guard canonical.startAccessingSecurityScopedResource() else { return nil }
        guard FileManager.default.fileExists(atPath: canonical.path) else {
            canonical.stopAccessingSecurityScopedResource()
            return nil
        }
        return ResolvedRestoreURL(url: canonical, isSecurityScoped: true, scopedURL: canonical)
    }

    /// Materializes every buffered restore window UNIFORMLY (S8 P1, review M2/L2).
    /// Called after launch URLs have a registered destination. Each saved
    /// window opens its bookmark-resolved files into a fresh
    /// pre-populated `TabManager` (the tear-off pattern) and selects the saved
    /// active tab — the first window is no longer a special-cased path. A file that
    /// is already open elsewhere (e.g. a Finder launch-open in the default window)
    /// de-dups via `openDocument`, so it never lands twice; a window whose files all
    /// de-duped away spawns no stray empty window. When at least one window is built,
    /// the leftover empty default WindowGroup window is reaped. Idempotent: the
    /// buffer is drained on first call.
    func flushPendingRestoreWindows() {
        guard windowContentBuilder != nil, !pendingRestoreWindows.isEmpty else { return }
        let windows = pendingRestoreWindows
        pendingRestoreWindows = []

        var didCreateWindow = false
        for window in windows {
            if materializeRestoreWindow(window) { didCreateWindow = true }
        }

        // Reap the empty default WindowGroup window left behind by launch (a no-op
        // if it adopted a Finder launch-open and is no longer a placeholder). Reuses
        // the same deferred placeholder-dismissal machinery as an external open.
        if didCreateWindow {
            WindowRegistry.shared.dismissTransientPlaceholderWindowForExternalOpen()
        }
    }

    /// Builds one restore window; returns whether a window was actually created
    /// (false when every tab failed to resolve or de-duped into another window).
    private func materializeRestoreWindow(_ window: WindowSessionState) -> Bool {
        // Resolve each surviving tab exactly once; the pure `filteringReopenable`
        // remaps the active index across the skipped (unresolvable) tabs.
        var resolvedByPath: [String: ResolvedRestoreURL] = [:]
        guard let reopenable = window.filteringReopenable({ tab in
            guard let resolved = resolveRestoreTab(tab) else { return false }
            resolvedByPath[tab.path] = resolved
            return true
        }) else {
            return false
        }

        let tabManager = TabManager()
        // Restore reopens notes the user already chose to open, large or not.
        tabManager.largeNoteOpenPrompt = { _, _ in true }
        var activeURL: URL?
        for (index, tab) in reopenable.tabs.enumerated() {
            guard let resolved = resolvedByPath[tab.path] else { continue }
            tabManager.openDocument(url: resolved.url, isSecurityScoped: resolved.isSecurityScoped)
            if index == reopenable.activeIndex { activeURL = resolved.url }
            resolved.stopAccess()
        }

        // Every file de-duped into an already-open window → don't spawn an empty one.
        // A window whose files are still downloading isn't empty: it opens them
        // when they land, and without it they'd open nowhere.
        guard tabManager.captureWindowSession() != nil || !tabManager.downloadingURLs.isEmpty else { return false }

        // By file, not position: a tab that de-duped into another window is
        // missing here, which shifts every position after it.
        if let activeURL, let activeID = tabManager.tabID(for: activeURL) {
            tabManager.selectTab(activeID)
        }
        guard let nativeWindow = createNewWindow(with: tabManager) else { return false }
        WindowRegistry.shared.register(tabManager, window: nativeWindow)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let documentURLs = urls
            .filter(\.pageFlowIsOpenableDocument)
            .map(\.pageFlowCanonicalDocumentURL)
        guard !documentURLs.isEmpty else { return }

        var reroutedIntoExistingWindow = false

        // Activate existing tabs first so Finder/open-file events reuse the live document window
        // instead of leaving behind a transient empty SwiftUI placeholder window.
        for url in documentURLs {
            if WindowRegistry.shared.activateExistingDocument(for: url) {
                reroutedIntoExistingWindow = true
                continue
            }

            if let tabManager = WindowRegistry.shared.anyTabManager() {
                if !tabManager.isPlaceholderWindow {
                    reroutedIntoExistingWindow = true
                }
                tabManager.closeFilePicker()
                tabManager.openDocument(url: url, isSecurityScoped: false)
            } else {
                pendingDocumentOpens.append(
                    PendingDocumentOpen(url: url, isSecurityScoped: false)
                )
            }
        }

        if reroutedIntoExistingWindow {
            WindowRegistry.shared.dismissTransientPlaceholderWindowForExternalOpen()
        }
        openPendingDocumentWindowIfNeeded()
    }

    /// File launches can suppress SwiftUI's initial WindowGroup entirely.
    /// Register a hosted window before draining its queue so restore and later
    /// Finder events see the same document owner immediately.
    private func openPendingDocumentWindowIfNeeded() {
        guard didFinishLaunching, !pendingDocumentOpens.isEmpty else { return }
        if let manager = WindowRegistry.shared.anyTabManager() {
            flushPendingURLs(to: manager)
            return
        }
        let manager = TabManager()
        manager.documentOpenedHandler = { [recentFilesManager] url, isSecurityScoped in
            recentFilesManager.addRecentFile(url, isSecurityScoped: isSecurityScoped)
        }
        guard let window = createNewWindow(with: manager) else { return }
        WindowRegistry.shared.register(manager, window: window)
        flushPendingURLs(to: manager)
        WindowRegistry.shared.dismissTransientPlaceholderWindowForExternalOpen()
    }

    /// Delivers launch URLs only after this manager is visible to cross-window
    /// document deduplication. Registration retries any earlier appearance call.
    func flushPendingURLs(to tabManager: TabManager) {
        guard !pendingDocumentOpens.isEmpty,
              WindowRegistry.shared.window(for: tabManager) != nil else { return }
        tabManager.closeFilePicker()
        let pendingOpens = pendingDocumentOpens
        pendingDocumentOpens.removeAll()
        for pendingOpen in pendingOpens {
            tabManager.openDocument(url: pendingOpen.url, isSecurityScoped: pendingOpen.isSecurityScoped)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        WindowRegistry.shared.flushAllViewState()
        // Test host: never block termination behind the save prompt — a modal
        // alert in a headless host turns finished test runs into zombies.
        if TestEnvironment.isRunningTests { return approveTermination() }
        guard terminationTask == nil else { return .terminateLater }
        WindowRegistry.shared.flushAllEditors()
        let owners = WindowRegistry.shared.allOpenTabs().map(\.tabManager)
        guard owners.contains(where: { $0.needsCloseApproval }) else { return approveTermination() }
        terminationTask = Task { @MainActor [weak self] in
            guard let self else { sender.reply(toApplicationShouldTerminate: false); return }
            let owner = WindowRegistry.shared.frontmostTabManager() ?? WindowRegistry.shared.anyTabManager()
            let sheet = DocumentCloseWaitSheet(window: owner.flatMap { WindowRegistry.shared.window(for: $0) }, quitting: true) { [weak self] in
                self?.terminationTask?.cancel()
            }
            let result = await self.confirmTerminationInBackground()
            sheet.finish()
            self.terminationTask = nil
            sender.reply(toApplicationShouldTerminate: result == .terminateNow)
        }
        return .terminateLater
    }

    func confirmTermination(using prompt: DocumentClosePrompt? = nil) -> NSApplication.TerminateReply {
        terminationApproved = false
        // Reconcile every markdown editor's live text into its durable document
        // BEFORE the dirty gate reads it (fork P1) — the engine commits keystrokes
        // on a ~1s deferred binding write, so a tab edited just before ⌘Q would
        // otherwise be judged clean on stale `text` and quit with no prompt.
        WindowRegistry.shared.flushAllEditors()
        WindowRegistry.shared.finishAllPendingWrites()

        // Persist each window's reading position before we quit (views are still live).
        WindowRegistry.shared.flushAllViewState()

        let dirtyDocs = WindowRegistry.shared.allDirtyDocuments()

        guard let firstDirty = dirtyDocs.first else {
            return approveTermination()
        }

        var approval = TerminationApproval()
        let decision = prompt?.decide(firstDirty.title) ?? presentTerminationDecision(dirtyDocs)
        guard approval.matches() else { return .terminateCancel }
        switch decision {
        case .save:
            var failedTitles: [String] = []
            for doc in dirtyDocs {
                guard approval.matches() else { return .terminateCancel }
                var didSave = false
                if doc.needsSaveAs {
                    // A dirty untitled Markdown buffer: route to a synchronous
                    // Save-As panel. A cancelled panel cancels termination (the
                    // buffer is preserved unsaved) — never silently discarded.
                    // Untitled buffers look alike, so show whose panel this is.
                    doc.reveal()
                    switch runSyncSaveAs(for: doc, using: prompt, whileApproved: { approval.matches() },
                                         didAdoptImages: { approval.acceptImageAdoption(of: doc.tabID) }) {
                    case .saved: didSave = true
                    case .cancelled: return .terminateCancel
                    case .failed: failedTitles.append(doc.title)
                    }
                } else {
                    didSave = doc.saveSync(whileApproved: { approval.matches() })
                    if !didSave { failedTitles.append(doc.title) }
                }
                if didSave, !approval.acceptSave(of: doc.tabID) { return .terminateCancel }
                if !didSave, !approval.matches() { return .terminateCancel }
            }

            guard failedTitles.isEmpty else {
                showSaveFailureAlert(titles: failedTitles)
                return .terminateCancel
            }
            guard approval.matches(), WindowRegistry.shared.allDirtyDocuments().isEmpty else { return .terminateCancel }
            return approveTermination()
        case .discard:
            return approveTermination()
        default:
            return .terminateCancel
        }
    }

    /// Native quit uses the same source/membership approval as modal boundaries,
    /// but user-document writes and their barriers never wait on the UI actor.
    func confirmTerminationInBackground(using prompt: DocumentClosePrompt? = nil) async -> NSApplication.TerminateReply {
        terminationApproved = false
        let registry = WindowRegistry.shared
        registry.flushAllEditors()
        var approval = TerminationApproval()
        let groups = registry.allOpenTabs()
        for group in groups {
            for tab in group.tabs {
                guard !Task.isCancelled, approval.matchesInitialWrites(), let session = group.tabManager.sessions[tab.id] else { return .terminateCancel }
                if session.content.document.hasPendingWrites {
                    guard await DocumentCloseOperation.wait({ _ in await session.content.document.finishPendingWritesInBackground(); return true }) == true,
                          !Task.isCancelled else { return .terminateCancel }
                }
            }
        }
        guard !Task.isCancelled, !registry.hasPendingDocumentWrites, approval.acceptInitialWrites() else { return .terminateCancel }
        for group in groups {
            for tab in group.tabs {
                if let session = group.tabManager.sessions[tab.id] { group.tabManager.publishSavedDocumentIdentity(session) }
            }
        }
        registry.flushAllViewState()
        let dirty = registry.allDirtyDocuments()
        guard let first = dirty.first else { return approveTermination() }
        let decision = prompt?.decide(first.title) ?? presentTerminationDecision(dirty)
        guard !Task.isCancelled, approval.matches(), !registry.hasPendingDocumentWrites else { return .terminateCancel }
        switch decision {
        case .cancel: return .terminateCancel
        case .discard: return approveTermination()
        case .save:
            let savePrompt = DocumentClosePrompt(decide: { _ in .save }, saveURL: { title in
                prompt.map { $0.saveURL(title) } ?? MarkdownSavePanel.runModal(defaultName: title)
            })
            for document in dirty {
                guard !Task.isCancelled, approval.matches(),
                      await document.saveForCloseInBackground(using: savePrompt,
                          whileApproved: { approval.matches() },
                          didAdoptImages: { approval.acceptImageAdoption(of: document.tabID) }),
                      !Task.isCancelled, approval.acceptSave(of: document.tabID) else { return .terminateCancel }
            }
            guard approval.matches(), !registry.hasPendingDocumentWrites, registry.allDirtyDocuments().isEmpty else { return .terminateCancel }
            return approveTermination()
        }
    }

    private func presentTerminationDecision(_ dirtyDocs: [DirtyDoc]) -> DocumentClosePrompt.Decision {
        let firstDirty = dirtyDocs[0]
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Do you want to save changes before quitting?"
        if dirtyDocs.count == 1 {
            alert.informativeText = "Your changes to \"\(firstDirty.title)\" will be lost if you don't save."
        } else {
            let moreCount = dirtyDocs.count - 1
            alert.informativeText = "Your changes to \"\(firstDirty.title)\" and \(moreCount) other document(s) will be lost if you don't save."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    private func approveTermination() -> NSApplication.TerminateReply {
        // Save As may have created file identities while quit panels were open.
        if !TestEnvironment.isRunningTests {
            WindowRegistry.shared.persistSessionNow()
            recoveryRestoreTask?.cancel()
            WindowRegistry.shared.retireMarkdownRecoveryCopies()
        }
        terminationApproved = true
        return .terminateNow
    }

    private enum SyncSaveAsOutcome { case saved, cancelled, failed }

    /// Presents a blocking Save-As panel for a dirty untitled Markdown document at
    /// quit time and writes it synchronously (no await possible at terminate time).
    /// Routes through the shared `MarkdownSavePanel` builder so the allowed types +
    /// default-name rule match ⌘⇧S exactly (AppDelegate stays unaware of the
    /// markdown UTTypes).
    private func runSyncSaveAs(for doc: DirtyDoc, using prompt: DocumentClosePrompt?, whileApproved: () -> Bool,
                               didAdoptImages: () -> Bool) -> SyncSaveAsOutcome {
        let selectedURL = prompt.map { $0.saveURL(doc.title) } ?? MarkdownSavePanel.runModal(defaultName: doc.title)
        guard let url = selectedURL, whileApproved() else { return .cancelled }
        return doc.saveAsSync(to: url, isSecurityScoped: true, whileApproved: whileApproved,
                              didAdoptImages: didAdoptImages) ? .saved : .failed
    }

    private func showSaveFailureAlert(titles: [String]) {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "PageFlow couldn't save all documents."
        alert.informativeText = titles.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func positionWindow(_ window: NSWindow, near screenPoint: CGPoint?) {
        guard let screenPoint, let screen = NSScreen.containing(screenPoint) else {
            window.center()
            return
        }

        // Anchor near the cursor, then fit the WHOLE window frame on-screen via
        // the shared clamp. Using `window.frame.size` (not the content size)
        // includes the titlebar, so the title bar can't slide under the menu bar.
        let size = window.frame.size
        let anchored = NSRect(
            origin: NSPoint(x: screenPoint.x - size.width * 0.35, y: screenPoint.y - 64),
            size: size
        )
        window.setFrame(NSScreen.onScreenFrame(anchored, in: screen.visibleFrame), display: false)
    }
}
