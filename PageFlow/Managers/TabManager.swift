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
class TabManager {
    // MARK: - Properties

    var tabs: [TabModel] = []
    var activeTabID: UUID?

    // Per-tab runtime state (not persisted)
    private var pdfManagers: [UUID: PDFManager] = [:]
    private var searchManagers: [UUID: SearchManager] = [:]
    private var annotationManagers: [UUID: AnnotationManager] = [:]
    private var commentManagers: [UUID: CommentManager] = [:]

    // Session persistence
    private let sessionKey = "tabSession"
    private let activeIndexKey = "tabSession_activeIndex"
    private let defaults = UserDefaults.standard

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
            _ = pdfManagers[newTab.id]?.loadDocument(from: url, isSecurityScoped: isSecurityScoped)
            // Update tab with actual title after loading
            if let index = tabs.firstIndex(where: { $0.id == newTab.id }) {
                tabs[index].documentURL = url
            }
        }
    }

    func closeTab(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }

        if let pdfManager = pdfManagers[tabID],
           pdfManager.isDirty,
           !confirmClose(tabID: tabID, pdfManager: pdfManager) {
            return
        }

        // Clean up managers
        pdfManagers[tabID]?.closeDocument()
        commentManagers[tabID]?.clearComments()
        pdfManagers.removeValue(forKey: tabID)
        searchManagers.removeValue(forKey: tabID)
        annotationManagers.removeValue(forKey: tabID)
        commentManagers.removeValue(forKey: tabID)

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

        // Save current tab state before switching
        saveCurrentTabState()

        activeTabID = tabID

        // Restore saved state for newly active tab
        restoreTabState(tabID)
    }

    func selectTabByIndex(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        selectTab(tabs[index].id)
    }

    func selectNextTab() {
        guard let currentIndex = activeTabIndex else { return }
        let nextIndex = (currentIndex + 1) % tabs.count
        selectTab(tabs[nextIndex].id)
    }

    func selectPreviousTab() {
        guard let currentIndex = activeTabIndex else { return }
        let previousIndex = (currentIndex - 1 + tabs.count) % tabs.count
        selectTab(tabs[previousIndex].id)
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
            if pdfManager.loadDocument(from: url, isSecurityScoped: isSecurityScoped) {
                if let index = tabs.firstIndex(where: { $0.id == activeID }) {
                    tabs[index].documentURL = url
                    tabs[index].isSecurityScoped = isSecurityScoped
                }
            }
        } else {
            // Current tab has a document, create new tab
            saveCurrentTabState()
            createNewTab(with: url, isSecurityScoped: isSecurityScoped)
        }
    }

    func updateTabDocument(_ tabID: UUID, url: URL) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].documentURL = url
    }

    func managers(for tabID: UUID) -> (PDFManager, SearchManager, AnnotationManager, CommentManager)? {
        guard let pdfManager = pdfManagers[tabID],
              let searchManager = searchManagers[tabID],
              let annotationManager = annotationManagers[tabID],
              let commentManager = commentManagers[tabID] else {
            return nil
        }
        return (pdfManager, searchManager, annotationManager, commentManager)
    }

    // MARK: - State Management

    private func createManagersForTab(_ tab: TabModel) {
        pdfManagers[tab.id] = PDFManager()
        searchManagers[tab.id] = SearchManager()
        annotationManagers[tab.id] = AnnotationManager()
        commentManagers[tab.id] = CommentManager()
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
        alert.informativeText = "Your changes will be lost if you don’t save."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return pdfManager.save()
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

    func saveActiveDocument() -> SaveResult {
        guard let id = activeTabID,
              let pdfManager = pdfManagers[id] else {
            return .failure(message: "No active document to save.")
        }

        guard pdfManager.hasDocument else {
            return .failure(message: "Open a document before saving.")
        }

        let saved = pdfManager.save()
        let result: SaveResult = saved ? .success(message: "Saved") : .failure(message: "Save failed.")
        postSaveNotification(result)
        return result
    }

    func saveActiveDocumentAs() -> SaveResult {
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

        let saved = pdfManager.saveAs(to: url)
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

    // MARK: - Session Persistence

    func saveSession() {
        saveCurrentTabState()

        // Filter to tabs with actual documents
        let persistableTabs = tabs.filter { $0.documentURL != nil }

        guard let data = try? JSONEncoder().encode(persistableTabs) else { return }
        defaults.set(data, forKey: sessionKey)

        if let activeIndex = activeTabIndex {
            defaults.set(activeIndex, forKey: activeIndexKey)
        }
    }

    func restoreSession() {
        guard let data = defaults.data(forKey: sessionKey),
              let savedTabs = try? JSONDecoder().decode([TabModel].self, from: data),
              !savedTabs.isEmpty else {
            return
        }

        // Clear initial empty tab
        for tab in tabs {
            pdfManagers[tab.id]?.closeDocument()
            commentManagers[tab.id]?.clearComments()
        }
        tabs.removeAll()
        pdfManagers.removeAll()
        searchManagers.removeAll()
        annotationManagers.removeAll()
        commentManagers.removeAll()

        // Restore each tab - only keep if document loads successfully
        for tab in savedTabs {
            guard let url = tab.documentURL else { continue }

            let restoredTab = tab
            createManagersForTab(restoredTab)

            // Only add tab if document loads successfully
            if pdfManagers[tab.id]?.loadDocument(from: url, isSecurityScoped: false) == true {
                tabs.append(restoredTab)
            } else {
                // Clean up managers if load failed
                pdfManagers.removeValue(forKey: tab.id)
                searchManagers.removeValue(forKey: tab.id)
                annotationManagers.removeValue(forKey: tab.id)
                commentManagers.removeValue(forKey: tab.id)
            }
        }

        // Restore active tab
        let savedIndex = defaults.integer(forKey: activeIndexKey)
        if savedIndex < tabs.count {
            activeTabID = tabs[savedIndex].id
        } else {
            activeTabID = tabs.first?.id
        }

        // If no tabs were restored, create an empty one
        if tabs.isEmpty {
            let emptyTab = TabModel()
            tabs = [emptyTab]
            activeTabID = emptyTab.id
            createManagersForTab(emptyTab)
        }
    }

    func clearSession() {
        defaults.removeObject(forKey: sessionKey)
        defaults.removeObject(forKey: activeIndexKey)
    }
}
