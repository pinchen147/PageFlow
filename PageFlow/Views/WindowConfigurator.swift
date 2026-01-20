//
//  WindowConfigurator.swift
//  PageFlow
//
//  Configures the NSWindow to hide system chrome and allow full-bleed content.
//

import SwiftUI
import AppKit

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)

        // Allow window dragging from views that return mouseDownCanMoveWindow = true
        // DO NOT set isMovable = false - that breaks everything
        window.isMovableByWindowBackground = false

        // Set window background to match PDF viewer
        window.backgroundColor = DesignTokens.viewerBackground
        window.hasShadow = true

        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }
}
