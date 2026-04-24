//
//  TabManager.swift
//  PageFlow
//
//  Tab state management with session persistence
//

import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Per-tab UI state (not persisted)
struct TabUIState: Sendable {
    var showingOutline = false
    var showingComments = false
    var showingGoToPage = false
    var showingFileImporter = false
    var isEditingPages = false
}

private struct UndoAvailability: Equatable, Sendable {
    var canUndo = false
    var canRedo = false
}

@Observable
@MainActor
final class TabManager {
    deinit {
        if let monitor = editModeKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        for observer in undoCheckpointObservers.values {
            NotificationCenter.default.removeObserver(observer)
        }
        #if DEBUG
        Swift.print("[deinit] TabManager")
        #endif
    }

    // MARK: - Properties

    var tabs: [TabModel] = []
    var activeTabID: UUID?

    /// Whether this window floats above other apps. Scoped per-window, not persisted.
    var isAlwaysOnTop: Bool = false

    // Per-tab runtime state (not persisted)
    private var pdfManagers: [UUID: PDFManager] = [:]
    private var searchManagers: [UUID: SearchManager] = [:]
    private var annotationManagers: [UUID: AnnotationManager] = [:]
    private var commentManagers: [UUID: CommentManager] = [:]
    private var bookmarkManagers: [UUID: BookmarkManager] = [:]
    private(set) var undoManagers: [UUID: UndoManager] = [:]
    private var undoAvailabilityByTab: [UUID: UndoAvailability] = [:]
    @ObservationIgnored var documentOpenedHandler: ((URL, Bool) -> Void)?

    // Per-tab UI state (not persisted) - internal for MainView access
    var tabUIStates: [UUID: TabUIState] = [:]

    // Edit mode keyboard shortcut monitor (intercepts Cmd+C/V for page copy/paste)
    @ObservationIgnored private var editModeKeyMonitor: Any?
    @ObservationIgnored private var undoCheckpointObservers: [UUID: NSObjectProtocol] = [:]

    // Track open file picker panel for closing on drag-drop
    private weak var openPanel: NSOpenPanel?
    private var suppressAutomaticFilePicker = false

    // Password dialog state
    var pendingPasswordRequest: PasswordRequest?
    private var queuedPasswordRequests: [PasswordRequest] = []

    struct PasswordRequest: Identifiable {
        let id = UUID()
        let tabID: UUID
        let url: URL
        let isSecurityScoped: Bool
        let closeTabOnCancel: Bool
        let restoreTabIDOnCancel: UUID?
    }

    private struct DetachedTabContext {
        let tab: TabModel
        let pdfManager: PDFManager
        let searchManager: SearchManager
        let annotationManager: AnnotationManager
        let commentManager: CommentManager
        let bookmarkManager: BookmarkManager
        let undoManager: UndoManager
        let uiState: TabUIState
        let pendingPasswordRequest: PasswordRequest?
        let queuedPasswordRequests: [PasswordRequest]
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

    var activePDFManager: PDFManager? {
        guard let id = activeTabID else { return nil }
        return pdfManagers[id]
    }

    var activeSearchManager: SearchManager? {
        guard let id = activeTabID else { return nil }
        return searchManagers[id]
    }

    var activeAnnotationManager: AnnotationManager? {
        guard let id = activeTabID else { return nil }
        return annotationManagers[id]
    }

    var activeCommentManager: CommentManager? {
        guard let id = activeTabID else { return nil }
        return commentManagers[id]
    }

    var activeBookmarkManager: BookmarkManager? {
        guard let id = activeTabID else { return nil }
        return bookmarkManagers[id]
    }

    var activeCanUndo: Bool {
        guard let id = activeTabID else { return false }
        return undoAvailabilityByTab[id]?.canUndo ?? false
    }

    var activeCanRedo: Bool {
        guard let id = activeTabID else { return false }
        return undoAvailabilityByTab[id]?.canRedo ?? false
    }

    // MARK: - UI State (Active Tab)

    var showingOutline: Bool {
        get {
            guard let id = activeTabID else { return false }
            return tabUIStates[id]?.showingOutline ?? false
        }
        set {
            guard let id = activeTabID else { return }
            tabUIStates[id, default: TabUIState()].showingOutline = newValue
        }
    }

