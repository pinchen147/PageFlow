//
//  TabDeckStripTests.swift
//  PageFlowTests
//
//  The real tab strip, mounted in a window: with compact tabs on it is the
//  Deck, reporting each card's shown part as its hit frame; off, it keeps the
//  full-width strip. The setting is passed in, never written to the shared
//  SettingsManager (and the test host's real defaults). Windows here are never
//  ordered front (test-host hazard).
//

import AppKit
import SwiftUI
import Testing
@testable import PageFlow

@MainActor
struct TabDeckStripTests {
    @MainActor
    private struct Mounted {
        let window: NSWindow
        let manager: TabManager
        let mouseView: TabBarMouseNSView

        /// Each tab's hit frame width, in tab order.
        var shownWidths: [CGFloat] {
            manager.tabs.compactMap { mouseView.tabScreenFrame(for: $0.id)?.width }
        }

        var hitFrames: [CGRect] {
            manager.tabs.compactMap { mouseView.tabScreenFrame(for: $0.id) }
        }
    }

    private func mount(tabs count: Int, width: CGFloat, compact: Bool, occluded: CGFloat = 0) throws -> Mounted {
        _ = NSApplication.shared
        let manager = TabManager(createInitialTab: false)
        for _ in 0..<count { manager.createNewTab() }
        manager.selectTab(manager.tabs[count / 2].id)

        let hosting = NSHostingView(rootView: TabBarView(tabManager: manager, compactTabs: compact,
                                                         occludedTrailingWidth: occluded).frame(width: width, height: 40))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 40)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = hosting
        settle(hosting)

        let mouseView = try #require(Self.mouseView(in: hosting))
        return Mounted(window: window, manager: manager, mouseView: mouseView)
    }

    /// Layout, preference and onChange passes land over a few run-loop turns.
    private func settle(_ view: NSView) {
        for _ in 0..<12 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private static func mouseView(in view: NSView) -> TabBarMouseNSView? {
        (view as? TabBarMouseNSView) ?? view.subviews.lazy.compactMap(mouseView(in:)).first
    }

    @Test
    func compactTabsShowTheDeck() throws {
        let strip = try mount(tabs: 9, width: 400, compact: true)
        defer { strip.window.orderOut(nil) }

        let widths = strip.shownWidths
        try #require(widths.count == 9)
        #expect(widths[4] == DesignTokens.tabMaxWidth, "the focused tab shows whole")
        for (index, width) in widths.enumerated() where index != 4 {
            #expect(width == DesignTokens.tabDeckSliverWidth, "tab \(index) is a sliver")
        }
        // Shown parts never overlap and run in tab order, so hover, close
        // and drop-index code written for side-by-side tabs still works.
        for (left, right) in zip(strip.hitFrames, strip.hitFrames.dropFirst()) {
            #expect(left.maxX <= right.minX + 0.5)
        }
    }

    @Test
    func compactTabsDeckEvenWhenTheyWouldFit() throws {
        let strip = try mount(tabs: 2, width: 900, compact: true)
        defer { strip.window.orderOut(nil) }

        #expect(strip.shownWidths == [DesignTokens.tabDeckSliverWidth, DesignTokens.tabMaxWidth])
    }

    @Test
    func turningCompactTabsOffKeepsTheScrollingStrip() throws {
        let strip = try mount(tabs: 9, width: 400, compact: false)
        defer { strip.window.orderOut(nil) }

        let widths = strip.shownWidths
        try #require(widths.count == 9)
        #expect(widths.allSatisfy { $0 >= DesignTokens.tabMinWidth })
    }

    @Test
    func dropIndexFollowsTheSlivers() throws {
        let strip = try mount(tabs: 9, width: 400, compact: true)
        defer { strip.window.orderOut(nil) }

        let frames = strip.hitFrames
        try #require(frames.count == 9)
        // Left half of each shown part drops before that tab.
        for (index, frame) in frames.enumerated() {
            let point = CGPoint(x: frame.minX + 1, y: frame.midY)
            #expect(strip.mouseView.dropIndex(for: point) == index)
        }
    }

    /// The strip's drawn opacity in an x range, rendered offscreen.
    private func maxAlpha(_ strip: Mounted, x range: ClosedRange<CGFloat>) throws -> CGFloat {
        let view = try #require(strip.window.contentView)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        var alpha: CGFloat = 0
        for x in stride(from: range.lowerBound, through: range.upperBound, by: 2) {
            for y in stride(from: CGFloat(4), through: 36, by: 2) {
                alpha = max(alpha, rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.alphaComponent ?? 0)
            }
        }
        return alpha
    }

    /// A toolbar floating open over the strip hides the tabs under it instead
    /// of letting them show through its glass.
    @Test
    func tabsUnderAFloatingToolbarFadeOut() throws {
        let open = try mount(tabs: 9, width: 400, compact: true)
        defer { open.window.orderOut(nil) }
        try #require(try maxAlpha(open, x: 230...290) > 0.1, "the Deck draws there with nothing over it")

        let covered = try mount(tabs: 9, width: 400, compact: true, occluded: 200)
        defer { covered.window.orderOut(nil) }
        #expect(try maxAlpha(covered, x: 230...290) < 0.01, "tabs show under the toolbar")
        #expect(try maxAlpha(covered, x: 20...120) > 0.1, "the tabs left of the toolbar stay")
    }
}
