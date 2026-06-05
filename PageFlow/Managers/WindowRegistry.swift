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
    private weak var lastActiveTabManager: TabManager?

    private var pendingTransientPlaceholderDismissals = 0
    private var transientPlaceholderDismissalLowerBound: Date?
    private var transientPlaceholderDismissalDeadline: Date?

    private init() {}

    // MARK: - Registration

    func register(_ tabManager: TabManager, window: NSWindow?) {
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
            let token = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeMainNotification,
                object: window,
                queue: .main
            ) { [weak self, weak tabManager] _ in
                MainActor.assumeIsolated {
                    guard let self, let tabManager else { return }
                    self.lastActiveTabManager = tabManager
                }
            }
            mainWindowObservers[ObjectIdentifier(tabManager)] = token
        }

        dismissPendingTransientPlaceholderWindows()

        // Deliver any URLs buffered during cold launch (before this TabManager existed).
        Task { @MainActor in
            guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
            appDelegate.flushPendingURLs(to: tabManager)
        }
    }

    func unregister(_ tabManager: TabManager) {
        entries.removeValue(forKey: ObjectIdentifier(tabManager))
        if lastActiveTabManager === tabManager {
            lastActiveTabManager = nil
        }
        let token = mainWindowObservers.removeValue(forKey: ObjectIdentifier(tabManager))
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Lookups

    func allDirtyPDFManagers() -> [(UUID, PDFManager)] {
        entries.values
            .filter { $0.window != nil }
            .flatMap { $0.tabManager.dirtyPDFManagers() }
    }

    /// Persists every open window's active-tab reading position to the store.
    /// Called on app termination so the last position survives a quit.
    func flushAllViewState() {
        for entry in entries.values where entry.window != nil {
            entry.tabManager.flushActiveTabViewState()
        }
    }

    /// TabManager whose window was most recently main. Stays correct even
    /// after Settings or another panel has stolen `keyWindow`/`mainWindow`.
    func frontmostTabManager() -> TabManager? {
        let tracked = lastActiveTabManager
        let values = Array(entries.values).filter { $0.window != nil }

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
        let values = Array(entries.values).filter { $0.window != nil }
        return preferredEntry(from: values)?.tabManager
    }

    /// Whether `url`'s document is already open in any registered window. A
    /// read-only counterpart to `activateExistingDocument` — it never changes focus.
    func isDocumentOpen(_ url: URL) -> Bool {
        let canonicalURL = url.pageFlowCanonicalDocumentURL
        for entry in entries.values where entry.window != nil {
            if entry.tabManager.tabID(for: canonicalURL) != nil { return true }
        }
        return false
    }

    /// Activates an existing tab for the given URL if already open. Returns
    /// `true` if handled (caller should not create a new tab/window).
    func activateExistingDocument(for url: URL) -> Bool {
        let canonicalURL = url.pageFlowCanonicalDocumentURL
        let match: (TabManager, UUID, NSWindow?)? = {
            for entry in entries.values {
                guard let window = entry.window else { continue }
                if let tabID = entry.tabManager.tabID(for: canonicalURL) {
                    return (entry.tabManager, tabID, window)
                }
            }
            return nil
        }()

        guard let (tabManager, tabID, window) = match else { return false }
        tabManager.selectTab(tabID)
        bringWindowToFront(window)
        return true
    }

    // MARK: - Window Front/Close

    func closeWindow(for tabManager: TabManager) {
        let window = entries[ObjectIdentifier(tabManager)]?.window
        DispatchQueue.main.async {
            window?.close()
        }
    }

    func bringToFront(for tabManager: TabManager) {
        let window = entries[ObjectIdentifier(tabManager)]?.window
        bringWindowToFront(window)
    }

    private func bringWindowToFront(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
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