    var showingComments: Bool {
        get {
            guard let id = activeTabID else { return false }
            return tabUIStates[id]?.showingComments ?? false
        }
        set {
            guard let id = activeTabID else { return }
            tabUIStates[id, default: TabUIState()].showingComments = newValue
        }
    }

    var showingGoToPage: Bool {
        get {
            guard let id = activeTabID else { return false }
            return tabUIStates[id]?.showingGoToPage ?? false
        }
        set {
            guard let id = activeTabID else { return }
            tabUIStates[id, default: TabUIState()].showingGoToPage = newValue
        }
    }

    var showingFileImporter: Bool {
        get {
            guard let id = activeTabID else { return false }
            return tabUIStates[id]?.showingFileImporter ?? false
        }
        set {
            guard let id = activeTabID else { return }
            tabUIStates[id, default: TabUIState()].showingFileImporter = newValue
        }
    }

    var isEditingPages: Bool {
        get {
            guard let id = activeTabID else { return false }
            return tabUIStates[id]?.isEditingPages ?? false
        }
        set {
            guard let id = activeTabID else { return }
            let wasEditing = tabUIStates[id]?.isEditingPages ?? false
            tabUIStates[id, default: TabUIState()].isEditingPages = newValue

            if newValue && !wasEditing {
                startEditModeKeyMonitor()
            } else if !newValue && wasEditing {
                stopEditModeKeyMonitor()
            }
        }
    }

    func sidebarState(for tabID: UUID) -> (showingOutline: Bool, showingComments: Bool) {
        let state = tabUIStates[tabID] ?? TabUIState()
        return (state.showingOutline, state.showingComments)
    }

    func setShowingOutline(_ value: Bool, for tabID: UUID) {
        tabUIStates[tabID, default: TabUIState()].showingOutline = value
    }

    func setShowingComments(_ value: Bool, for tabID: UUID) {
        tabUIStates[tabID, default: TabUIState()].showingComments = value
    }

    func setShowingGoToPage(_ value: Bool, for tabID: UUID) {
        tabUIStates[tabID, default: TabUIState()].showingGoToPage = value
    }

