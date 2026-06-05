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

struct TabRuntime {
    let tabID: UUID
    let pdfManager: PDFManager
    let searchManager: SearchManager
    let annotationManager: AnnotationManager
    let commentManager: CommentManager
    let bookmarkManager: BookmarkManager
    let undoManager: UndoManager
}

@Observable
@MainActor
final class TabManager {
    deinit {
        if let monitor = editModeKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        // Each TabSession removes its own undo observers on cleanup()/deinit, so
        // releasing `sessions` here is sufficient — no observer bookkeeping.
        #if DEBUG
        Swift.print("[deinit] TabManager")
        #endif
    }

    // MARK: - Properties

    var tabs: [TabModel] = []
    var activeTabID: UUID?

    /// Whether this window floats above other apps. Scoped per-window, not persisted.
    var isAlwaysOnTop: Bool = false

    /// The single source of truth for per-tab runtime state: one session per tab.
    private var sessions: [UUID: TabSession] = [:]

    @ObservationIgnored var documentOpenedHandler: ((URL, Bool) -> Void)?

    // Edit mode keyboard shortcut monitor (intercepts Cmd+C/V for page copy/paste)
    @ObservationIgnored private var editModeKeyMonitor: Any?

    // Track open file picker panel for closing on drag-drop
    private weak var openPanel: NSOpenPanel?
    private var suppressAutomaticFilePicker = false

    // Password sheet presentation (window-level). The unlock payload lives on
    // each TabSession; this is the FIFO order of tab ids waiting for the single
    // sheet — the head is the request currently presented.
    private var unlockQueue: [UUID] = []

    /// The unlock prompt presented as this window's password sheet, derived from
    /// the head of `unlockQueue`. Identifiable by tab id so the sheet stays
    /// stable while a given tab is at the head.
    var pendingPasswordRequest: PasswordPrompt? {
        get {
            guard let tabID = unlockQueue.first,
                  let request = sessions[tabID]?.pendingUnlock else { return nil }
            return PasswordPrompt(tabID: tabID, url: request.url)
        }
        set {
            // SwiftUI only writes nil here (interactive / Escape dismiss); treat
            // it as cancelling the presented prompt.
            if newValue == nil { cancelPasswordPrompt() }
        }
    }

    struct PasswordPrompt: Identifiable {
        let tabID: UUID
        let url: URL
        var id: UUID { tabID }
    }

    /// The movable unit when a tab is torn off or merged: the tab model plus its
    /// session (which carries managers, undo history, UI state, and pending
    /// unlock together).
    private struct DetachedTab {
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

    var activeAnnotationManager: AnnotationManager? { activeSession?.annotationManager }

    var activeCommentManager: CommentManager? { activeSession?.commentManager }

    var activeBookmarkManager: BookmarkManager? { activeSession?.bookmarkManager }

