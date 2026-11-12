//
//  SessionRestoreStore.swift
//  PageFlow
//
//  Cross-launch session restore (S8 P1): the ordered set of each window's
//  file-backed tabs, so a relaunch reopens the same documents (PDF and Markdown
//  alike). Each tab persists a SECURITY-SCOPED BOOKMARK (plus a canonical path
//  for de-dup/logging) so the reopen works in the SANDBOXED build — a bare path
//  is unreadable outside the app container (`fileExists`/`Data(contentsOf:)` deny),
//  so restore must resolve the bookmark and reopen `isSecurityScoped: true`,
//  mirroring `RecentFilesManager`. The PEER of `DocumentStateStore`: that store
//  remembers WHERE in a document the reader was; this one remembers WHICH
//  documents were open, in which window, and which was active. The two compose —
//  a restored tab lands at its saved reading position.
//
//  The list transforms (capture / skip-untitled / filter-unreopenable) are pure
//  and unit-tested; the actual bookmark resolve + window reopen is GUI/IO and
//  lives in `AppDelegate`. Untitled / URL-less tabs are NOT persisted (ADR-0012
//  D7): they have nothing to reopen from.
//
//  Crash fidelity of the active index is an explicit NON-GOAL (review M4): the
//  layout is persisted on coalesced mutation + at graceful quit, not continuously,
//  so a hard crash may restore a stale active tab. That is acceptable — the
//  document set (the load-bearing part) is still recovered.
//

import AppKit
import os.log

/// One restorable tab: a security-scoped bookmark to reopen it inside the sandbox
/// plus its canonical path. The bookmark is the reopen source (resolved with
/// `.withSecurityScope`); the path is retained for de-dup, logging, and as the
/// reopen fallback in a non-sandboxed build where no scoped bookmark is vended.
struct RestoreTab: Codable, Equatable {
    /// Canonical file path — de-dup key, log line, and non-sandbox reopen fallback.
    var path: String

    /// Security-scoped bookmark (`.withSecurityScope`) captured while the document
    /// was open, or `nil` in a non-sandboxed build / when the OS won't vend one.
    var bookmark: Data?
}

/// One window's restorable session: the ordered file-backed tabs plus which of
/// them was active. Codable so a window's layout survives a quit.
struct WindowSessionState: Codable, Equatable {
    /// The window's file-backed tabs, order preserved. Untitled (URL-less) tabs
    /// are excluded, so this is a subsequence of the window's real tab strip.
    var tabs: [RestoreTab]

    /// Index into `tabs` of the active tab, or `nil` when the active tab was
    /// untitled (and thus not persisted) or the window had no active tab.
    var activeIndex: Int?

    /// Where the window was, or `nil` for a session saved before this was kept
    /// (it opens centered at the default size).
    var placement: WindowPlacement?
}

/// Where a window was: its frame out of full screen, and whether it was in full
/// screen. Decodes with `WindowSessionState` from any earlier session.
struct WindowPlacement: Codable, Equatable {
    var frame: CGRect
    var isFullScreen: Bool

