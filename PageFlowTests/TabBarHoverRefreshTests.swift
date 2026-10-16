//
//  TabBarHoverRefreshTests.swift
//  PageFlowTests
//
//  Tabs that move under a still pointer (a ⌘1–9 switch re-laying out the
//  Deck) get no mouse event from AppKit; the tab strip's mouse view re-reads
//  the pointer so no card stays slid out under a stale hover. The window sits
//  far off-screen, so the real pointer is never over it.
//

import AppKit
import Testing
@testable import PageFlow

@MainActor
struct TabBarHoverRefreshTests {
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// A mouse view in a window far off-screen: a re-read always finds the
    /// pointer outside it.
    private func offScreenMouseView() -> (NSWindow, TabBarMouseNSView) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: -20_000, y: -20_000, width: 400, height: 32),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let view = TabBarMouseNSView(frame: CGRect(x: 0, y: 0, width: 400, height: 32))
        window.contentView = view
        return (window, view)
    }

    @Test
    func aLayoutChangeUnderAStillPointerDropsTheStaleHover() async throws {
        let manager = TabManager(createInitialTab: false)
        manager.createNewTab()
        manager.createNewTab()
        let first = try #require(manager.tabs.first?.id)
        let second = try #require(manager.tabs.last?.id)
        let (window, view) = offScreenMouseView()
        defer { window.orderOut(nil) }

        var hovers: [UUID?] = []
        func apply(_ frames: [UUID: CGRect], hovered: UUID?) {
            view.apply(
                tabManager: manager,
                tabFrames: frames,
                newTabButtonFrame: .zero,
                hoveredTabID: hovered,
                activeTabID: manager.activeTabID,
                onHover: { hovers.append($0) },
                onClick: { _ in }
            )
        }

        // The first tab was slid out under the pointer while the second was
        // focused.
        apply([first: CGRect(x: 0, y: 3, width: 160, height: 26),
               second: CGRect(x: 160, y: 3, width: 160, height: 26)], hovered: first)
        await drainMainQueue()
        hovers.removeAll()

        // ⌘1: the Deck re-lays out around the first tab; the pointer, nowhere
        // near the strip, never moved and AppKit reports nothing.
        manager.selectTab(first)
        apply([first: CGRect(x: 0, y: 3, width: 160, height: 26),
               second: CGRect(x: 160, y: 3, width: 18, height: 26)], hovered: first)
        await drainMainQueue()

        #expect(hovers == [nil])
    }

    @Test
    func anUnchangedLayoutDoesNotReReadThePointer() async throws {
        let manager = TabManager(createInitialTab: false)
        manager.createNewTab()
        let tab = try #require(manager.tabs.first?.id)
        // In a window, so a re-read would report the pointer outside and fail.
        let (window, view) = offScreenMouseView()
        defer { window.orderOut(nil) }
        let frames = [tab: CGRect(x: 0, y: 3, width: 160, height: 26)]
        var hovers: [UUID?] = []
        let apply = {
            view.apply(tabManager: manager, tabFrames: frames, newTabButtonFrame: .zero,
                       hoveredTabID: tab, activeTabID: manager.activeTabID,
                       onHover: { hovers.append($0) }, onClick: { _ in })
        }
        apply()
        await drainMainQueue()
        hovers.removeAll()

        apply()
        await drainMainQueue()

        #expect(hovers.isEmpty)
    }
}
