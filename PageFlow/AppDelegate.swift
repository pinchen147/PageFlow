//
//  AppDelegate.swift
//  PageFlow
//
//  Handles app-level termination prompts for unsaved documents.
//

import AppKit
import SwiftUI

enum PageFlowWindowIdentifiers {
    static let userCreated = NSUserInterfaceItemIdentifier("PageFlowUserCreatedWindow")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    struct PendingDocumentOpen {
        let url: URL
        let isSecurityScoped: Bool
    }

    private let firstLaunchManager = FirstLaunchManager()
    private var windowControllers: [NSWindowController] = []
    private var windowCloseObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// Builds the SwiftUI root view for a new window, wrapping the passed-in
    /// (pre-populated) TabManager. Set once by `PageFlowApp` at launch. Nil
    /// means "a window was requested before PageFlowApp installed the builder"
    /// — which should never happen, but if it does we fail loud.
    var windowContentBuilder: ((TabManager) -> AnyView)?

    /// URLs received before any TabManager registered (cold launch from Finder)
    private(set) var pendingDocumentOpens: [PendingDocumentOpen] = []

    var pendingURLs: [URL] {
        pendingDocumentOpens.map(\.url)
    }

    func enqueuePendingURLs(_ urls: [URL], isSecurityScoped: Bool = false) {
        let pdfURLs = urls
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .map(\.pageFlowCanonicalDocumentURL)
        pendingDocumentOpens.append(contentsOf: pdfURLs.map {
            PendingDocumentOpen(url: $0, isSecurityScoped: isSecurityScoped)
        })
    }

    @discardableResult
    func createNewWindow(
        with contentView: some View,
        screenPoint: CGPoint? = nil,
        frame: NSRect? = nil
    ) -> NSWindow {
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(contentViewController: hostingController)
        let contentSize = frame?.size
            ?? NSSize(width: DesignTokens.defaultWindowWidth, height: DesignTokens.defaultWindowHeight)
        window.setContentSize(contentSize)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.identifier = PageFlowWindowIdentifiers.userCreated
        if let frame {
            window.setFrame(frame, display: false)
        } else {
            positionWindow(window, contentSize: contentSize, near: screenPoint)
        }

        let windowController = NSWindowController(window: window)
        windowControllers.append(windowController)
        let controllerID = ObjectIdentifier(windowController)

        // Clean up when window closes
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak windowController] _ in
            guard let self = self else { return }
            if let wc = windowController {
                self.windowControllers.removeAll { $0 === wc }
            }
            if let token = self.windowCloseObservers.removeValue(forKey: controllerID) {
                NotificationCenter.default.removeObserver(token)
            }
        }
        windowCloseObservers[controllerID] = observer

        windowController.showWindow(nil)
        return window
    }

    /// Creates a window hosting the given (pre-populated) TabManager. Used
    /// by tear-off: caller detaches the tab into a fresh empty TabManager,
    /// then hands it to us so the window opens with the tab already in place.
    @discardableResult
    func createNewWindow(
        with tabManager: TabManager,
        screenPoint: CGPoint? = nil,
        frame: NSRect? = nil
    ) -> NSWindow? {
        guard let builder = windowContentBuilder else {
            assertionFailure("windowContentBuilder not installed — PageFlowApp.onAppear didn't fire")
            return nil
        }
        return createNewWindow(with: builder(tabManager), screenPoint: screenPoint, frame: frame)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        firstLaunchManager.handleFirstLaunch()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let pdfURLs = urls
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .map(\.pageFlowCanonicalDocumentURL)
        guard !pdfURLs.isEmpty else { return }

        var reroutedIntoExistingWindow = false

        // Activate existing tabs first so Finder/open-file events reuse the live document window
        // instead of leaving behind a transient empty SwiftUI placeholder window.
        for url in pdfURLs {
            if WindowRegistry.shared.activateExistingDocument(for: url) {
                reroutedIntoExistingWindow = true
                continue
            }

            if let tabManager = WindowRegistry.shared.anyTabManager() {
                if !tabManager.isPlaceholderWindow {
                    reroutedIntoExistingWindow = true
                }
                tabManager.closeFilePicker()
                tabManager.openDocument(url: url, isSecurityScoped: false)
            } else {
                pendingDocumentOpens.append(
                    PendingDocumentOpen(url: url, isSecurityScoped: false)
                )
            }
        }

        if reroutedIntoExistingWindow {
            WindowRegistry.shared.dismissTransientPlaceholderWindowForExternalOpen()
        }
    }

    /// Delivers any URLs buffered during cold launch to the given TabManager.
    func flushPendingURLs(to tabManager: TabManager) {
        guard !pendingDocumentOpens.isEmpty else { return }
        tabManager.closeFilePicker()
        let pendingOpens = pendingDocumentOpens
        pendingDocumentOpens.removeAll()
        for pendingOpen in pendingOpens {
            tabManager.openDocument(url: pendingOpen.url, isSecurityScoped: pendingOpen.isSecurityScoped)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirtyEntries = WindowRegistry.shared.allDirtyPDFManagers()

        guard let firstDirty = dirtyEntries.first else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Do you want to save changes before quitting?"
        if dirtyEntries.count == 1 {
            alert.informativeText = "Your changes to \"\(firstDirty.1.documentTitle)\" will be lost if you don't save."
        } else {
            let moreCount = dirtyEntries.count - 1
            alert.informativeText = "Your changes to \"\(firstDirty.1.documentTitle)\" and \(moreCount) other document(s) will be lost if you don't save."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let failedManagers = dirtyEntries.compactMap { _, manager in
                manager.saveSync() ? nil : manager
            }

            guard failedManagers.isEmpty else {
                showSaveFailureAlert(for: failedManagers)
                return .terminateCancel
            }
            return .terminateNow
        case .alertSecondButtonReturn:
            return .terminateCancel
        default:
            return .terminateNow
        }
    }

    private func showSaveFailureAlert(for managers: [PDFManager]) {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "PageFlow couldn't save all documents."
        alert.informativeText = managers.map(\.documentTitle).joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func positionWindow(
        _ window: NSWindow,
        contentSize: NSSize,
        near screenPoint: CGPoint?
    ) {
        guard let screenPoint,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) }) ?? NSScreen.main else {
            window.center()
            return
        }

        let visibleFrame = screen.visibleFrame
        let originX = min(
            max(screenPoint.x - contentSize.width * 0.35, visibleFrame.minX),
            visibleFrame.maxX - contentSize.width
        )
        let originY = min(
            max(screenPoint.y - 64, visibleFrame.minY),
            visibleFrame.maxY - contentSize.height
        )

        window.setFrameOrigin(NSPoint(x: originX, y: originY))
    }
}
