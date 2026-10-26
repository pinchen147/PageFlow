//
//  SessionRestoreTests.swift
//  PageFlowTests
//
//  The pure list logic behind cross-launch session restore (S8 P1): capturing a
//  window's file-backed tabs (skip untitled), serialize/deserialize round-trip of
//  the per-tab security-scoped bookmarks, and restore filtering (skip tabs whose
//  bookmark/file is unresolvable, re-map the active index). The actual bookmark
//  resolve + window reopen is GUI/IO and lives in AppDelegate — not covered here;
//  these tests exercise the capture/filter list logic with placeholder bookmark
//  `Data`, no real files required.
//

import Foundation
import Testing
@testable import PageFlow

@MainActor
struct SessionRestoreTests {

    // MARK: - Capture (skip untitled, compute active index)

    @Test
    func capturingKeepsOrderAndMapsActiveIndex() {
        let a = RestoreTab(path: "/a.pdf", bookmark: Data([0x01]))
        let b = RestoreTab(path: "/b.md", bookmark: Data([0x02]))
        let c = RestoreTab(path: "/c.pdf", bookmark: Data([0x03]))
        let window = WindowSessionState.capturing(orderedTabs: [a, b, c], activeListIndex: 1)
        #expect(window == WindowSessionState(tabs: [a, b, c], activeIndex: 1))
    }

    @Test
    func capturingDropsUntitledTabsAndRemapsActive() {
        // Tab list: [file, untitled, file, active-file]; the untitled one (a nil
        // entry, no path/bookmark) is dropped and the active index re-mapped.
        let a = RestoreTab(path: "/a.pdf", bookmark: Data([0x01]))
        let b = RestoreTab(path: "/b.md", bookmark: Data([0x02]))
        let c = RestoreTab(path: "/c.pdf", bookmark: Data([0x03]))
        let window = WindowSessionState.capturing(orderedTabs: [a, nil, b, c], activeListIndex: 3)
        #expect(window?.tabs == [a, b, c])
        #expect(window?.activeIndex == 2)
    }

    @Test
    func capturingWithUntitledActiveTabHasNilActiveIndex() {
        let a = RestoreTab(path: "/a.pdf", bookmark: Data([0x01]))
        let window = WindowSessionState.capturing(orderedTabs: [a, nil], activeListIndex: 1)
        #expect(window?.tabs == [a])
        #expect(window?.activeIndex == nil)  // the untitled tab is active — not persisted
    }

    @Test
    func capturingRetainsFileBackedTabWithoutBookmark() {
        // A file-backed tab whose scoped bookmark couldn't be minted (non-sandboxed
        // build) is RETAINED with a nil bookmark — the path is the reopen fallback.
        // Only URL-less (untitled → nil entry) tabs are skipped, not nil-bookmark ones.
        let scoped = RestoreTab(path: "/scoped.pdf", bookmark: Data([0x01]))
        let pathOnly = RestoreTab(path: "/pathonly.md", bookmark: nil)
        let window = WindowSessionState.capturing(orderedTabs: [scoped, pathOnly], activeListIndex: 1)
        #expect(window?.tabs == [scoped, pathOnly])
        #expect(window?.activeIndex == 1)
    }

    @Test
    func capturingAllUntitledWindowReturnsNil() {
        // A window of only untitled buffers has nothing to reopen (ADR-0012 D7).
        #expect(WindowSessionState.capturing(orderedTabs: [nil, nil], activeListIndex: 0) == nil)
        #expect(WindowSessionState.capturing(orderedTabs: [], activeListIndex: nil) == nil)
    }

    // MARK: - Restore filtering (skip unresolvable bookmark/file)

    @Test
    func filteringReopenableSkipsUnresolvableAndRemapsActive() {
        let gone = RestoreTab(path: "/gone.pdf", bookmark: Data([0x09]))
        let here = RestoreTab(path: "/here.md", bookmark: Data([0x01]))
        let also = RestoreTab(path: "/alsohere.pdf", bookmark: Data([0x02]))
        let window = WindowSessionState(tabs: [gone, here, also], activeIndex: 2)
        let resolvable: Set<String> = ["/here.md", "/alsohere.pdf"]

        let restored = window.filteringReopenable { resolvable.contains($0.path) }
        #expect(restored?.tabs == [here, also])
        // Active was index 2 (/alsohere.pdf) → now index 1 after /gone.pdf dropped.
        #expect(restored?.activeIndex == 1)
    }

    @Test
    func filteringReopenableWithVanishedActiveClearsActiveIndex() {
        let here = RestoreTab(path: "/here.pdf", bookmark: Data([0x01]))
        let gone = RestoreTab(path: "/gone.md", bookmark: Data([0x02]))
        let window = WindowSessionState(tabs: [here, gone], activeIndex: 1)
        let restored = window.filteringReopenable { $0.path == "/here.pdf" }
        #expect(restored?.tabs == [here])
        #expect(restored?.activeIndex == nil)  // active file vanished → default active
    }

    @Test
    func filteringReopenableDropsWindowWhenNoneResolvable() {
        let window = WindowSessionState(tabs: [
            RestoreTab(path: "/gone1.pdf", bookmark: Data([0x01])),
            RestoreTab(path: "/gone2.md", bookmark: nil),
        ], activeIndex: 0)
        #expect(window.filteringReopenable { _ in false } == nil)
    }

    // MARK: - Store persistence round-trip (bookmark Data survives)

    @Test
    func saveLoadRoundTripsBookmarksAndActive() {
        let defaults = makeDefaults()
        let state = SessionRestoreState(windows: [
            WindowSessionState(tabs: [
                RestoreTab(path: "/w1a.pdf", bookmark: Data([0xDE, 0xAD, 0xBE, 0xEF])),
                RestoreTab(path: "/w1b.md", bookmark: nil),
            ], activeIndex: 1),
            WindowSessionState(tabs: [
                RestoreTab(path: "/w2a.pdf", bookmark: Data([0xCA, 0xFE])),
            ], activeIndex: nil),
        ])

        SessionRestoreStore(defaults: defaults).save(state)

        // A fresh store reading the same defaults restores the value, bookmark
        // `Data` included (disk round-trip).
        #expect(SessionRestoreStore(defaults: defaults).load() == state)
    }

    @Test
    func loadWithoutSavedStateIsEmpty() {
        #expect(SessionRestoreStore(defaults: makeDefaults()).load().isEmpty)
    }

    @Test
    func clearForgetsTheSavedSession() {
        let defaults = makeDefaults()
        let store = SessionRestoreStore(defaults: defaults)
        store.save(SessionRestoreState(windows: [
            WindowSessionState(tabs: [RestoreTab(path: "/x.pdf", bookmark: Data([0x01]))], activeIndex: 0)
        ]))
        store.clear()
        #expect(store.load().isEmpty)
    }

    // MARK: - TabManager capture

    @Test
    func tabManagerCaptureSkipsTheEmptyPlaceholderTab() {
        // A fresh window has one empty untitled tab → nothing to persist.
        let manager = TabManager()
        #expect(manager.captureWindowSession() == nil)
    }

    // MARK: - Helpers

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "pageflow.tests.\(UUID().uuidString)")!
    }
}
