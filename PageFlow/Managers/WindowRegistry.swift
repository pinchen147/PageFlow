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
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private let lock = NSLock()

    private init() {}

    func register(_ tabManager: TabManager, window: NSWindow?) {
        lock.withLock {
            entries[ObjectIdentifier(tabManager)] = Entry(tabManager: tabManager, window: window)
        }

        // Deliver any URLs buffered during cold launch (before this TabManager existed)
        DispatchQueue.main.async {
            guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
            appDelegate.flushPendingURLs(to: tabManager)
        }
    }

    func unregister(_ tabManager: TabManager) {
        _ = lock.withLock {
            entries.removeValue(forKey: ObjectIdentifier(tabManager))
        }
    }

    func allDirtyPDFManagers() -> [(UUID, PDFManager)] {
        lock.withLock {
            entries.values.flatMap { $0.tabManager.dirtyPDFManagers() }
        }
    }

    /// Returns the first available TabManager (for opening files from Finder)
    func anyTabManager() -> TabManager? {
        lock.withLock {
            entries.values.first?.tabManager
        }
    }

    /// Activates an existing tab for a URL if already open. Returns true if handled.
    func activateExistingDocument(for url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let match: (TabManager, UUID, NSWindow?)? = lock.withLock {
            for entry in entries.values {
                if let tabID = entry.tabManager.tabID(for: standardized) {
                    return (entry.tabManager, tabID, entry.window)
                }
            }
            return nil
        }

        guard let (tabManager, tabID, window) = match else { return false }
        tabManager.selectTab(tabID)
        window?.makeKeyAndOrderFront(nil)
        return true
    }
}
