//
//  TabManager.swift
//  PageFlow
//
//  Tab state management with session persistence
//

import Foundation
import AppKit
import SwiftUI

@Observable
class TabManager {
    // MARK: - Properties

    var tabs: [TabModel] = []
    var activeTabID: UUID?

    // Per-tab runtime state (not persisted)
    private var pdfManagers: [UUID: PDFManager] = [:]
    private var searchManagers: [UUID: SearchManager] = [:]

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
        var newTab = TabModel(documentURL: url, isSecurityScoped: isSecurityScoped)

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

        // Clean up managers
        pdfManagers[tabID]?.closeDocument()
        pdfManagers.removeValue(forKey: tabID)
        searchManagers.removeValue(forKey: tabID)

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

    func openDocument(url: URL, isSecurityScoped: Bool) {
        // If current tab is empty, use it; otherwise create new tab
        if let activeTab = activeTab, !activeTab.hasDocument {
            // Load document in current empty tab
            if let activeID = activeTabID,
               let pdfManager = pdfManagers[activeID] {
                if pdfManager.loadDocument(from: url, isSecurityScoped: isSecurityScoped) {
                    // Update tab with document info
                    if let index = tabs.firstIndex(where: { $0.id == activeID }) {
                        tabs[index].documentURL = url
                        tabs[index].isSecurityScoped = isSecurityScoped
                    }
                }
            }
        } else {
            // Current tab has a document, create new tab
            createNewTab(with: url, isSecurityScoped: isSecurityScoped)
        }
    }

    func updateTabDocument(_ tabID: UUID, url: URL) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].documentURL = url
    }

    // MARK: - State Management

    private func createManagersForTab(_ tab: TabModel) {
        pdfManagers[tab.id] = PDFManager()
        searchManagers[tab.id] = SearchManager()
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
        }
        tabs.removeAll()
        pdfManagers.removeAll()
        searchManagers.removeAll()

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