    func setShowingFileImporter(_ value: Bool, for tabID: UUID) {
        tabUIStates[tabID, default: TabUIState()].showingFileImporter = value
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
        pdfManagers.compactMap { key, manager in
            manager.isDirty ? (key, manager) : nil
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
        createManagersForTab(initialTab)
    }

    /// Returns the tab ID if this TabManager has a tab with the given URL open.
    func tabID(for url: URL) -> UUID? {
        let canonicalURL = url.pageFlowCanonicalDocumentURL

        if let passwordRequest = passwordRequest(for: canonicalURL) {
            return passwordRequest.tabID
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
        createManagersForTab(newTab)
        activeTabID = newTab.id

        if let url = url {
            let result = pdfManagers[newTab.id]?.loadDocument(from: url, isSecurityScoped: isSecurityScoped) ?? .failed
            handleLoadResult(
                result,
                for: newTab.id,
                url: url,
                isSecurityScoped: isSecurityScoped,
                closeTabOnCancel: true,
                restoreTabIDOnCancel: previousActiveTabID
            )
        }
    }

    func closeTab(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }

        if let pdfManager = pdfManagers[tabID],
           pdfManager.isDirty,
           !confirmClose(tabID: tabID, pdfManager: pdfManager) {
            return
        }

        // Stop keyboard monitor if closing tab was in edit mode
        if activeTabID == tabID && (tabUIStates[tabID]?.isEditingPages ?? false) {
            stopEditModeKeyMonitor()
        }

        // Note: closeDocument() in cleanupManagers handles undo cleanup via undoManagerProvider
        // which correctly targets this tab's window, not keyWindow (fixes multi-window scenarios)
        cleanupManagers(for: tabID)
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
           let pdfManager = pdfManagers[activeID] {
            let result = pdfManager.loadDocument(from: url, isSecurityScoped: isSecurityScoped)
            handleLoadResult(result, for: activeID, url: url, isSecurityScoped: isSecurityScoped)
        } else {
            // Current tab has a document, create new tab
            createNewTab(with: url, isSecurityScoped: isSecurityScoped)
        }

        WindowRegistry.shared.bringToFront(for: self)
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
                tabs[index].title = pdfManagers[tabID]?.documentTitle ?? url.deletingPathExtension().lastPathComponent
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
        pendingPasswordRequest?.tabID == tabID ||
            queuedPasswordRequests.contains { $0.tabID == tabID }
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
            !(pdfManagers[activeTabID]?.hasDocument ?? false) &&
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

    private func promptForPassword(
        tabID: UUID,
        url: URL,
        isSecurityScoped: Bool,
        closeTabOnCancel: Bool,
        restoreTabIDOnCancel: UUID?
    ) {
        clearPendingPasswordRequest(for: tabID)

        let request = PasswordRequest(
            tabID: tabID,
            url: url,
            isSecurityScoped: isSecurityScoped,
            closeTabOnCancel: closeTabOnCancel,
            restoreTabIDOnCancel: restoreTabIDOnCancel
        )

        if pendingPasswordRequest == nil {
            pendingPasswordRequest = request
        } else {
            queuedPasswordRequests.append(request)
        }
    }

    private func clearPendingPasswordRequest(for tabID: UUID) {
        if pendingPasswordRequest?.tabID == tabID {
            pendingPasswordRequest = nil
            advancePasswordRequestQueue()
            return
        }

        queuedPasswordRequests.removeAll { $0.tabID == tabID }
    }

    private func passwordRequest(for url: URL) -> PasswordRequest? {
        if let pendingPasswordRequest,
           pendingPasswordRequest.url.pageFlowCanonicalDocumentURL == url {
            return pendingPasswordRequest
        }

        return queuedPasswordRequests.first {
            $0.url.pageFlowCanonicalDocumentURL == url
        }
    }

    private func advancePasswordRequestQueue() {
        guard pendingPasswordRequest == nil,
              !queuedPasswordRequests.isEmpty else {
            return
        }

        pendingPasswordRequest = queuedPasswordRequests.removeFirst()
    }

    func submitPassword(_ password: String) -> Bool {
        guard let request = pendingPasswordRequest,
              let pdfManager = pdfManagers[request.tabID] else {
            return false
        }

        if pdfManager.unlockDocument(password: password) {
            clearSearchState(for: request.tabID)
            if let index = tabs.firstIndex(where: { $0.id == request.tabID }) {
                tabs[index].documentURL = request.url
                tabs[index].isSecurityScoped = request.isSecurityScoped
            }
            documentOpenedHandler?(request.url, request.isSecurityScoped)
            pendingPasswordRequest = nil
            advancePasswordRequestQueue()
            return true
        }
        return false
    }

    func cancelPasswordPrompt() {
        guard let request = pendingPasswordRequest else { return }
        pdfManagers[request.tabID]?.cancelPendingUnlock()
        pendingPasswordRequest = nil
        advancePasswordRequestQueue()

        guard request.closeTabOnCancel,
              tabs.contains(where: { $0.id == request.tabID }) else {
            return
        }

        closeTab(request.tabID)

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
        for searchManager in searchManagers.values {
            searchManager.clearSearch()
        }

        for index in tabs.indices {
            tabs[index].savedSearchQuery = ""
            tabs[index].savedSearchResultIndex = 0
        }
    }

    func managers(for tabID: UUID) -> (PDFManager, SearchManager, AnnotationManager, CommentManager, BookmarkManager)? {
        guard let pdfManager = pdfManagers[tabID],
              let searchManager = searchManagers[tabID],
              let annotationManager = annotationManagers[tabID],
              let commentManager = commentManagers[tabID],
              let bookmarkManager = bookmarkManagers[tabID] else {
            return nil
        }
        return (pdfManager, searchManager, annotationManager, commentManager, bookmarkManager)
    }

    // MARK: - State Management

    private func createManagersForTab(_ tab: TabModel) {
        let pdfManager = PDFManager()
        let searchManager = SearchManager()
        let annotationManager = AnnotationManager()
        let commentManager = CommentManager()
        let bookmarkManager = BookmarkManager()
        // Note: bookmarkManager.configure() is called in PDFViewWrapper.makeNSView()
        // when the undoManagerProvider is available

        pdfManagers[tab.id] = pdfManager
        searchManagers[tab.id] = searchManager
        annotationManagers[tab.id] = annotationManager
        commentManagers[tab.id] = commentManager
        bookmarkManagers[tab.id] = bookmarkManager
        configureUndoManager(for: tab.id)

        pdfManager.pageMutationHandler = { [weak bookmarkManager, weak commentManager] mutation in
            switch mutation {
            case .inserted(let index):
                bookmarkManager?.handlePageInsertion(at: index)
                commentManager?.reconcilePageIndices()
            case .deleted(let index):
                bookmarkManager?.handlePageDeletion(at: index)
                commentManager?.reconcilePageIndices()
            case .moved(let sourceIndex, let destinationIndex):
                bookmarkManager?.handlePageMove(from: sourceIndex, to: destinationIndex)
                commentManager?.reconcilePageIndices()
            }
        }
    }

    private func configureUndoManager(for tabID: UUID) {
        installUndoManager(UndoManager(), for: tabID)
    }

    private func installUndoManager(_ undoManager: UndoManager, for tabID: UUID) {
        removeUndoObserver(for: tabID)

        undoManagers[tabID] = undoManager
        refreshUndoAvailability(for: tabID)

        let observer = NotificationCenter.default.addObserver(
            forName: .NSUndoManagerCheckpoint,
            object: undoManager,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshUndoAvailability(for: tabID)
            }
        }
        undoCheckpointObservers[tabID] = observer
    }

    private func removeUndoObserver(for tabID: UUID) {
        guard let observer = undoCheckpointObservers.removeValue(forKey: tabID) else { return }
        NotificationCenter.default.removeObserver(observer)
    }

    private func refreshUndoAvailability(for tabID: UUID) {
        updateUndoAvailability(for: tabID, undoManager: undoManagers[tabID])
    }

    private func updateUndoAvailability(for tabID: UUID, undoManager: UndoManager?) {
        let availability: UndoAvailability
        if let undoManager {
            availability = UndoAvailability(
                canUndo: undoManager.canUndo,
                canRedo: undoManager.canRedo
            )
        } else {
            availability = UndoAvailability()
        }

        if undoAvailabilityByTab[tabID] != availability {
            undoAvailabilityByTab[tabID] = availability
        }
    }

    private func clearSearchState(for tabID: UUID) {
        searchManagers[tabID]?.clearSearch()

        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].savedSearchQuery = ""
        tabs[index].savedSearchResultIndex = 0
    }

