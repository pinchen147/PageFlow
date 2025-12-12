//
//  WindowRegistry.swift
//  PageFlow
//
//  Tracks all TabManagers across windows for app-level operations (e.g., quit prompts).
//

import Foundation

final class WindowRegistry {
    static let shared = WindowRegistry()

    private var tabManagers: [ObjectIdentifier: TabManager] = [:]
    private let lock = NSLock()

    private init() {}

    func register(_ tabManager: TabManager) {
        lock.withLock {
            tabManagers[ObjectIdentifier(tabManager)] = tabManager
        }
    }

    func unregister(_ tabManager: TabManager) {
        lock.withLock {
            tabManagers.removeValue(forKey: ObjectIdentifier(tabManager))
        }
    }

    func allDirtyPDFManagers() -> [(UUID, PDFManager)] {
        lock.withLock {
            tabManagers.values.flatMap { $0.dirtyPDFManagers() }
        }
    }
}
