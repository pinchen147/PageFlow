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

@Observable
@MainActor
final class TabManager {
    deinit {
        if let monitor = editModeKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        #if DEBUG
        Swift.print("[deinit] TabManager")
        #endif
    }

    // MARK: - Properties

    var tabs: [TabModel] = []
    var activeTabID: UUID?

    // Per-tab runtime state (not persisted)
    private var pdfManagers: [UUID: PDFManager] = [:]
    private var searchManagers: [UUID: SearchManager] = [:]
    private var annotationManagers: [UUID: AnnotationManager] = [:]
    private var commentManagers: [UUID: CommentManager] = [:]
    private var bookmarkManagers: [UUID: BookmarkManager] = [:]

    // Per-tab UI state (not persisted) - internal for MainView access
    var showingOutlineState: [UUID: Bool] = [:]
    var showingCommentsState: [UUID: Bool] = [:]
    var showingGoToPageState: [UUID: Bool] = [:]
    var showingFileImporterState: [UUID: Bool] = [:]
    var isEditingPagesState: [UUID: Bool] = [:]

    // Edit mode keyboard shortcut monitor (intercepts Cmd+C/V for page copy/paste)
    @ObservationIgnored private var editModeKeyMonitor: Any?

    // Track open file picker panel for closing on drag-drop
    private weak var openPanel: NSOpenPanel?

    // Password dialog state
    var pendingPasswordRequest: PasswordRequest?

    struct PasswordRequest: Identifiable {
        let id = UUID()
        let tabID: UUID
        let url: URL
        let isSecurityScoped: Bool
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

    // MARK: - Sidebar State (Active Tab)

    var showingOutline: Bool {
        get {
            guard let id = activeTabID else { return false }
            return showingOutlineState[id] ?? false
        }
        set {
            guard let id = activeTabID else { return }
            showingOutlineState[id] = newValue
        }
    }

    var showingComments: Bool {
        get {
            guard let id = activeTabID else { return false }
            return showingCommentsState[id] ?? false
        }
        set {
            guard let id = activeTabID else { return }
            showingCommentsState[id] = newValue
        }
    }

    var showingGoToPage: Bool {
        get {
            guard let id = activeTabID else { return false }
            return showingGoToPageState[id] ?? false
        }
        set {
            guard let id = activeTabID else { return }
            showingGoToPageState[id] = newValue
        }
    }

    var showingFileImporter: Bool {
        get {
            guard let id = activeTabID else { return false }
            return showingFileImporterState[id] ?? false
        }
        set {
            guard let id = activeTabID else { return }
            showingFileImporterState[id] = newValue
        }
    }

    var isEditingPages: Bool {
        get {
            guard let id = activeTabID else { return false }
            return isEditingPagesState[id] ?? false
        }
        set {
            guard let id = activeTabID else { return }
            let wasEditing = isEditingPagesState[id] ?? false
            isEditingPagesState[id] = newValue

            // Start/stop keyboard monitor when edit mode changes
            if newValue && !wasEditing {
                startEditModeKeyMonitor()
            } else if !newValue && wasEditing {
                stopEditModeKeyMonitor()
            }
        }
    }

    func sidebarState(for tabID: UUID) -> (showingOutline: Bool, showingComments: Bool) {
        (showingOutlineState[tabID] ?? false, showingCommentsState[tabID] ?? false)
    }

    func setShowingOutline(_ value: Bool, for tabID: UUID) {
        showingOutlineState[tabID] = value
    }

    func setShowingComments(_ value: Bool, for tabID: UUID) {
        showingCommentsState[tabID] = value
    }

    func setShowingGoToPage(_ value: Bool, for tabID: UUID) {
        showingGoToPageState[tabID] = value
    }

    func setShowingFileImporter(_ value: Bool, for tabID: UUID) {
        showingFileImporterState[tabID] = value
    }

    /// Opens NSOpenPanel directly - waits for window readiness
    func openFilePicker(retryCount: Int = 0) {
        // NSOpenPanel.begin() requires a key window - wait if not ready
        guard NSApp.keyWindow != nil else {
            guard retryCount < 10 else { return }  // Max 1 second total
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.openFilePicker(retryCount: retryCount + 1)
            }
            return
        }

        // Close any existing panel first
        openPanel?.close()

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Select a PDF file to open"

        openPanel = panel

