//
//  TabSwitcherSelectionTests.swift
//  PageFlowTests
//
//  The Tab Switcher opens with the tab the user is on highlighted: the
//  frontmost window's active tab, wherever it sits in the list.
//

import AppKit
import Testing
@testable import PageFlow

@MainActor
struct TabSwitcherSelectionTests {
    private func group(_ manager: TabManager, isFrontmost: Bool) -> WindowTabGroup {
        WindowTabGroup(
            tabManager: manager,
            window: NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true),
            tabs: manager.tabs,
            activeTabID: manager.activeTabID,
            dirtyTabIDs: [],
            isFrontmost: isFrontmost
        )
    }

    @Test
    func currentTabIsTheFrontmostWindowsActiveTab() throws {
        let front = TabManager()
        front.createNewTab()
        let first = try #require(front.tabs.first?.id)
        let second = try #require(front.tabs.last?.id)
        front.selectTab(second)
        let other = TabManager()

        let groups = [group(front, isFrontmost: true), group(other, isFrontmost: false)]
        #expect(TabSwitcherView.currentTabID(in: groups) == second)
        #expect(TabSwitcherView.currentTabID(in: groups) != first, "the highlight starts on the first row")

        let reversed = [group(other, isFrontmost: false), group(front, isFrontmost: true)]
        #expect(TabSwitcherView.currentTabID(in: reversed) == second)
    }

    @Test
    func noFrontmostWindowHasNoCurrentTab() {
        let manager = TabManager()
        #expect(TabSwitcherView.currentTabID(in: [group(manager, isFrontmost: false)]) == nil)
        #expect(TabSwitcherView.currentTabID(in: []) == nil)
    }
}