    private func saveCurrentTabState() {
        guard let id = activeTabID,
              let index = tabs.firstIndex(where: { $0.id == id }),
              let pdfManager = pdfManagers[id],
              let searchManager = searchManagers[id] else { return }

        tabs[index].savedPageIndex = pdfManager.currentPageIndex
        tabs[index].savedScaleFactor = pdfManager.scaleFactor
        tabs[index].savedSearchQuery = searchManager.searchQuery
        tabs[index].savedSearchResultIndex = searchManager.currentResultIndex
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
              let pdfManager = pdfManagers[tabID],
              let searchManager = searchManagers[tabID] else { return }

        let tab = tabs[index]

        if pdfManager.hasDocument {
            pdfManager.goToPage(tab.savedPageIndex)
            if !pdfManager.isAutoScaling {
                pdfManager.setZoom(tab.savedScaleFactor)
            }
        }

        if let document = pdfManager.document,
           !tab.savedSearchQuery.isEmpty {
            searchManager.restoreSearch(
                tab.savedSearchQuery,
                resultIndex: tab.savedSearchResultIndex,
                in: document
            )
        }
    }

    func updateScrollPosition(for tabID: UUID, scrollY: CGFloat) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].savedScrollY = scrollY
    }

    // MARK: - Dirty State

    func isTabDirty(_ tabID: UUID) -> Bool {
        pdfManagers[tabID]?.isDirty ?? false
    }

    // MARK: - Save Operations

    enum SaveResult {
        case success(message: String)
        case cancelled
        case failure(message: String)
    }

    func saveActiveDocument() async -> SaveResult {
        guard let id = activeTabID,
              let pdfManager = pdfManagers[id] else {
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
              let pdfManager = pdfManagers[id] else {
            return .failure(message: "No active document to save.")
        }

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
                bookmarkManagers[id]?.migrateBookmarks(from: oldURL, to: url)
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

    private func detachTab(_ tabID: UUID, closeIfEmpty: Bool = true) -> DetachedTabContext? {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              let pdfManager = pdfManagers[tabID],
              let searchManager = searchManagers[tabID],
              let annotationManager = annotationManagers[tabID],
              let commentManager = commentManagers[tabID],
              let bookmarkManager = bookmarkManagers[tabID],
              let undoManager = undoManagers[tabID] else {
            return nil
        }

        if activeTabID == tabID {
            saveCurrentTabState()
        }

        if activeTabID == tabID && (tabUIStates[tabID]?.isEditingPages ?? false) {
            stopEditModeKeyMonitor()
        }

        let detachedPendingPasswordRequest = pendingPasswordRequest?.tabID == tabID ? pendingPasswordRequest : nil
        let detachedQueuedPasswordRequests = queuedPasswordRequests.filter { $0.tabID == tabID }

        if detachedPendingPasswordRequest != nil {
            self.pendingPasswordRequest = nil
            advancePasswordRequestQueue()
        }
        self.queuedPasswordRequests.removeAll { $0.tabID == tabID }

        let detachedTab = DetachedTabContext(
            tab: tabs[index],
            pdfManager: pdfManager,
            searchManager: searchManager,
            annotationManager: annotationManager,
            commentManager: commentManager,
            bookmarkManager: bookmarkManager,
            undoManager: undoManager,
            uiState: tabUIStates[tabID] ?? TabUIState(),
            pendingPasswordRequest: detachedPendingPasswordRequest,
            queuedPasswordRequests: detachedQueuedPasswordRequests
        )

        removeUndoObserver(for: tabID)
        tabs.remove(at: index)
        pdfManagers.removeValue(forKey: tabID)
        searchManagers.removeValue(forKey: tabID)
        annotationManagers.removeValue(forKey: tabID)
        commentManagers.removeValue(forKey: tabID)
        bookmarkManagers.removeValue(forKey: tabID)
        undoManagers.removeValue(forKey: tabID)
        undoAvailabilityByTab.removeValue(forKey: tabID)
        tabUIStates.removeValue(forKey: tabID)

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
        _ detachedTab: DetachedTabContext,
        at index: Int,
        select: Bool = true
    ) {
        if select {
            saveCurrentTabState()
        }

        let clampedIndex = min(max(index, 0), tabs.count)
        var attachedTab = detachedTab.tab
        if let documentURL = attachedTab.documentURL {
            attachedTab.title = detachedTab.pdfManager.documentTitle.isEmpty
                ? documentURL.deletingPathExtension().lastPathComponent
                : detachedTab.pdfManager.documentTitle
        }
        tabs.insert(attachedTab, at: clampedIndex)
        pdfManagers[detachedTab.tab.id] = detachedTab.pdfManager
        searchManagers[detachedTab.tab.id] = detachedTab.searchManager
        annotationManagers[detachedTab.tab.id] = detachedTab.annotationManager
        commentManagers[detachedTab.tab.id] = detachedTab.commentManager
        bookmarkManagers[detachedTab.tab.id] = detachedTab.bookmarkManager
        tabUIStates[detachedTab.tab.id] = detachedTab.uiState
        installUndoManager(detachedTab.undoManager, for: detachedTab.tab.id)
        restorePasswordRequests(
            pending: detachedTab.pendingPasswordRequest,
            queued: detachedTab.queuedPasswordRequests
        )
        if select {
            selectTab(detachedTab.tab.id)
        }
    }

    private func restorePasswordRequests(
        pending: PasswordRequest?,
        queued: [PasswordRequest]
    ) {
        if let pending {
            if pendingPasswordRequest == nil {
                pendingPasswordRequest = pending
            } else {
                queuedPasswordRequests.append(pending)
            }
        }

        if !queued.isEmpty {
            queuedPasswordRequests.append(contentsOf: queued)
        }
    }

    // MARK: - Cleanup

    private func cleanupManagers(for tabID: UUID) {
        removeUndoObserver(for: tabID)
        pdfManagers[tabID]?.closeDocument()
        commentManagers[tabID]?.clearComments()
        bookmarkManagers[tabID]?.clearBookmarks()

        undoManagers[tabID]?.removeAllActions()
        pdfManagers.removeValue(forKey: tabID)
        searchManagers.removeValue(forKey: tabID)
        annotationManagers.removeValue(forKey: tabID)
        commentManagers.removeValue(forKey: tabID)
        bookmarkManagers.removeValue(forKey: tabID)
        undoManagers.removeValue(forKey: tabID)
        undoAvailabilityByTab.removeValue(forKey: tabID)

        tabUIStates.removeValue(forKey: tabID)

        // Clear pending password dialog if it was for this tab
        clearPendingPasswordRequest(for: tabID)
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
