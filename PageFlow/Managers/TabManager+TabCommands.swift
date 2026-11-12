//
//  TabManager+TabCommands.swift
//  PageFlow
//
//  The Tab menu's commands over this window's tabs: reopening a closed tab,
//  moving tabs between windows through the path a tab drag takes, and going
//  back through the tabs in the order they were used.
//

import AppKit
import Foundation

extension TabManager {

    // MARK: - Reopen Closed Tab

    /// Reopens the most recently closed tab that can still come back, as a new
    /// tab or in this window's empty placeholder; the open path restores its
    /// reading position. A file that's gone is skipped and reported, and a record
    /// whose document is already on its way back is passed over, so repeating
    /// walks the stack. A record leaves the stack when its open lands or fails
    /// for good (`ClosedTabStore.documentSettled`), so an abandoned open keeps it.
    @discardableResult
    func reopenClosedTab() -> Task<Void, Never>? {
        var gone: [ClosedTabStore.Record] = []
        defer { reportGoneClosedTabs(gone) }
        for record in closedTabStore.records {
            if record.fileIsGone {
                closedTabStore.remove(record)
                gone.append(record)
            } else if tabID(for: record.url) == nil, !downloadingURLs.contains(record.url),
                      !WindowRegistry.shared.isDocumentOpen(record.url) {
                return openDocument(url: record.url, isSecurityScoped: record.isSecurityScoped)
            }
        }
        return nil
    }

    /// Reopens the one record picked from Search Tabs' Recently Closed.
    @discardableResult
    func reopen(_ record: ClosedTabStore.Record) -> Task<Void, Never>? {
        guard !record.fileIsGone else {
            closedTabStore.remove(record)
            reportGoneClosedTabs([record])
            return nil
        }
        return openDocument(url: record.url, isSecurityScoped: record.isSecurityScoped)
    }

    /// Puts a closing tab on the stack, including one closed before its document
    /// arrived, which has no identity of its own yet.
    func recordClosedTab(_ tab: TabModel) {
        let session = sessions[tab.id]
        if tab.documentURL == nil, let open = session?.pendingMarkdownOpen {
            closedTabStore.record(url: open.url, title: open.url.deletingPathExtension().lastPathComponent,
                                  isSecurityScoped: open.access.requestedSecurityScope)
        } else if tab.documentURL == nil, let unlock = session?.pendingUnlock {
            closedTabStore.record(url: unlock.url, title: unlock.url.deletingPathExtension().lastPathComponent,
                                  isSecurityScoped: unlock.isSecurityScoped)
        } else {
            closedTabStore.record(tab)
        }
    }

    private func reportGoneClosedTabs(_ gone: [ClosedTabStore.Record]) {
        guard let first = gone.first else { return }
        postTransientToast(gone.count == 1
            ? "Couldn’t find “\(first.url.lastPathComponent)”"
            : "Couldn’t find \(gone.count) closed files")
    }

    // MARK: - Most recently used

    /// One tap of Ctrl-Tab: shows the next tab of the cycle. The order holds
    /// until `commitRecentTabCycle`.
    func stepRecentTab(_ direction: TabRecency.Direction) {
        guard let target = tabRecency.step(direction, tabs: tabs.map(\.id), active: activeTabID) else { return }
        selectTab(target)
    }

    /// Control went up: the tab reached is now the most recent.
    func commitRecentTabCycle() {
        tabRecency.commit()
    }

    /// The menu command: a whole cycle of one tap.
    func selectRecentTab(_ direction: TabRecency.Direction) {
        stepRecentTab(direction)
        commitRecentTabCycle()
    }

    /// The menu item, which the keys also reach when the monitor passes them on:
    /// from Search Tabs, a sheet or Settings the tab behind must not change, and
    /// a drag is holding the tabs in place.
    func selectRecentTabFromMenu(_ direction: TabRecency.Direction, keyWindow: NSWindow? = NSApp.keyWindow) {
        guard let keyWindow, keyWindow === WindowRegistry.shared.window(for: self),
              !TabDragController.shared.isActive else { return }
        selectRecentTab(direction)
    }

    // MARK: - Move Tab to New Window

    /// A tab can leave when its window keeps another one. Not while a close is
    /// waiting on it or a drag is holding tabs in place.
    func canMoveTabToNewWindow(_ tabID: UUID?) -> Bool {
        guard let tabID, tabs.count > 1, sessions[tabID] != nil else { return false }
        return pendingTabCloses[tabID] == nil && !TabDragController.shared.isActive
    }

