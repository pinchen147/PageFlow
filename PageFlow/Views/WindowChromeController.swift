//
//  WindowChromeController.swift
//  PageFlow
//
//  Owns per-window AppKit chrome: hides the title bar and hover-reveals the
//  native window buttons (traffic lights) in sync with the SwiftUI top chrome.
//
//  The buttons are the real `standardWindowButton`s — controlled by alphaValue,
//  never `isHidden` (which removes them from layout + accessibility and which
//  AppKit fights by re-showing them on key/main/full-screen transitions).
//

import AppKit

final class WindowChromeController: NSObject {
    private weak var window: NSWindow?
    private var isTrafficLightsVisible = false

    init(window: NSWindow) {
        self.window = window
        super.init()
        configureWindow()
        setTrafficLightsVisible(false, animated: false)
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
    }

    private var systemButtons: [NSButton] {
        guard let window else { return [] }
        return [.closeButton, .miniaturizeButton, .zoomButton].compactMap {
            window.standardWindowButton($0)
        }
    }

    private func observeWindowChanges() {
        let nc = NotificationCenter.default
        // AppKit re-shows / resets button alpha on these transitions, so we
        // re-assert the hover-driven visibility after each.
        let names: [NSNotification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didEndLiveResizeNotification
        ]
        for name in names {
            nc.addObserver(self, selector: #selector(windowStateChanged), name: name, object: window)
        }
    }

    @objc private func windowStateChanged() {
        applyTrafficLightAlpha(animated: false)
    }

    // MARK: - Hover reveal

    /// Reveal or hide the native window buttons. No-ops when the animated state
    /// is already correct, so repeated reporter updates don't restart animations.
    func setTrafficLightsVisible(_ visible: Bool, animated: Bool = true) {
        if animated && isTrafficLightsVisible == visible { return }
        isTrafficLightsVisible = visible
        applyTrafficLightAlpha(animated: animated)
    }

    private func applyTrafficLightAlpha(animated: Bool) {
        let buttons = systemButtons
        guard !buttons.isEmpty else { return }
        let target: CGFloat = isTrafficLightsVisible ? 1 : 0

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DesignTokens.animationFast
                context.allowsImplicitAnimation = true
                buttons.forEach { $0.animator().alphaValue = target }
            }
        } else {
            buttons.forEach { $0.alphaValue = target }
        }
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