    var activeRuntime: TabRuntime? {
        activeSession.map(runtime)
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

    var showingFileImporter: Bool {
        get {
            guard let id = activeTabID else { return false }
            return showingFileImporter(for: id)
        }
        set {
            guard let id = activeTabID else { return }
            setShowingFileImporter(newValue, for: id)
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

    func showingOutline(for tabID: UUID) -> Bool {
        sessions[tabID]?.uiState.showingOutline ?? false
    }

    func showingComments(for tabID: UUID) -> Bool {
        sessions[tabID]?.uiState.showingComments ?? false
    }

    func showingGoToPage(for tabID: UUID) -> Bool {
        sessions[tabID]?.uiState.showingGoToPage ?? false
    }

    func showingFileImporter(for tabID: UUID) -> Bool {
        sessions[tabID]?.uiState.showingFileImporter ?? false
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

    func setShowingFileImporter(_ value: Bool, for tabID: UUID) {
        sessions[tabID]?.uiState.showingFileImporter = value
    }

    func setIsEditingPages(_ value: Bool, for tabID: UUID) {
        guard let session = sessions[tabID] else { return }
        let wasEditing = session.uiState.isEditingPages
        session.uiState.isEditingPages = value

        guard activeTabID == tabID else { return }
        if value && !wasEditing {
            startEditModeKeyMonitor()
        } else if !value && wasEditing {
            stopEditModeKeyMonitor()
        }
    }

    /// Opens NSOpenPanel as a sheet on the key window — waits for window readiness.
    func openFilePicker() {
        // Prevent duplicate panels (concurrent onAppear calls, retry chains, etc.)
        guard openPanel == nil else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Select a PDF file to open"

        openPanel = panel  // Set immediately to block concurrent calls
        presentOpenPanel(panel, retryCount: 0)
    }

    private func presentOpenPanel(_ panel: NSOpenPanel, retryCount: Int) {
        // Bail out if closeFilePicker() was called during retry loop
        guard openPanel === panel else { return }

        guard let window = NSApp.keyWindow else {
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

    func dirtyPDFManagers() -> [(UUID, PDFManager)] {
        sessions.compactMap { id, session in
            session.pdfManager.isDirty ? (id, session.pdfManager) : nil
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

    /// Returns the tab ID if this TabManager has a tab with the given URL open.
    func tabID(for url: URL) -> UUID? {
        let canonicalURL = url.pageFlowCanonicalDocumentURL

        if let tabID = tabAwaitingPassword(for: canonicalURL) {
            return tabID
        }

        return tabs.first { $0.documentURL?.pageFlowCanonicalDocumentURL == canonicalURL }?.id
    }

    // MARK: - Tab Operations

    func createNewTab(with url: URL? = nil, isSecurityScoped: Bool = false) {
        let previousActiveTabID = activeTabID

        // Preserve state of current tab before switching away
        saveCurrentTabState()

        let newTab = TabModel()

        tabs.append(newTab)
        createSession(for: newTab)
        activeTabID = newTab.id

        if let url = url {
            let result = sessions[newTab.id]?.pdfManager.loadDocument(from: url, isSecurityScoped: isSecurityScoped) ?? .failed
            handleLoadResult(
                result,
                for: newTab.id,
                url: url,
                isSecurityScoped: isSecurityScoped,
                closeTabOnCancel: true,
                restoreTabIDOnCancel: previousActiveTabID
            )
        } else {
            // A new empty tab (Cmd+T / the "+" button) prompts for a file to open,
            // matching the auto file picker a freshly opened window shows. The tab's
            // window is already key, so the panel attaches to it correctly.
            openFilePicker()
        }
    }

    func closeTab(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }

        if let pdfManager = sessions[tabID]?.pdfManager,
           pdfManager.isDirty,
           !confirmClose(tabID: tabID, pdfManager: pdfManager) {
            return
        }

        // Stop keyboard monitor if closing tab was in edit mode
        if activeTabID == tabID, sessions[tabID]?.uiState.isEditingPages == true {
            stopEditModeKeyMonitor()
        }

        // Capture the closing tab's reading position before teardown, but only
        // when it's the active tab (its live view still exists for an exact scroll
        // point); background tabs were already persisted when switched away from.
        if activeTabID == tabID, let pdfManager = sessions[tabID]?.pdfManager {
            persistViewState(for: pdfManager)
        }

        // closeSession() performs the ordered teardown (close document, clear
        // markup, drop undo history + observers) before dropping the session.
        closeSession(for: tabID)
        tabs.remove(at: index)

        // Handle tab selection after close
        if tabs.isEmpty {
            WindowRegistry.shared.closeWindow(for: self)
        } else if activeTabID == tabID {
            let newIndex = min(index, tabs.count - 1)
            activeTabID = tabs[newIndex].id
        }
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

    func moveTab(from source: IndexSet, to destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
    }

    func moveTab(fromIndex: Int, toIndex: Int) {
        guard fromIndex >= 0, fromIndex < tabs.count,
              toIndex >= 0, toIndex <= tabs.count,
              fromIndex != toIndex else { return }

        let tab = tabs.remove(at: fromIndex)
        let adjustedIndex = toIndex > fromIndex ? toIndex - 1 : toIndex
        tabs.insert(tab, at: adjustedIndex)
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

    @discardableResult
    func moveTabToNewWindow(_ tabID: UUID, near screenPoint: CGPoint) -> Bool {
        // Synchronous: detach the tab → build an empty TabManager pre-loaded
        // with it → hand to the AppDelegate, which creates and shows a window
        // hosting that TabManager. No async callback, no placeholder dance —
        // if the window opens, the tab is already in it.
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let detachedTab = detachTab(tabID) else {
            return false
        }

        let newTabManager = TabManager(createInitialTab: false)
        newTabManager.attachDetachedTab(detachedTab, at: 0)
        _ = appDelegate.createNewWindow(with: newTabManager, screenPoint: screenPoint)
        return true
    }

    // MARK: - Document Operations

    func openDocument(url: URL, isSecurityScoped: Bool, replaceCurrent: Bool = false) {
        if let existingTabID = tabID(for: url) {
            selectTab(existingTabID)
            WindowRegistry.shared.bringToFront(for: self)
            dismissPlaceholderWindowIfNeeded()
            return
        }

        // Activate existing tab if this document is already open (any window)
        if WindowRegistry.shared.activateExistingDocument(for: url) {
            dismissPlaceholderWindowIfNeeded()
            return
        }

        // If current tab is empty or replace is requested, load into current tab; otherwise create new tab
        if let activeTab = activeTab,
           let activeID = activeTabID,
           (replaceCurrent || (!activeTab.hasDocument && !isAwaitingPassword(for: activeID))),
           let pdfManager = sessions[activeID]?.pdfManager {
            let result = pdfManager.loadDocument(from: url, isSecurityScoped: isSecurityScoped)
            handleLoadResult(result, for: activeID, url: url, isSecurityScoped: isSecurityScoped)
        } else {
            // Current tab has a document, create new tab
            createNewTab(with: url, isSecurityScoped: isSecurityScoped)
        }

        WindowRegistry.shared.bringToFront(for: self)
    }

    /// Opens dropped PDFs as tabs in THIS window, in order, and returns how many
    /// failed to load. A file already open in this window is focused (not
    /// duplicated); a file open in another window is skipped so the whole drop stays
    /// in this window. The window is brought to front once, after all files are
    /// processed — not per file.
    @discardableResult
    func openDroppedDocuments(_ urls: [URL]) -> Int {
        guard !urls.isEmpty else { return 0 }
        var failures = 0
        for url in urls where !openDroppedDocument(url) {
            failures += 1
        }
        WindowRegistry.shared.bringToFront(for: self)
        return failures
    }

    /// Loads one dropped `url`. Returns false only if the PDF failed to load.
    private func openDroppedDocument(_ url: URL) -> Bool {
        // Already open in this window → focus it, no duplicate.
        if let existingTabID = tabID(for: url) {
            selectTab(existingTabID)
            return true
        }
        // Already open in another window → leave it there; keep this drop here.
        if WindowRegistry.shared.isDocumentOpen(url) {
            return true
        }
        // Reuse the empty active tab if free; otherwise a fresh tab, rolled back on failure.
        if let activeID = activeTabID, let activeTab,
           !activeTab.hasDocument, !isAwaitingPassword(for: activeID),
           let pdfManager = sessions[activeID]?.pdfManager {
            let result = pdfManager.loadDocument(from: url, isSecurityScoped: false)
            return finishDroppedLoad(result, for: activeID, url: url, createdTab: false, restoreOnFailure: nil)
        }

        let previousActiveTabID = activeTabID
        saveCurrentTabState()
        let newTab = TabModel()
        tabs.append(newTab)
        createSession(for: newTab)
        activeTabID = newTab.id
        let result = sessions[newTab.id]?.pdfManager.loadDocument(from: url, isSecurityScoped: false) ?? .failed
        return finishDroppedLoad(result, for: newTab.id, url: url, createdTab: true, restoreOnFailure: previousActiveTabID)
    }

    /// Applies a dropped file's load result. On `.failed`, removes a tab we created
    /// for it so a bad file never leaves an empty "New Tab" behind. Returns false
    /// only on `.failed`.
    private func finishDroppedLoad(
        _ result: DocumentLoadResult,
        for tabID: UUID,
        url: URL,
        createdTab: Bool,
        restoreOnFailure: UUID?
    ) -> Bool {
        if case .failed = result {
            if createdTab {
                closeSession(for: tabID)
                tabs.removeAll { $0.id == tabID }
                activeTabID = restoreOnFailure ?? tabs.last?.id
            }
            return false
        }
        handleLoadResult(
            result,
            for: tabID,
            url: url,
            isSecurityScoped: false,
            closeTabOnCancel: createdTab,
            restoreTabIDOnCancel: createdTab ? restoreOnFailure : nil
        )
        return true
    }

    private func handleLoadResult(
        _ result: DocumentLoadResult,
        for tabID: UUID,
        url: URL,
        isSecurityScoped: Bool,
        closeTabOnCancel: Bool = false,
        restoreTabIDOnCancel: UUID? = nil
    ) {
        switch result {
        case .success:
            clearPendingPasswordRequest(for: tabID)
            clearSearchState(for: tabID)
            if let index = tabs.firstIndex(where: { $0.id == tabID }) {
                tabs[index].documentURL = url
                tabs[index].isSecurityScoped = isSecurityScoped
                tabs[index].title = sessions[tabID]?.pdfManager.documentTitle ?? url.deletingPathExtension().lastPathComponent
            }
            documentOpenedHandler?(url, isSecurityScoped)
        case .needsPassword:
            promptForPassword(
                tabID: tabID,
                url: url,
                isSecurityScoped: isSecurityScoped,
                closeTabOnCancel: closeTabOnCancel,
                restoreTabIDOnCancel: restoreTabIDOnCancel
            )
        case .failed:
            clearPendingPasswordRequest(for: tabID)
            break
        }
    }

    func consumeAutomaticFilePickerSuppression() -> Bool {
        let wasSuppressed = suppressAutomaticFilePicker
        suppressAutomaticFilePicker = false
        return wasSuppressed
    }

    func isAwaitingPassword(for tabID: UUID) -> Bool {
        sessions[tabID]?.pendingUnlock != nil
    }

    var isPlaceholderWindow: Bool {
        hasOnlyPlaceholderTab
    }

    private var hasOnlyPlaceholderTab: Bool {
        guard tabs.count == 1,
              let activeTabID,
              let activeTab = activeTab else {
            return false
        }

        return !activeTab.hasDocument &&
            !(sessions[activeTabID]?.pdfManager.hasDocument ?? false) &&
            !isAwaitingPassword(for: activeTabID)
    }

    @discardableResult
    func dismissPlaceholderWindowIfNeeded() -> Bool {
        closeFilePicker()

        guard hasOnlyPlaceholderTab else { return false }

        suppressAutomaticFilePicker = true
        WindowRegistry.shared.closeWindow(for: self)
        return true
    }

    // MARK: - Password Sheet (window-level presentation over per-session data)

    private func promptForPassword(
        tabID: UUID,
        url: URL,
        isSecurityScoped: Bool,
        closeTabOnCancel: Bool,
        restoreTabIDOnCancel: UUID?
    ) {
        guard let session = sessions[tabID] else { return }

        session.pendingUnlock = TabSession.UnlockRequest(
            url: url,
            isSecurityScoped: isSecurityScoped,
            closeTabOnCancel: closeTabOnCancel,
            restoreTabIDOnCancel: restoreTabIDOnCancel
        )
        if !unlockQueue.contains(tabID) {
            unlockQueue.append(tabID)
        }
    }

    private func clearPendingPasswordRequest(for tabID: UUID) {
        sessions[tabID]?.pendingUnlock = nil
        unlockQueue.removeAll { $0 == tabID }
    }

    /// The tab whose session is awaiting a password for the given canonical URL.
    private func tabAwaitingPassword(for canonicalURL: URL) -> UUID? {
        sessions.first { _, session in
            session.pendingUnlock?.url.pageFlowCanonicalDocumentURL == canonicalURL
        }?.key
    }

    func submitPassword(_ password: String) -> Bool {
        guard let tabID = unlockQueue.first,
              let session = sessions[tabID],
              let request = session.pendingUnlock else {
            return false
        }

        if session.pdfManager.unlockDocument(password: password) {
            clearSearchState(for: tabID)
            if let index = tabs.firstIndex(where: { $0.id == tabID }) {
                tabs[index].documentURL = request.url
                tabs[index].isSecurityScoped = request.isSecurityScoped
            }
            documentOpenedHandler?(request.url, request.isSecurityScoped)
            session.pendingUnlock = nil
            unlockQueue.removeAll { $0 == tabID }
            return true
        }
        return false
    }

    func cancelPasswordPrompt() {
        guard let tabID = unlockQueue.first,
              let session = sessions[tabID],
              let request = session.pendingUnlock else { return }

        session.pdfManager.cancelPendingUnlock()
        session.pendingUnlock = nil
        unlockQueue.removeAll { $0 == tabID }

        guard request.closeTabOnCancel,
              tabs.contains(where: { $0.id == tabID }) else {
            return
        }

        closeTab(tabID)

        if let restoreTabID = request.restoreTabIDOnCancel,
           tabs.contains(where: { $0.id == restoreTabID }) {
            selectTab(restoreTabID)
        }
    }

    func updateTabDocument(_ tabID: UUID, url: URL) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].documentURL = url
    }

    func clearAllSearchState() {
        for session in sessions.values {
            session.searchManager.clearSearch()
        }

        for index in tabs.indices {
            tabs[index].savedSearchQuery = ""
            tabs[index].savedSearchResultIndex = 0
        }
    }

    private func runtime(for session: TabSession) -> TabRuntime {
        TabRuntime(
            tabID: session.id,
            pdfManager: session.pdfManager,
            searchManager: session.searchManager,
            annotationManager: session.annotationManager,
            commentManager: session.commentManager,
            bookmarkManager: session.bookmarkManager,
            undoManager: session.undoManager
        )
    }

    // MARK: - State Management

    private func createSession(for tab: TabModel) {
        // The session wires the page-mutation fan-out and undo-availability
        // observers in its init; the markup managers are configured with the
        // live PDFView later in PDFViewWrapper.makeNSView().
        sessions[tab.id] = TabSession(id: tab.id)
    }

    private func clearSearchState(for tabID: UUID) {
        sessions[tabID]?.searchManager.clearSearch()

        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].savedSearchQuery = ""
        tabs[index].savedSearchResultIndex = 0
    }

    private func saveCurrentTabState() {
        guard let id = activeTabID,
              let index = tabs.firstIndex(where: { $0.id == id }),
              let session = sessions[id] else { return }

        tabs[index].savedPageIndex = session.pdfManager.currentPageIndex
        tabs[index].savedScaleFactor = session.pdfManager.scaleFactor
        tabs[index].savedSearchQuery = session.searchManager.searchQuery
        tabs[index].savedSearchResultIndex = session.searchManager.currentResultIndex
        persistViewState(for: session.pdfManager)
    }

    // MARK: - Reading-Position Persistence

    /// Persists the active tab's reading state (last page, scroll, zoom) to the
    /// shared store. Safe to call at any lifecycle boundary (window close, quit).
    func flushActiveTabViewState() {
        guard let id = activeTabID, let session = sessions[id] else { return }
        persistViewState(for: session.pdfManager)
    }

    private func persistViewState(for pdfManager: PDFManager) {
        guard let url = pdfManager.documentURL,
              let state = pdfManager.captureViewState() else { return }
        DocumentStateStore.shared.save(state, for: url)
    }

    private func confirmClose(tabID: UUID, pdfManager: PDFManager) -> Bool {
        guard pdfManager.isDirty else { return true }

        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Do you want to save changes to \"\(pdfManager.documentTitle)\"?"
        alert.informativeText = "Your changes will be lost if you don't save."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return pdfManager.saveSync()  // Use sync for modal context
        case .alertSecondButtonReturn:
            return false
        default:
            return true
        }
    }

    private func restoreTabState(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              let session = sessions[tabID] else { return }

        let tab = tabs[index]
        let pdfManager = session.pdfManager

        if pdfManager.hasDocument {
            pdfManager.goToPage(tab.savedPageIndex)
            if !pdfManager.isAutoScaling {
                pdfManager.setZoom(tab.savedScaleFactor)
            }
        }

        if let document = pdfManager.document,
           !tab.savedSearchQuery.isEmpty {
            session.searchManager.restoreSearch(
                tab.savedSearchQuery,
                resultIndex: tab.savedSearchResultIndex,
                in: document
            )
        }
    }

    // MARK: - Dirty State

    func isTabDirty(_ tabID: UUID) -> Bool {
        sessions[tabID]?.pdfManager.isDirty ?? false
    }

    // MARK: - Save Operations

    enum SaveResult {
        case success(message: String)
        case cancelled
        case failure(message: String)
    }

    func saveActiveDocument() async -> SaveResult {
        guard let pdfManager = activeSession?.pdfManager else {
            return .failure(message: "No active document to save.")
        }

        guard pdfManager.hasDocument else {
            return .failure(message: "Open a document before saving.")
        }

        guard pdfManager.isDirty else {
            return .success(message: "")
        }

        let saved = await pdfManager.save()
        let result: SaveResult = saved ? .success(message: "Saved") : .failure(message: "Save failed.")
        postSaveNotification(result)
        return result
    }

    func saveActiveDocumentAs() async -> SaveResult {
        guard let id = activeTabID,
              let session = sessions[id] else {
            return .failure(message: "No active document to save.")
        }

        let pdfManager = session.pdfManager
        guard let originalURL = pdfManager.documentURL else {
            return .failure(message: "Open a document before saving.")
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = originalURL.lastPathComponent

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            return .cancelled
        }

        let oldURL = pdfManager.documentURL
        let saved = await pdfManager.saveAs(to: url)
        if saved, let index = tabs.firstIndex(where: { $0.id == id }) {
            // Migrate bookmarks from old path to new path
            if let oldURL = oldURL {
                session.bookmarkManager.migrateBookmarks(from: oldURL, to: url)
            }
            tabs[index].documentURL = url
            tabs[index].isSecurityScoped = false
        }

        let result: SaveResult = saved ? .success(message: "Saved As") : .failure(message: "Save As failed.")
        postSaveNotification(result)
        return result
    }

    // MARK: - Notifications
    private func postSaveNotification(_ result: SaveResult) {
        switch result {
        case .success(let message):
            guard !message.isEmpty else { return }
            NotificationCenter.default.post(
                name: .saveResult,
                object: nil,
                userInfo: ["message": message]
            )
        case .cancelled, .failure:
            break
        }
    }

    // MARK: - Tab Move (tear-off / merge)

    private func detachTab(_ tabID: UUID, closeIfEmpty: Bool = true) -> DetachedTab? {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              let session = sessions[tabID] else {
            return nil
        }

        if activeTabID == tabID {
            saveCurrentTabState()
        }

        if activeTabID == tabID, session.uiState.isEditingPages {
            stopEditModeKeyMonitor()
        }

        let detachedTab = DetachedTab(tab: tabs[index], session: session)

        // The session — managers, undo history + observers, UI state, and any
        // pending unlock — travels intact. Only this window's presentation order
        // is released; the session's undo observers are NOT torn down.
        unlockQueue.removeAll { $0 == tabID }
        tabs.remove(at: index)
        sessions.removeValue(forKey: tabID)

        if tabs.isEmpty {
            activeTabID = nil
            closeFilePicker()
            if closeIfEmpty {
                WindowRegistry.shared.closeWindow(for: self)
            }
        } else if activeTabID == tabID {
            let newIndex = min(index, tabs.count - 1)
            activeTabID = tabs[newIndex].id
        }

        return detachedTab
    }

    private func attachDetachedTab(
        _ detachedTab: DetachedTab,
        at index: Int,
        select: Bool = true
    ) {
        if select {
            saveCurrentTabState()
        }

        let session = detachedTab.session
        let clampedIndex = min(max(index, 0), tabs.count)
        var attachedTab = detachedTab.tab
        if let documentURL = attachedTab.documentURL {
            attachedTab.title = session.pdfManager.documentTitle.isEmpty
                ? documentURL.deletingPathExtension().lastPathComponent
                : session.pdfManager.documentTitle
        }
        tabs.insert(attachedTab, at: clampedIndex)
        sessions[session.id] = session

        // If the moved tab is still awaiting a password, queue it for this
        // window's sheet (after any request already presented here).
        if session.pendingUnlock != nil, !unlockQueue.contains(session.id) {
            unlockQueue.append(session.id)
        }

        if select {
            selectTab(session.id)
        }
    }

    // MARK: - Cleanup

    /// Tears down and drops a tab's session. The session owns the ordered
    /// teardown (close document, clear markup, drop undo history + observers).
    private func closeSession(for tabID: UUID) {
        sessions.removeValue(forKey: tabID)?.cleanup()
        unlockQueue.removeAll { $0 == tabID }
    }

    // MARK: - Edit Mode Keyboard Monitor

    private func startEditModeKeyMonitor() {
        guard editModeKeyMonitor == nil else { return }

        editModeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isEditingPages else {
                return event
            }

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
                if let pdfManager = self.activePDFManager {
                    pdfManager.copyPage(at: pdfManager.currentPageIndex)
                }
                return nil
            }

            if cutShortcut.matches(event: event) {
                if let pdfManager = self.activePDFManager,
                   pdfManager.pageCount > 1 {
                    pdfManager.cutPage(at: pdfManager.currentPageIndex)
                }
                return nil
            }

            if pasteShortcut.matches(event: event) {
                if let pdfManager = self.activePDFManager, pdfManager.canPaste {
                    _ = pdfManager.pastePage(after: pdfManager.currentPageIndex)
                }
                return nil
            }

            // Enter/Return exits edit mode
            if event.keyCode == 36 {
                self.isEditingPages = false
                return nil
            }

            return event
        }
    }

    private func stopEditModeKeyMonitor() {
        if let monitor = editModeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            editModeKeyMonitor = nil
        }
    }
}
