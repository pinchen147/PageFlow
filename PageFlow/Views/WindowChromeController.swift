//
//  WindowChromeController.swift
//  PageFlow
//
//  Owns per-window AppKit chrome suppression. The visible top chrome is
//  rendered by TopChromeView; this controller only keeps the native titlebar
//  transparent and the system traffic lights hidden.
//

import AppKit

final class WindowChromeController: NSObject {
    private weak var window: NSWindow?

    init(window: NSWindow) {
        self.window = window
        super.init()
        configureWindow()
        observeWindowChanges()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Window setup

    private func configureWindow() {
        guard let window else { return }

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = .none

        hideSystemButtons()
    }

    /// Hide the close/min/zoom buttons. Re-applied on multiple notifications
    /// because AppKit can re-show them when key/main/full-screen state changes.
    private func hideSystemButtons() {
        guard let window else { return }
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            let button = window.standardWindowButton(kind)
            button?.isHidden = true
            button?.alphaValue = 0
        }
    }

    private func observeWindowChanges() {
        let nc = NotificationCenter.default
        let names: [NSNotification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification
        ]
        for name in names {
            nc.addObserver(
                self,
                selector: #selector(windowStateChanged),
                name: name,
                object: window
            )
        }
    }

    @objc private func windowStateChanged() {
        hideSystemButtons()
    }
}

// MARK: - Per-window installation

extension WindowChromeController {
    private static var controllerKey: UInt8 = 0

    /// Idempotently attach a chrome controller to `window`. Repeat calls (e.g.
    /// from SwiftUI re-renders) no-op. The controller is retained as an
    /// associated object so it lives exactly as long as the window does.
    static func installIfNeeded(on window: NSWindow) -> WindowChromeController {
        if let existing = objc_getAssociatedObject(window, &controllerKey) as? WindowChromeController {
            return existing
        }
        let controller = WindowChromeController(window: window)
        objc_setAssociatedObject(window, &controllerKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return controller
    }

    /// Returns the controller previously installed on `window`, if any.
    static func attached(to window: NSWindow) -> WindowChromeController? {
        objc_getAssociatedObject(window, &controllerKey) as? WindowChromeController
    }
}
