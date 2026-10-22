//
//  ShortcutMenuRefresh.swift
//  PageFlow
//
//  SwiftUI gives a menu item a changed key equivalent only when its menu
//  updates, which happens as the menu opens; until then the old key stays
//  live and the new one does nothing. A rebinding in Settings > Shortcuts
//  must work from the keyboard at once, so the menu bar updates whenever a
//  shortcut changes and whenever a window becomes key.
//

import AppKit

@MainActor
enum ShortcutMenuRefresh {
    private static var observers: [NSObjectProtocol] = []

    static func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addMainActorObserver(forName: SettingsManager.shortcutsDidChange) {
            // After SwiftUI has re-run the commands with the new keys.
            DispatchQueue.main.async { refreshMainMenu() }
        })
        observers.append(center.addMainActorObserver(forName: NSWindow.didBecomeKeyNotification) {
            refreshMainMenu()
        })
    }

    /// Lets each top-level menu bring its items up to date, as opening it would.
    static func refreshMainMenu() {
        for item in NSApp.mainMenu?.items ?? [] {
            guard let submenu = item.submenu else { continue }
            submenu.delegate?.menuNeedsUpdate?(submenu)
            submenu.update()
        }
    }
}
