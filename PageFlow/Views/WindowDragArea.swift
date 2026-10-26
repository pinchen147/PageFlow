//
//  WindowDragArea.swift
//  PageFlow
//
//  NSView that gives an area native titlebar behavior: drag to move the
//  window, double-click to perform the user's configured titlebar action.
//

import SwiftUI
import AppKit

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowDragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowDragView: NSView {
    // `mouseDownCanMoveWindow` is a pass-through: the view's mouseDown is
    // never invoked, so double-clicks would be invisible. Instead we take
    // the event and hand the window-move to performDrag(with:) — the
    // documented pattern for drag + double-click on one surface. clickCount
    // is stamped by the system event stream, so the second click arrives
    // with clickCount == 2 even though performDrag consumed the first
    // click's tracking.
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1 else { return }
        window?.performDrag(with: event)
    }

    // Act on mouse-up, like the native titlebar (and Chromium): a
    // double-click-and-hold doesn't fire until release.
    override func mouseUp(with event: NSEvent) {
        guard event.clickCount == 2 else { return }
        performTitlebarAction()
    }

    private func performTitlebarAction() {
        guard let window else { return }
        let preference = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
        switch TitlebarDoubleClick.action(for: preference) {
        case .zoom:
            window.performZoom(nil)
        case .minimize:
            window.performMiniaturize(nil)
        case .fill:
            // Fill (macOS 15+ window tiling) has no public trigger; the
            // guarded private selector is the pattern Chromium/iTerm2 ship.
            // Floating (always-on-top) windows skip tiling — undocumented
            // territory — and fall back to zoom, as does any OS that drops
            // the selector.
            let fillSelector = Selector(("_zoomFill:"))
            if window.level == .normal, window.responds(to: fillSelector) {
                window.perform(fillSelector, with: nil)
            } else {
                window.performZoom(nil)
            }
        case .none:
            break
        }
    }
}