        panel.begin { [weak self] response in
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

    init() {
        let initialTab = TabModel()
        tabs = [initialTab]
        activeTabID = initialTab.id
        createManagersForTab(initialTab)
    }

    // MARK: - Tab Operations

    func createNewTab(with url: URL? = nil, isSecurityScoped: Bool = false) {
        // Preserve state of current tab before switching away
        saveCurrentTabState()

        let newTab = TabModel(documentURL: url, isSecurityScoped: isSecurityScoped)

        tabs.append(newTab)
        createManagersForTab(newTab)
        activeTabID = newTab.id

        if let url = url {
            let result = pdfManagers[newTab.id]?.loadDocument(from: url, isSecurityScoped: isSecurityScoped) ?? .failed
            handleLoadResult(result, for: newTab.id, url: url, isSecurityScoped: isSecurityScoped)
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
        if activeTabID == tabID && (isEditingPagesState[tabID] ?? false) {
            stopEditModeKeyMonitor()
        }

        // Note: closeDocument() in cleanupManagers handles undo cleanup via undoManagerProvider
        // which correctly targets this tab's window, not keyWindow (fixes multi-window scenarios)
        cleanupManagers(for: tabID)
        tabs.remove(at: index)

        // Handle tab selection after close
        if tabs.isEmpty {
            NSApplication.shared.keyWindow?.close()
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
        clearUndoStack()
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

    // MARK: - Document Operations

    func openDocument(url: URL, isSecurityScoped: Bool, replaceCurrent: Bool = false) {
        // If current tab is empty or replace is requested, load into current tab; otherwise create new tab
        if let activeTab = activeTab,
           let activeID = activeTabID,
           (replaceCurrent || !activeTab.hasDocument),
           let pdfManager = pdfManagers[activeID] {
            // Clear undo stack when replacing document to prevent dangling references
            if activeTab.hasDocument {
                NSApp.keyWindow?.undoManager?.removeAllActions()
            }
            let result = pdfManager.loadDocument(from: url, isSecurityScoped: isSecurityScoped)
            handleLoadResult(result, for: activeID, url: url, isSecurityScoped: isSecurityScoped)
        } else {
            // Current tab has a document, create new tab
            saveCurrentTabState()
            createNewTab(with: url, isSecurityScoped: isSecurityScoped)
        }
    }

    private func handleLoadResult(_ result: DocumentLoadResult, for tabID: UUID, url: URL, isSecurityScoped: Bool) {
        switch result {
        case .success:
            if let index = tabs.firstIndex(where: { $0.id == tabID }) {
                tabs[index].documentURL = url
                tabs[index].isSecurityScoped = isSecurityScoped
            }
        case .needsPassword:
            promptForPassword(tabID: tabID, url: url, isSecurityScoped: isSecurityScoped)
        case .failed:
            break
        }
    }

    private func promptForPassword(tabID: UUID, url: URL, isSecurityScoped: Bool) {
        pendingPasswordRequest = PasswordRequest(
            tabID: tabID,
            url: url,
            isSecurityScoped: isSecurityScoped
        )
    }

    func submitPassword(_ password: String) -> Bool {
        guard let request = pendingPasswordRequest,
              let pdfManager = pdfManagers[request.tabID] else {
            return false
        }

        if pdfManager.unlockDocument(password: password) {
            if let index = tabs.firstIndex(where: { $0.id == request.tabID }) {
                tabs[index].documentURL = request.url
                tabs[index].isSecurityScoped = request.isSecurityScoped
            }
            pendingPasswordRequest = nil
            return true
        }
        return false
    }

    func cancelPasswordPrompt() {
        guard let request = pendingPasswordRequest else { return }
        pdfManagers[request.tabID]?.cancelPendingUnlock()
        pendingPasswordRequest = nil
    }

    func updateTabDocument(_ tabID: UUID, url: URL) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].documentURL = url
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
        let bookmarkManager = BookmarkManager()
        // Note: bookmarkManager.configure() is called in PDFViewWrapper.makeNSView()
        // when the undoManagerProvider is available

        pdfManagers[tab.id] = pdfManager
        searchManagers[tab.id] = SearchManager()
        annotationManagers[tab.id] = AnnotationManager()
        commentManagers[tab.id] = CommentManager()
        bookmarkManagers[tab.id] = bookmarkManager
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
            pdfManager.setZoom(tab.savedScaleFactor)
        }

        if !tab.savedSearchQuery.isEmpty {
            searchManager.searchQuery = tab.savedSearchQuery
            searchManager.currentResultIndex = tab.savedSearchResultIndex
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
            return .failure(message: "Save As cancelled.")
        }

        let saved = await pdfManager.saveAs(to: url)
        if saved, let index = tabs.firstIndex(where: { $0.id == id }) {
            tabs[index].documentURL = url
        }

        let result: SaveResult = saved ? .success(message: "Saved As") : .failure(message: "Save As failed.")
        postSaveNotification(result)
        return result
    }

    // MARK: - Notifications
    private func postSaveNotification(_ result: SaveResult) {
        switch result {
        case .success(let message):
            NotificationCenter.default.post(
                name: .saveResult,
                object: nil,
                userInfo: ["message": message]
            )
        case .failure:
            break
        }
    }

    // MARK: - Undo Stack Management

    private func clearUndoStack() {
        NSApp.keyWindow?.undoManager?.removeAllActions()
    }

    private func cleanupManagers(for tabID: UUID) {
        pdfManagers[tabID]?.closeDocument()
        commentManagers[tabID]?.clearComments()
        bookmarkManagers[tabID]?.clearBookmarks()

        pdfManagers.removeValue(forKey: tabID)
        searchManagers.removeValue(forKey: tabID)
        annotationManagers.removeValue(forKey: tabID)
        commentManagers.removeValue(forKey: tabID)
        bookmarkManagers.removeValue(forKey: tabID)

        // Clean up UI state dictionaries to prevent memory leak
        showingOutlineState.removeValue(forKey: tabID)
        showingCommentsState.removeValue(forKey: tabID)
        showingGoToPageState.removeValue(forKey: tabID)
        showingFileImporterState.removeValue(forKey: tabID)
        isEditingPagesState.removeValue(forKey: tabID)

        // Clear pending password dialog if it was for this tab
        if pendingPasswordRequest?.tabID == tabID {
            pendingPasswordRequest = nil
        }
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
