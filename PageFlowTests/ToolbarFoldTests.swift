//
//  ToolbarFoldTests.swift
//  PageFlowTests
//
//  The toolbar fold decision: when the floating toolbar holds its width,
//  rests as a sphere, or floats open over the tabs.
//

import Foundation
import Testing
@testable import PageFlow

@MainActor
struct ToolbarFoldTests {
    /// A 1000 pt row: strip + slot = 1000, the open toolbar is 300 wide and
    /// the sphere 28.
    private func fold(pinned: Bool, peeking: Bool = false, tabs: CGFloat, open: Bool) -> ToolbarFold {
        let slot: CGFloat = open ? 300 : 28
        return ToolbarFold(
            isPinned: pinned,
            isPeeking: peeking,
            tabsWidth: tabs,
            tabStripWidth: 1000 - slot,
            slotWidth: slot,
            openWidth: 300
        )
    }

    @Test
    func pinnedToolbarHoldsItsWidthWhileTheTabsFit() {
        #expect(fold(pinned: true, tabs: 700, open: true).holdsWidth)
        #expect(fold(pinned: true, tabs: 700, open: true).isOpen)
    }

    @Test
    func pinnedToolbarFoldsWhileTheTabsDontFit() {
        #expect(!fold(pinned: true, tabs: 701, open: true).holdsWidth)
        #expect(!fold(pinned: true, tabs: 701, open: true).isOpen)
    }

    @Test
    func foldingNeverFlipsTheDecisionThatCausedIt() {
        for tabs: CGFloat in [500, 700, 701, 900] {
            #expect(fold(pinned: true, tabs: tabs, open: true).holdsWidth == fold(pinned: true, tabs: tabs, open: false).holdsWidth)
        }
    }

    @Test
    func unpinnedToolbarRestsAsASphereAndOpensOnlyWhilePeeking() {
        #expect(!fold(pinned: false, tabs: 100, open: false).isOpen)
        #expect(fold(pinned: false, peeking: true, tabs: 100, open: false).isOpen)
        #expect(!fold(pinned: false, peeking: true, tabs: 100, open: false).holdsWidth)
    }

    /// A pinned toolbar that crowded tabs fold still opens as a peek, and its
    /// trailing button must unpin it: pinning it again would do nothing.
    @Test
    func theTrailingButtonPinsOnlyAnUnpinnedToolbar() {
        #expect(fold(pinned: false, peeking: true, tabs: 100, open: false).offersPin)
        let crowded = fold(pinned: true, peeking: true, tabs: 900, open: false)
        #expect(crowded.isFloating)
        #expect(!crowded.offersPin)
        #expect(!fold(pinned: true, tabs: 700, open: true).offersPin)
    }

    @Test
    func theCoveredStripNeverExceedsTheStrip() {
        let narrow = ToolbarFold(isPinned: false, isPeeking: true, tabsWidth: 100,
                                 tabStripWidth: 120, slotWidth: 28, openWidth: 300)
        #expect(narrow.coveredStripWidth == 120)
        #expect(narrow.coversTabSwitcher)
        #expect(!fold(pinned: false, peeking: true, tabs: 100, open: false).coversTabSwitcher)
    }

    /// The pointer opens the toolbar only over the part of the row the open
    /// toolbar covers, never over a tab, and keeps it open anywhere over it.
    @Test
    func thePeekZoneIsWhereTheOpenToolbarWillBe() {
        #expect(fold(pinned: false, tabs: 100, open: false).peekReach == 300, "a long empty strip: only the toolbar's footprint")
        #expect(fold(pinned: false, tabs: 500, open: false).peekReach == 300, "the sphere and the footprint beside it")
        #expect(fold(pinned: false, tabs: 900, open: false).peekReach == 100, "the footprint stops at the tabs")
        #expect(fold(pinned: false, tabs: 1200, open: false).peekReach == 28, "crowded tabs leave only the sphere")
        #expect(fold(pinned: false, peeking: true, tabs: 900, open: false).peekReach == 300, "open, the whole toolbar")
        #expect(fold(pinned: false, peeking: true, tabs: 100, open: false).peekReach == 300, "open, the whole toolbar, not the strip")
    }

    @Test
    func onlyAFloatingToolbarOverhangsTheTabs() {
        #expect(fold(pinned: false, peeking: true, tabs: 100, open: false).overhang == 272)
        #expect(fold(pinned: false, tabs: 100, open: false).overhang == 0)
        #expect(fold(pinned: true, peeking: true, tabs: 100, open: true).overhang == 0)
    }
}
