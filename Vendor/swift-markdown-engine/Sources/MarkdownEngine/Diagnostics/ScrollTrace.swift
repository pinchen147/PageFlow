//
//  ScrollTrace.swift
//  MarkdownEngine
//
//  Attribution ledger for every change of the editor's scroll origin.
//
//  The engine stamps each origin write it makes; the scroll view stamps user
//  gestures; anything else that moves the clip view — TextKit 2 estimate
//  revisions, AppKit re-anchoring after a frame change, the magnification
//  bounce — is UNATTRIBUTED. Unattributed moves are the jumps the reader sees,
//  so they are logged persistently (`os_log` notice) and counted for the QA
//  harness. Always compiled: the steady-state cost is one comparison per
//  bounds change.
//
//  Read the trace after the fact with
//  `log show --predicate 'subsystem == "com.pageflow.MarkdownEngine" AND category == "ScrollTrace"'`.
//  Set PAGEFLOW_SCROLL_TRACE=1 to also log attributed moves (debug level).
//

import AppKit
import os

@MainActor
public enum ScrollTrace {

    /// One origin change, as observed on the clip view.
    public struct Entry: Sendable, Equatable {
        public let delta: CGFloat
        public let originY: CGFloat
        public let magnification: CGFloat
        /// The stamp or gesture the move is credited to; `nil` = unattributed.
        public let mutator: String?
        public var isAttributed: Bool { mutator != nil }
    }

    /// Aggregate view for the harness. `unattributedMaxDelta` is the largest
    /// jump the reader could have seen without doing anything.
    public struct Report: Sendable, Equatable {
        public var attributedCount = 0
        public var unattributedCount = 0
        public var unattributedMaxDelta: CGFloat = 0
        public var recent: [Entry] = []
    }

    /// A stamp older than this no longer explains an origin change. One
    /// run-loop turn is what engine writes need; 50 ms covers a wheel event
    /// delivered just before its scroll lands.
    static let attributionWindow: TimeInterval = 0.05
    private static let recentCapacity = 64

    private static let logger = Logger(subsystem: "com.pageflow.MarkdownEngine", category: "ScrollTrace")
    static let isVerbose = ProcessInfo.processInfo.environment["PAGEFLOW_SCROLL_TRACE"] != nil

    private struct ViewState {
        var originY: CGFloat
        var magnification: CGFloat
    }

    private static var lastStamp: (name: String, at: CFTimeInterval)?
    private static var liveGestureDepth = 0
    private static var viewStates: [ObjectIdentifier: ViewState] = [:]
    private static var report = Report()

    // MARK: - Writers

    /// Record that the engine is about to move a scroll origin. Call
    /// immediately before the write, on the main thread.
    public static func stamp(_ mutator: String) {
        lastStamp = (mutator, CACurrentMediaTime())
    }

    /// A user-driven origin change: a wheel/momentum event, a scroller drag,
    /// or a pinch. Wheel events stamp themselves per event; live scroll and
    /// magnify gestures bracket their whole duration with begin/end.
    public static func noteUserGesture(_ kind: String) {
        stamp("user:\(kind)")
    }

    public static func beginLiveGesture(_ kind: String) {
        liveGestureDepth += 1
        stamp("user:\(kind)")
    }

    public static func endLiveGesture(_ kind: String) {
        liveGestureDepth = max(0, liveGestureDepth - 1)
        stamp("user:\(kind)-end")
    }

    // MARK: - Observation

    /// Called from the clip-view bounds observer on every bounds change.
    /// Attributes the move and records it.
    public static func observe(_ scrollView: NSScrollView) {
        let key = ObjectIdentifier(scrollView)
        let originY = scrollView.contentView.bounds.origin.y
        let magnification = scrollView.magnification
        defer { viewStates[key] = ViewState(originY: originY, magnification: magnification) }
        guard let previous = viewStates[key] else { return }

        let delta = originY - previous.originY
        guard abs(delta) > 0.5 else { return }

        let mutator = attribution(magnificationChanged: abs(magnification - previous.magnification) > 0.0001)
        let entry = Entry(delta: delta, originY: originY, magnification: magnification, mutator: mutator)
        record(entry)
    }

    private static func attribution(magnificationChanged: Bool) -> String? {
        if liveGestureDepth > 0 { return lastStamp?.name ?? "user:live" }
        if let stamp = lastStamp, CACurrentMediaTime() - stamp.at < attributionWindow {
            return stamp.name
        }
        // A magnification change is always someone's explicit act (gesture,
        // ⌘±, restore); the stamp may simply be older than the window because
        // AppKit animates the last frames itself.
        if magnificationChanged { return "magnification" }
        return nil
    }

    private static func record(_ entry: Entry) {
        if isVerbose {
            // stderr as well as the log: the harness captures stderr.
            FileHandle.standardError.write(Data(String(format: "SCROLL Δy=%.1f → %.1f by %@\n", entry.delta, entry.originY, entry.mutator ?? "UNATTRIBUTED").utf8))
        }
        if entry.isAttributed {
            report.attributedCount += 1
            if isVerbose {
                logger.debug("moved Δy=\(entry.delta, format: .fixed(precision: 1)) → \(entry.originY, format: .fixed(precision: 1)) by \(entry.mutator ?? "?", privacy: .public)")
            }
        } else {
            report.unattributedCount += 1
            report.unattributedMaxDelta = max(report.unattributedMaxDelta, abs(entry.delta))
            let stampAge = lastStamp.map { (CACurrentMediaTime() - $0.at) * 1000 } ?? -1
            logger.notice("UNATTRIBUTED Δy=\(entry.delta, format: .fixed(precision: 1)) → \(entry.originY, format: .fixed(precision: 1)) mag=\(entry.magnification, format: .fixed(precision: 3)) lastStamp=\(lastStamp?.name ?? "none", privacy: .public) age=\(stampAge, format: .fixed(precision: 0))ms")
        }
        report.recent.append(entry)
        if report.recent.count > recentCapacity {
            report.recent.removeFirst(report.recent.count - recentCapacity)
        }
    }

    // MARK: - Harness API

    public static func snapshot() -> Report { report }

    /// Clears the ledger. Baselines are cleared too unless `keepingBaselines`:
    /// the harness keeps them so the first move of a scenario is recorded
    /// against the origin the previous scenario left; tests must not, because a
    /// freshly allocated scroll view can reuse a dead one's identity and inherit
    /// its stale origin.
    public static func reset(keepingBaselines: Bool = false) {
        report = Report()
        lastStamp = nil
        if !keepingBaselines { viewStates.removeAll() }
    }

    /// Forget a scroll view at teardown, for the same identity-reuse reason.
    public static func forget(_ scrollView: NSScrollView) {
        viewStates.removeValue(forKey: ObjectIdentifier(scrollView))
    }
}
