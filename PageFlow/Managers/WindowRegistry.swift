//
//  WindowRegistry.swift
//  PageFlow
//
//  Tracks all TabManagers across windows for app-level operations (e.g., quit prompts).
//

import Foundation
import AppKit

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
    private let lock = NSLock()
    private var pendingTransientPlaceholderDismissals = 0
    private var transientPlaceholderDismissalLowerBound: Date?
    private var transientPlaceholderDismissalDeadline: Date?

    private init() {}

    func register(_ tabManager: TabManager, window: NSWindow?) {
        lock.withLock {
            entries[ObjectIdentifier(tabManager)] = Entry(
                tabManager: tabManager,
                window: window,
                isUserCreated: window?.identifier == PageFlowWindowIdentifiers.userCreated,
                registeredAt: Date()
            )
            if window?.isMainWindow == true {
                lastActiveTabManager = tabManager
            }
        }

        if let window {
            let token = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeMainNotification,
                object: window,
                queue: .main
            ) { [weak self, weak tabManager] _ in
                guard let self, let tabManager else { return }
                self.lock.withLock {
                    self.lastActiveTabManager = tabManager
                }
            }
            lock.withLock {
                mainWindowObservers[ObjectIdentifier(tabManager)] = token
            }
        }

        dismissPendingTransientPlaceholderWindows()

        // Deliver any URLs buffered during cold launch (before this TabManager existed)
        DispatchQueue.main.async {
            guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
            appDelegate.flushPendingURLs(to: tabManager)
        }
    }

    func unregister(_ tabManager: TabManager) {
        let token: NSObjectProtocol? = lock.withLock {
            entries.removeValue(forKey: ObjectIdentifier(tabManager))
            if lastActiveTabManager === tabManager {
                lastActiveTabManager = nil
            }
            return mainWindowObservers.removeValue(forKey: ObjectIdentifier(tabManager))
        }
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func allDirtyPDFManagers() -> [(UUID, PDFManager)] {
        lock.withLock {
            entries.values
                .filter { $0.window != nil }
                .flatMap { $0.tabManager.dirtyPDFManagers() }
        }
    }

    /// Returns the TabManager for the PageFlow window that was most recently
    /// the main window. Remains correct even after Settings (or another
    /// utility panel) has taken over `keyWindow`/`mainWindow`.
    func frontmostTabManager() -> TabManager? {
        let (tracked, values) = lock.withLock {
            (lastActiveTabManager, Array(entries.values).filter { $0.window != nil })
        }

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

    /// Returns the first available TabManager (for opening files from Finder)
    func anyTabManager() -> TabManager? {
        let values = lock.withLock {
            Array(entries.values).filter { $0.window != nil }
        }

        return preferredEntry(from: values)?.tabManager
    }

    /// Activates an existing tab for a URL if already open. Returns true if handled.
    func activateExistingDocument(for url: URL) -> Bool {
        let canonicalURL = url.pageFlowCanonicalDocumentURL
        let match: (TabManager, UUID, NSWindow?)? = lock.withLock {
            for entry in entries.values {
                guard let window = entry.window else { continue }
                if let tabID = entry.tabManager.tabID(for: canonicalURL) {
                    return (entry.tabManager, tabID, window)
                }
            }
            return nil
        }

        guard let (tabManager, tabID, window) = match else { return false }
        tabManager.selectTab(tabID)
        bringWindowToFront(window)
        return true
    }

    /// Brings the given window to the front, handling minimized state and background app activation.
    private func bringWindowToFront(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)

        guard let window = window else { return }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func closeWindow(for tabManager: TabManager) {
        DispatchQueue.main.async { [self] in
            let window = lock.withLock {
                entries[ObjectIdentifier(tabManager)]?.window
            }
            window?.close()
        }
    }

    /// Closes one transient placeholder window created by an external open event that
    /// rerouted into an existing PageFlow window.
    func dismissTransientPlaceholderWindowForExternalOpen(within seconds: TimeInterval = 1.0) {
        let now = Date()
        lock.withLock {
            pendingTransientPlaceholderDismissals = 1
            transientPlaceholderDismissalLowerBound = now.addingTimeInterval(-seconds)
            transientPlaceholderDismissalDeadline = now.addingTimeInterval(seconds)
        }
        dismissPendingTransientPlaceholderWindows()
    }

    /// Activates the app and brings the given TabManager's window to the front.
    func bringToFront(for tabManager: TabManager) {
        let window = lock.withLock {
            entries[ObjectIdentifier(tabManager)]?.window
        }
        bringWindowToFront(window)
    }

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

    private func dismissPendingTransientPlaceholderWindows() {
        let tabManagers: [TabManager] = lock.withLock {
            pruneExpiredTransientPlaceholderDismissals()

            guard pendingTransientPlaceholderDismissals > 0,
                  let lowerBound = transientPlaceholderDismissalLowerBound else {
                return [TabManager]()
            }

            return entries.values
                .filter { $0.window != nil }
                .filter { !$0.isUserCreated }
                .filter { $0.registeredAt >= lowerBound }
                .sorted { $0.registeredAt > $1.registeredAt }
                .map(\.tabManager)
        }

        for tabManager in tabManagers {
            if tabManager.dismissPlaceholderWindowIfNeeded() {
                lock.withLock {
                    pendingTransientPlaceholderDismissals = max(0, pendingTransientPlaceholderDismissals - 1)
                    if pendingTransientPlaceholderDismissals == 0 {
                        transientPlaceholderDismissalLowerBound = nil
                        transientPlaceholderDismissalDeadline = nil
                    }
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
}
