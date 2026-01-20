//
//  AppDelegate.swift
//  PageFlow
//
//  Handles app-level termination prompts for unsaved documents.
//

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let firstLaunchManager = FirstLaunchManager()
    private var windowControllers: [NSWindowController] = []

    func createNewWindow(with contentView: some View) {
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(NSSize(width: 900, height: 700))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()

        let windowController = NSWindowController(window: window)
        windowControllers.append(windowController)

        // Clean up when window closes
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak windowController] _ in
            guard let self = self, let wc = windowController else { return }
            self.windowControllers.removeAll { $0 === wc }
        }

        windowController.showWindow(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        firstLaunchManager.handleFirstLaunch()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let pdfURLs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfURLs.isEmpty else { return }

        // Open in existing window if available, otherwise SwiftUI will create new window
        if let tabManager = WindowRegistry.shared.anyTabManager() {
            for url in pdfURLs {
                tabManager.openDocument(url: url, isSecurityScoped: false)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirtyEntries = WindowRegistry.shared.allDirtyPDFManagers()

        guard let firstDirty = dirtyEntries.first else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Do you want to save changes before quitting?"
        alert.informativeText = "Your changes to \"\(firstDirty.1.documentTitle)\" will be lost if you don't save."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for (_, manager) in dirtyEntries {
                _ = manager.saveSync()  // Use sync for quit-time saves
            }
            return .terminateNow
        case .alertSecondButtonReturn:
            return .terminateCancel
        default:
            return .terminateNow
        }
    }
}