    /// Moves `tabID` into a new window beside this one, by the move a tear-off
    /// makes, so the whole session goes with it. Returns the new window's manager.
    /// `open` shows the window at the frame given; nil means the app's own.
    @discardableResult
    func moveTabToNewWindow(_ tabID: UUID, open: ((TabManager, NSRect?) -> NSWindow?)? = nil) -> TabManager? {
        guard canMoveTabToNewWindow(tabID), let index = tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        let frame = newWindowFrame()
        let destination = TabManager(createInitialTab: false)
        guard moveTab(tabID, to: destination, at: 0) else { return nil }
        let window = open.map { $0(destination, frame) }
            ?? AppDelegate.shared?.createNewWindow(with: destination, frame: frame)
        guard let window else {
            // As in a tear-off: a tab and its edits can't strand in a manager with no window.
            _ = destination.moveTab(tabID, to: self, at: index)
            sessions[tabID]?.pdfManager?.reclaimReleasedView()
            return nil
        }
        // At once, not when the view appears: the session save coming next turn
        // must find this window, or its tab drops out of what a relaunch restores.
        WindowRegistry.shared.register(destination, window: window)
        scheduleSessionSave()
        return destination
    }

    private func newWindowFrame() -> NSRect? {
        guard let source = WindowRegistry.shared.window(for: self) else { return nil }
        let visible = source.screen?.visibleFrame
        let size = TabDragController.tornOffWindowSize(source.frame.size, visibleFrame: visible?.size)
        return TabWindowCascade.frame(
            after: source.frame,
            size: size,
            visibleFrame: visible,
            occupied: WindowRegistry.shared.allOpenTabs().map(\.window.frame)
        )
    }

    // MARK: - Merge All Windows

    func canMergeTabs(from sources: [TabManager]) -> Bool {
        !TabDragController.shared.isActive && sources.contains { $0 !== self && !$0.tabs.isEmpty }
    }

    /// Brings every tab of `sources` into this window, after its own, keeping
    /// the tab on screen. Blank tabs stay behind and vanish, and this window's own
    /// sole placeholder gives way to the tabs that arrive. A tab waiting on a
    /// close stays, and its window with it, until that ends.
    ///
    /// A window with a download in flight stays open with a blank tab: its
    /// manager is what the file lands in, and without a window it would be
    /// released and the file dropped.
    func mergeTabs(from sources: [TabManager]) {
        guard canMergeTabs(from: sources) else { return }
        let ownPlaceholder = hasOnlyPlaceholderTab ? activeTabID : nil
        var firstArrived: UUID?
        for source in sources where source !== self {
            let blanks = source.tabs.map(\.id).filter(source.isBlankTab)
            let staysForDownload = !source.downloadingURLs.isEmpty
            for tab in source.tabs where !blanks.contains(tab.id) && source.pendingTabCloses[tab.id] == nil {
                if staysForDownload, source.tabs.count == 1 { source.createNewTab() }
                if source.moveTab(tab.id, to: self, at: tabs.count, select: false), firstArrived == nil {
                    firstArrived = tab.id
                }
            }
            if !staysForDownload { blanks.forEach { source.closeTab($0) } }
        }
        if let ownPlaceholder, let firstArrived {
            selectTab(firstArrived)
            closeTab(ownPlaceholder)
        }
        scheduleSessionSave()
    }
}

/// Where a window opened from another one goes: down and right of it, past any
/// window already sitting exactly there, starting over at the screen's corner
/// when it would run off. Pure, so it needs no screen to test.
enum TabWindowCascade {
    static let step: CGFloat = 26

    static func frame(after source: NSRect, size: NSSize, visibleFrame: NSRect?, occupied: [NSRect]) -> NSRect {
        func placed(left: CGFloat, top: CGFloat) -> NSRect {
            NSRect(x: left, y: top - size.height, width: size.width, height: size.height)
        }
        var frame = placed(left: source.minX + step, top: source.maxY - step)
        // Bounded by the windows there are: each pass clears one or wraps once.
        for _ in 0...(occupied.count + 1) {
            if let visibleFrame, frame.maxX > visibleFrame.maxX || frame.minY < visibleFrame.minY {
                frame = placed(left: visibleFrame.minX + step, top: visibleFrame.maxY - step)
            }
            let isTaken = occupied.contains { abs($0.minX - frame.minX) < 1 && abs($0.maxY - frame.maxY) < 1 }
            guard isTaken else { break }
            frame = placed(left: frame.minX + step, top: frame.maxY - step)
        }
        return visibleFrame.map { NSScreen.onScreenFrame(frame, in: $0) } ?? frame
    }
}
