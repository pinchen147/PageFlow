//
//  EditModeMonitorTests.swift
//  PageFlowTests
//
//  The edit-mode key monitor invariant: installed iff this window's active
//  tab is in page-edit mode (reconciled — never started/stopped at call
//  sites). Uses the injectable installer seam: a real NSEvent local monitor
//  is app-wide test-host state, so these tests record installs/removals
//  instead of installing anything.
//

import AppKit
import Testing
@testable import PageFlow

@MainActor
struct EditModeMonitorTests {
    /// Records monitor installs/removals through the TabManager seam, and
    /// captures the handler so guard behavior is testable without dispatching
    /// real events.
    final class MonitorSpy {
        private(set) var installCount = 0
        private(set) var removeCount = 0
        private(set) var capturedHandler: ((NSEvent) -> NSEvent?)?
        var isInstalled: Bool { installCount > removeCount }

        @MainActor
        func wire(_ manager: TabManager) {
            manager.editModeMonitorInstall = { handler in
                self.installCount += 1
                self.capturedHandler = handler
                return NSObject()
            }
            manager.editModeMonitorRemove = { _ in
                self.removeCount += 1
            }
        }
    }

    @Test
    func enteringAndLeavingEditModeReconcilesTheMonitor() {
        let manager = TabManager()
        let spy = MonitorSpy()
        spy.wire(manager)

        manager.isEditingPages = true
        #expect(spy.isInstalled)

        manager.isEditingPages = false
        #expect(!spy.isInstalled)
        #expect(spy.installCount == 1)
        #expect(spy.removeCount == 1)
    }

    /// The reconcile is idempotent: re-asserting the current state must not
    /// stack a second monitor or over-remove (an over-release per AppKit docs).
    @Test
    func reconcileIsIdempotent() throws {
        let manager = TabManager()
        let tabID = try #require(manager.activeTabID)
        let spy = MonitorSpy()
        spy.wire(manager)

        manager.isEditingPages = true
        manager.setIsEditingPages(true, for: tabID)
        #expect(spy.installCount == 1)

        manager.isEditingPages = false
        manager.setIsEditingPages(false, for: tabID)
        #expect(spy.removeCount == 1)
    }

    /// Edit mode is ephemeral: switching tabs exits it on the tab being left
    /// (the flag is cleared, not parked) and retires the monitor.
    @Test
    func switchingTabsExitsEditModeAndRetiresTheMonitor() throws {
        let manager = TabManager()
        let spy = MonitorSpy()
        spy.wire(manager)
        let firstTab = try #require(manager.activeTabID)
        manager.createNewTab()
        let secondTab = try #require(manager.activeTabID)
        manager.selectTab(firstTab)

        manager.isEditingPages = true
        #expect(spy.isInstalled)

        manager.selectTab(secondTab)
        #expect(!spy.isInstalled)
        #expect(!manager.isEditingPages(for: firstTab))
    }

    /// Closing the last tab drops its session without reassigning activeTabID
    /// (no didSet fires) — the regression this pins is the monitor surviving
    /// that branch on the closeTab path's explicit reconcile.
    @Test
    func closingTheLastEditingTabRetiresTheMonitor() throws {
        let manager = TabManager()
        let spy = MonitorSpy()
        spy.wire(manager)
        let tabID = try #require(manager.activeTabID)

        manager.isEditingPages = true
        #expect(spy.isInstalled)

        manager.closeTab(tabID)
        #expect(!spy.isInstalled)
    }

    /// Closing the active editing tab while a neighbor remains promotes the
    /// neighbor (not editing) — the monitor must retire with the closed tab.
    @Test
    func closingTheActiveEditingTabRetiresTheMonitor() throws {
        let manager = TabManager()
        let spy = MonitorSpy()
        spy.wire(manager)
        manager.createNewTab()
        let secondTab = try #require(manager.activeTabID)

        manager.isEditingPages = true
        #expect(spy.isInstalled)

        manager.closeTab(secondTab)
        #expect(!spy.isInstalled)
        #expect(manager.activeTabID != nil)
    }

    /// Tear-off regression (previously: the flag rode along as true with no
    /// monitor anywhere). Edit mode exits on detach: the source retires its
    /// monitor, and the tab arrives in the destination NOT editing — so the
    /// destination installs nothing.
    @Test
    func tearOffExitsEditModeInBothWindows() throws {
        let source = TabManager()
        let sourceSpy = MonitorSpy()
        sourceSpy.wire(source)
        let tabID = try #require(source.activeTabID)

        source.isEditingPages = true
        #expect(sourceSpy.isInstalled)

        let destination = TabManager(createInitialTab: false)
        let destinationSpy = MonitorSpy()
        destinationSpy.wire(destination)
        #expect(source.moveTab(tabID, to: destination, at: 0))

        #expect(!sourceSpy.isInstalled)
        #expect(destination.activeTabID == tabID)
        #expect(!destination.isEditingPages)
        #expect(destinationSpy.installCount == 0)
    }

    /// Cmd+T (and a drop creating a fresh tab) switches tabs without going
    /// through selectTab — the regression this pins is the leaving tab's flag
    /// parking true and the reconcile resurrecting edit mode on return.
    @Test
    func openingANewTabExitsEditModeOnTheLeavingTab() throws {
        let manager = TabManager()
        let spy = MonitorSpy()
        spy.wire(manager)
        let firstTab = try #require(manager.activeTabID)

        manager.isEditingPages = true
        #expect(spy.isInstalled)

        manager.createNewTab()
        #expect(!spy.isInstalled)
        #expect(!manager.isEditingPages(for: firstTab))

        manager.selectTab(firstTab)
        #expect(!manager.isEditingPages)
        #expect(spy.installCount == 1)
    }

    /// The window guard fails closed: while editing, an event that cannot be
    /// attributed to this manager's window passes through UNCHANGED — never
    /// swallowed, never interpreted (here: Return must not exit edit mode).
    /// The positive interception path needs a real key window and stays
    /// manual QA (ADR-0005).
    @Test
    func foreignWindowKeyEventsPassThroughWhileEditing() throws {
        let manager = TabManager()
        let spy = MonitorSpy()
        spy.wire(manager)

        manager.isEditingPages = true
        let handler = try #require(spy.capturedHandler)

        let returnKey = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))

        #expect(handler(returnKey) === returnKey)
        #expect(manager.isEditingPages)
    }
}
