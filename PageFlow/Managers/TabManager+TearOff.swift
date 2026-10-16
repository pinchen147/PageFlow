//
//  TabManager+TearOff.swift
//  PageFlow
//
//  The movable-tab plumbing: detach a tab (and its session) from this window,
//  attach a detached tab into another, and the ordered session teardown both
//  close and tear-off funnel through. Pure decomposition of the tab-move path.
//

import Foundation
import os.log

extension TabManager {

    func detachTab(_ tabID: UUID, closeIfEmpty: Bool = true) -> DetachedTab? {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              let session = sessions[tabID] else {
            return nil
        }
        logger.debug("tab.detach tab=\(tabID.uuidString, privacy: .public)")

        if activeTabID == tabID {
            saveCurrentTabState()
        } else if let pdfManager = session.pdfManager {
            // A warm view may have consumed the switch-away restore. Re-arm it
            // before dismantling; an evicted view keeps its cached restore.
            // Do not persist here: no live view must not erase durable scroll.
            _ = pdfManager.captureViewState()
        }

        // Edit mode is ephemeral: leaving the window exits it, exactly as a tab
        // switch does (selectTab). The flag never travels true; the monitor is
        // retired by the reconcile in activeTabID's didSet below.
        session.uiState.isEditingPages = false

        let detachedTab = DetachedTab(tab: tabs[index], session: session)
        let fallbackTabID = fallbackTabIDAfterClosing(tabID, at: index)

        // The session — managers, undo history + observers, UI state, and any
        // pending unlock — travels intact. Only this window's presentation order
        // is released; the session's undo observers are NOT torn down.
        unlockQueue.removeAll { $0 == tabID }
        // Capture before the native editor changes windows, so the destination
        // can restore the same reading position after its viewport changes.
        session.content.markdown?.armReadingPositionRestore()
        dropRenderedTab(tabID)
        tabs.remove(at: index)
        sessions.removeValue(forKey: tabID)

        if tabs.isEmpty {
            activeTabID = nil
            closeFilePicker()
            if closeIfEmpty {
                WindowRegistry.shared.closeWindow(for: self, onlyIfEmpty: true)
            }
        } else if activeTabID == tabID {
            activeTabID = fallbackTabID
        }

        // The source window released a tab — refresh the restore store (S8 P1).
        scheduleSessionSave()
        return detachedTab
    }

    func attachDetachedTab(
        _ detachedTab: DetachedTab,
        at index: Int,
        select: Bool = true
    ) {
        let session = detachedTab.session
        logger.debug("tab.attach tab=\(session.id.uuidString, privacy: .public) index=\(index, privacy: .public)")
        let clampedIndex = min(max(index, 0), tabs.count)
        var attachedTab = detachedTab.tab
        if let documentURL = attachedTab.documentURL {
            let documentTitle = session.pdfManager?.documentTitle ?? ""
            attachedTab.title = documentTitle.isEmpty
                ? documentURL.deletingPathExtension().lastPathComponent
                : documentTitle
        }
        tabs.insert(attachedTab, at: clampedIndex)
        sessions[session.id] = session

        // If the moved tab is still awaiting a password, queue it for this
        // window's sheet (after any request already presented here).
        if session.pendingUnlock != nil, !unlockQueue.contains(session.id) {
            unlockQueue.append(session.id)
        }

        // selectTab captures the outgoing destination exactly once. An empty
        // destination must display its incoming tab even during a hover merge.
        if select || activeSession == nil {
            selectTab(session.id)
        }
        retainTransferredEditor(session.id)

        // The destination window gained a tab — refresh the restore store (S8 P1).
        scheduleSessionSave()
    }

    /// Tears down and drops a tab's session. The session owns the ordered
    /// teardown (close document, clear markup, drop undo history + observers).
    func closeSession(for tabID: UUID) {
        logger.debug("session.close tab=\(tabID.uuidString, privacy: .public)")
        sessions.removeValue(forKey: tabID)?.cleanup()
        unlockQueue.removeAll { $0 == tabID }
        dropRenderedTab(tabID)
    }
}
