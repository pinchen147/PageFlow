//
//  TabSwitcherChevron.swift
//  PageFlow
//
//  Chrome's "Search Tabs" chevron, mounted in the top chrome just right of the
//  traffic lights. Tapping it drops the Tab Switcher below the button.
//
//  Clicks are handled by an AppKit hit target (not a SwiftUI Button) for the
//  same reasons the tab strip uses TabBarMouseView: in this hidden-title-bar
//  chrome a SwiftUI button doesn't accept first-mouse (so a click while the
//  dropdown panel is key is swallowed activating the window) and competes with
//  the window-drag region. The target also registers this window's button
//  position so a menu/keyboard invocation can drop the panel in the same place.
//
//  Like TabBarMouseView, the target is mounted ONLY while the bar is interactive:
//  AppKit hit-testing ignores SwiftUI's `allowsHitTesting`, so a hidden bar must
//  unmount it rather than rely on opacity.
//

import SwiftUI
import AppKit

struct TabSwitcherChevron: View {
    let tabManager: TabManager
    let isInteractive: Bool

    var body: some View {
        ChromeGlassIcon(systemName: "chevron.down", pointSize: 9)
            .overlay {
                if isInteractive {
                    TabSwitcherChevronTarget(tabManager: tabManager)
                }
            }
            .help("Search Tabs")
            .accessibilityLabel("Search Tabs")
            .accessibilityAddTraits(.isButton)
    }
}

private struct TabSwitcherChevronTarget: NSViewRepresentable {
    let tabManager: TabManager

    func makeNSView(context: Context) -> TabSwitcherChevronView {
        let view = TabSwitcherChevronView()
        view.tabManager = tabManager
        return view
    }

    func updateNSView(_ nsView: TabSwitcherChevronView, context: Context) {
        nsView.tabManager = tabManager
    }
}

final class TabSwitcherChevronView: NSView {
    weak var tabManager: TabManager?
    private weak var registeredWindow: NSWindow?

    // Match TabBarMouseView so the click is robust in the custom chrome:
    // register even when the window isn't key, and never start a window drag.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // Re-register on every window change (tear-off re-hosts this view),
        // mirroring the tracking-area reparent contract.
        TabSwitcherController.shared.registerAnchor(self, for: window)
        registeredWindow = window
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let registeredWindow, newWindow !== registeredWindow {
            TabSwitcherController.shared.unregisterAnchor(for: registeredWindow)
            self.registeredWindow = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Target this view's own window, not NSApp.keyWindow (which is the
        // dropdown panel itself while it's open).
        TabSwitcherController.shared.toggle(forWindow: window, hostTabManager: tabManager)
    }
}
