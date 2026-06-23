//
//  TabSwitcherRegistryTests.swift
//  PageFlowTests
//
//  WindowRegistry.allOpenTabs() — the cross-window enumeration behind the Tab
//  Switcher. Returns each live window's tabs and excludes unregistered windows.
//

import AppKit
import Testing
@testable import PageFlow

@MainActor
struct TabSwitcherRegistryTests {
    /// An offscreen window that is NEVER ordered front: a visible test window
    /// becoming the last window terminates the whole suite mid-run (see
    /// WindowCloseTests).
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    @Test
    func enumeratesEveryRegisteredWindowsTabs() throws {
        let m1 = TabManager(); let w1 = makeWindow()
        let m2 = TabManager(); let w2 = makeWindow()
        WindowRegistry.shared.register(m1, window: w1)
        WindowRegistry.shared.register(m2, window: w2)
        defer {
            WindowRegistry.shared.unregister(m1)
            WindowRegistry.shared.unregister(m2)
        }

        m1.createNewTab()  // m1 now has two tabs

        let groups = WindowRegistry.shared.allOpenTabs()
        let g1 = try #require(groups.first { $0.tabManager === m1 })
        let g2 = try #require(groups.first { $0.tabManager === m2 })

        #expect(g1.tabs.count == 2)
        #expect(g1.activeTabID == m1.activeTabID)
        #expect(g1.tabs.map(\.id) == m1.tabs.map(\.id))
        #expect(g2.tabs.count == 1)
        // At most one window is flagged frontmost.
        #expect(groups.filter(\.isFrontmost).count <= 1)
    }

    @Test
    func excludesUnregisteredWindows() {
        let manager = TabManager()
        let window = makeWindow()
        WindowRegistry.shared.register(manager, window: window)

        #expect(WindowRegistry.shared.allOpenTabs().contains { $0.tabManager === manager })

        WindowRegistry.shared.unregister(manager)

        #expect(!WindowRegistry.shared.allOpenTabs().contains { $0.tabManager === manager })
    }
}
