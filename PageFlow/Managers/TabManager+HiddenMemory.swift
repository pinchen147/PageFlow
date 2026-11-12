//
//  TabManager+HiddenMemory.swift
//  PageFlow
//
//  What hidden tabs give back: after a while out of sight, and at once when
//  the Mac runs short. Warm Markdown editors stay warm on purpose; a PDF view,
//  the costliest, rebuilds at the reader's place like any evicted view.
//

import Foundation
import os.log

extension TabManager {
    /// Starts the clock on a tab just hidden, and stops it on the one shown.
    func noteHiddenTab(_ id: UUID?) {
        if let id {
            sessions[id]?.hiddenSince = Date()
            sessions[id]?.content.markdown?.noteGoingOutOfSight()
        }
        activeSession?.hiddenSince = nil
        activeSession?.content.epub?.resumeReleasedCaches()
        scheduleHiddenTabRelease()
    }

    /// A tab that arrived from another window without being shown: a clock
    /// it already has runs on, otherwise it starts now. Its narration stops as
    /// for a tab switch, whose view would have seen the tab go inactive.
    func noteArrivedHidden(_ session: TabSession) {
        if session.hiddenSince == nil { session.hiddenSince = Date() }
        session.content.epub?.readAloud.stop()
        scheduleHiddenTabRelease()
    }

    /// One waiting call for the oldest hidden tab: nothing runs once every
    /// hidden tab has given back what it can.
    private func scheduleHiddenTabRelease() {
        hiddenTabRelease?.cancel()
        hiddenTabRelease = nil
        guard let oldest = sessions.values.compactMap(\.hiddenSince).min() else { return }
        let delay = max(0, oldest.addingTimeInterval(hiddenTabLifetime).timeIntervalSinceNow)
        let release = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hiddenTabRelease = nil
                let now = Date()
                for session in self.sessions.values {
                    guard let since = session.hiddenSince, now.timeIntervalSince(since) >= self.hiddenTabLifetime else { continue }
                    session.hiddenSince = nil
                    if session.id != self.activeTabID { self.releaseMemory(ofHidden: session.id, underPressure: false) }
                }
                self.scheduleHiddenTabRelease()
            }
        }
        hiddenTabRelease = release
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: release)
    }

    /// The Mac is short of memory: every hidden tab gives back all it can now.
    func releaseHiddenTabsUnderPressure() {
        for id in sessions.keys where id != activeTabID {
            releaseMemory(ofHidden: id, underPressure: true)
        }
    }

    private func releaseMemory(ofHidden id: UUID, underPressure: Bool) {
        guard let session = sessions[id] else { return }
        switch session.content {
        case .pdf:
            dropWarmView(of: id)
        case .epub(let content):
            content.releaseHiddenCaches()
            if underPressure { dropWarmView(of: id) }
        case .markdown(let content):
            content.imageProvider.releaseDecodedImages()
        }
    }

    private func dropWarmView(of id: UUID) {
        guard renderedTabIDs.contains(id) else { return }
        prepareRenderedViewEviction(id)
        dropRenderedTab(id)
        logger.debug("warmset.release tab=\(id.uuidString, privacy: .public)")
    }
}
