//
//  AppDelegate.swift
//  PageFlow
//
//  Handles app-level termination prompts for unsaved documents.
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

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
                _ = manager.save()
            }
            return .terminateNow
        case .alertSecondButtonReturn:
            return .terminateCancel
        default:
            return .terminateNow
        }
    }
}