    /// The saved frame on the screen it overlaps most, kept wholly on it. A
    /// display since unplugged leaves the window at its size on the first screen.
    func restoredFrame(onScreens screens: [CGRect]) -> CGRect {
        func overlap(_ screen: CGRect) -> CGFloat {
            let shared = screen.intersection(frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        let best = screens.max { overlap($0) < overlap($1) }.flatMap { overlap($0) > 0 ? $0 : nil }
        guard let screen = best ?? screens.first else { return frame }
        return NSScreen.onScreenFrame(frame, in: screen)
    }
}

/// The whole app's restorable session: one entry per window that had at least one
/// file-backed tab, back to front, so reopening them in order leaves the same
/// window in front.
struct SessionRestoreState: Codable, Equatable {
    var windows: [WindowSessionState]

    static let empty = SessionRestoreState(windows: [])

    var isEmpty: Bool { windows.isEmpty }
}

// MARK: - Pure list transforms (capture + restore filtering)

extension WindowSessionState {
    /// Builds a window session from an ordered list of per-tab entries (`nil` = an
    /// untitled tab, dropped) plus the index of the active tab in that FULL list.
    /// `activeIndex` is re-mapped to point into the filtered (file-backed-only)
    /// list; it is `nil` when the active tab was untitled. Returns `nil` when no
    /// tab is file-backed — an all-untitled window is not persisted (ADR-0012 D7).
    static func capturing(orderedTabs: [RestoreTab?], activeListIndex: Int?) -> WindowSessionState? {
        var kept: [RestoreTab] = []
        var activeIndex: Int?
        for (listIndex, tab) in orderedTabs.enumerated() {
            guard let tab, !tab.path.isEmpty else { continue }
            if listIndex == activeListIndex { activeIndex = kept.count }
            kept.append(tab)
        }
        guard !kept.isEmpty else { return nil }
        return WindowSessionState(tabs: kept, activeIndex: activeIndex)
    }

    /// Drops tabs the caller marks un-reopenable (in production: a bookmark that
    /// resolves to an existing on-disk file), re-mapping `activeIndex`. Returns
    /// `nil` when nothing survives (the window is not reopened). If the active
    /// tab was dropped but others remain, `activeIndex` becomes `nil` (the reopen
    /// picks a default active tab). Pure — the resolve/existence decision is the
    /// caller's, so this list logic stays unit-testable with placeholder bookmarks.
    func filteringReopenable(_ isReopenable: (RestoreTab) -> Bool) -> WindowSessionState? {
        var survivors: [RestoreTab] = []
        var newActiveIndex: Int?
        for (index, tab) in tabs.enumerated() {
            guard isReopenable(tab) else { continue }
            if index == activeIndex { newActiveIndex = survivors.count }
            survivors.append(tab)
        }
        guard !survivors.isEmpty else { return nil }
        return WindowSessionState(tabs: survivors, activeIndex: newActiveIndex, placement: placement)
    }
}

// MARK: - Window placement

/// Keeps a live window's `WindowPlacement`. In full screen `frame` is the whole
/// screen, so the frame to come back to is the one from before: resizes and moves
/// update it only outside full screen, and capture reads it in full screen.
@MainActor
final class WindowPlacementTracker {
    private weak var window: NSWindow?
    private var windowedFrame: NSRect
    private var isFullScreen = false
    private var observers: [NSObjectProtocol] = []

    /// `onChange` runs when a settled move, resize or full-screen change or a
    /// new main window gives the session something new to save.
    init(window: NSWindow, onChange: @escaping @MainActor () -> Void) {
        self.window = window
        windowedFrame = window.frame
        let center = NotificationCenter.default
        func observe(_ names: [Notification.Name], _ work: @escaping @MainActor (WindowPlacementTracker) -> Void) {
            observers += names.map { name in
                center.addMainActorObserver(forName: name, object: window) { [weak self] in
                    if let self { work(self) }
                }
            }
        }
        observe([NSWindow.didResizeNotification, NSWindow.didMoveNotification]) { $0.noteFrame() }
        observe([NSWindow.willEnterFullScreenNotification]) { $0.isFullScreen = true }
        observe([NSWindow.didExitFullScreenNotification, .pageFlowWindowDidFailToEnterFullScreen]) {
            $0.isFullScreen = false
            $0.noteFrame()
        }
        observe([NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification,
                 NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                 .pageFlowWindowDidFailToEnterFullScreen, NSWindow.didBecomeMainNotification]) { _ in onChange() }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    var placement: WindowPlacement? {
        guard let window else { return nil }
        return WindowPlacement(frame: isFullScreen ? windowedFrame : window.frame, isFullScreen: isFullScreen)
    }

    private func noteFrame() {
        guard let window, !isFullScreen, !window.styleMask.contains(.fullScreen) else { return }
        windowedFrame = window.frame
    }
}

// MARK: - Persistence

/// App-wide persistence of the last session's window/tab layout. Mirrors the
/// `DocumentStateStore` idiom: a single JSON value in UserDefaults, decoded on
/// demand and rewritten whenever the layout changes (coalesced by
/// `WindowRegistry.scheduleSessionSave`).
@MainActor
final class SessionRestoreStore {
    static let shared = SessionRestoreStore()

    private static let storageKey = "sessionRestore.v1"

    /// Internal so a test can check where this writes without writing there.
    let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.pageflow", category: "SessionRestoreStore")

    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
    }

    /// The saved session, or `.empty` when none is recorded (or it fails to decode).
    func load() -> SessionRestoreState {
        guard let data = defaults.data(forKey: Self.storageKey) else { return .empty }
        do {
            return try JSONDecoder().decode(SessionRestoreState.self, from: data)
        } catch {
            logger.error("Failed to decode session restore state: \(error.localizedDescription)")
            return .empty
        }
    }

    /// Overwrites the saved session with `state`.
    func save(_ state: SessionRestoreState) {
        do {
            defaults.set(try JSONEncoder().encode(state), forKey: Self.storageKey)
        } catch {
            logger.error("Failed to encode session restore state: \(error.localizedDescription)")
        }
    }

    /// Forgets the saved session (used by tests; also a clean reset seam).
    func clear() {
        defaults.removeObject(forKey: Self.storageKey)
    }
}
