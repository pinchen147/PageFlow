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
    /// The adaptor instance. On macOS 26 SwiftUI installs its own proxy as
    /// `NSApp.delegate` and only forwards callbacks here, so
    /// `NSApp.delegate as? AppDelegate` returns nil — every call site must use
    /// this instead (verified by AppDelegateInstallTests).
    private(set) static weak var shared: AppDelegate?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

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

    /// Builds the chrome-less window that hosts `contentView`, without showing,
    /// positioning, or registering it (`createNewWindow` does that).
    ///
    /// The SwiftUI view is hosted as the window's `contentView` via `NSHostingView`
    /// (the WWDC23-blessed form), NOT by installing an `NSHostingController` as the
    /// window's `contentViewController`. A hosting controller keeps re-asserting its
    /// view to the FRONT of the theme frame — above the `NSTitlebarContainerView` —
    /// so opaque content paints over the native traffic-light buttons and they are
    /// invisible (the tear-off / ⌘N "no traffic lights" bug). An `NSHostingView`
    /// set as the content view stays BEHIND the titlebar like SwiftUI's own
    /// WindowGroup, AND bridges scene state (notably the focused values the ⌘T/⌘W
    /// menu commands read) to the window — which a nested hosting subview does not.
    /// `isReleasedWhenClosed` is false because the `NSWindowController` owns the
    /// window's lifetime (see `createNewWindow`).
    static func makeHostedWindow(contentView: some View, contentSize: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // Host the SwiftUI view directly AS the window's content view (WWDC23):
        // this is what bridges scene state — including focused values, which the
        // ⌘T/⌘W menu commands read via `.focusedSceneValue` — to a manually
        // created NSWindow. (A nested hosting subview does not bridge.)
        window.contentView = NSHostingView(rootView: contentView)
        // Canonical hidden-titlebar chrome (adds .fullSizeContentView). Applied
        // here at construction so the window never flashes a solid titlebar
        // before WindowChromeController installs via the SwiftUI content.
        WindowChromeController.applyHiddenTitlebarChrome(to: window)
        window.identifier = PageFlowWindowIdentifiers.userCreated
        return window
    }

    @discardableResult
    func createNewWindow(
        with contentView: some View,
        screenPoint: CGPoint? = nil,
        frame: NSRect? = nil
    ) -> NSWindow {
        let contentSize = frame?.size
            ?? NSSize(width: DesignTokens.defaultWindowWidth, height: DesignTokens.defaultWindowHeight)

        let window = Self.makeHostedWindow(contentView: contentView, contentSize: contentSize)
        if let frame {
            window.setFrame(frame, display: false)
        } else {
            positionWindow(window, near: screenPoint)
        }

        let windowController = NSWindowController(window: window)
        windowControllers.append(windowController)
        let controllerID = ObjectIdentifier(windowController)

        // Clean up when window closes
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak windowController] notification in
            // Archive the closing window's tabs into Recently Closed (Tab
            // Switcher): a window-level close (red button / multi-tab window)
            // never routes through TabManager.closeTab. This `queue: .main`
            // callback runs on the main thread, so the main-actor hop is safe.
            if let closingWindow = notification.object as? NSWindow {
                MainActor.assumeIsolated {
                    WindowRegistry.shared.recordClosedTabs(forWindow: closingWindow)
                }
            }
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
        // Test host: never block termination behind the save prompt — a modal
        // alert in a headless host turns finished test runs into zombies.
        if TestEnvironment.isRunningTests { return .terminateNow }

        // Persist each window's reading position before we quit (views are still live).
        WindowRegistry.shared.flushAllViewState()

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

    private func positionWindow(_ window: NSWindow, near screenPoint: CGPoint?) {
        guard let screenPoint, let screen = NSScreen.containing(screenPoint) else {
            window.center()
            return
        }

        // Anchor near the cursor, then fit the WHOLE window frame on-screen via
        // the shared clamp. Using `window.frame.size` (not the content size)
        // includes the titlebar, so the title bar can't slide under the menu bar.
        let size = window.frame.size
        let anchored = NSRect(
            origin: NSPoint(x: screenPoint.x - size.width * 0.35, y: screenPoint.y - 64),
            size: size
        )
        window.setFrame(NSScreen.onScreenFrame(anchored, in: screen.visibleFrame), display: false)
    }
}
