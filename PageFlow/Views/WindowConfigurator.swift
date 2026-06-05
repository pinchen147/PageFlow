//
//  WindowConfigurator.swift
//  PageFlow
//
//  Configures the NSWindow to hide system chrome and allow full-bleed content.
//

import SwiftUI
import AppKit

struct WindowConfigurator: NSViewRepresentable {
    let isAlwaysOnTop: Bool

    func makeNSView(context: Context) -> WindowConfiguratorView {
        let view = WindowConfiguratorView()
        view.isAlwaysOnTop = isAlwaysOnTop
        return view
    }

    func updateNSView(_ nsView: WindowConfiguratorView, context: Context) {
        nsView.isAlwaysOnTop = isAlwaysOnTop
    }
}

final class WindowConfiguratorView: NSView {
    var isAlwaysOnTop = false {
        didSet {
            configureIfNeeded()
        }
    }

    private weak var configuredWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureIfNeeded()
    }

    private func configureIfNeeded() {
        guard let window else { return }

        if configuredWindow !== window {
            configuredWindow = window
            configureStaticWindowState(window)
        }

        let targetLevel: NSWindow.Level = isAlwaysOnTop ? .floating : .normal
        if window.level != targetLevel {
            window.level = targetLevel
        }
    }

    private func configureStaticWindowState(_ window: NSWindow) {
        // Allow window dragging from views that return mouseDownCanMoveWindow = true.
        // DO NOT set isMovable = false - that breaks everything.
        if window.isMovableByWindowBackground {
            window.isMovableByWindowBackground = false
        }

        window.backgroundColor = DesignTokens.viewerBackground
        if !window.hasShadow {
            window.hasShadow = true
        }

        // Install the chrome controller (idempotent). The controller handles
        // titlebar transparency, fullSizeContentView, hiding the standard
        // window buttons, and hosting the custom traffic-light overlay.
        _ = WindowChromeController.installIfNeeded(on: window)
    }
}
