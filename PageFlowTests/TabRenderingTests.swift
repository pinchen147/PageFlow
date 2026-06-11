//
//  TabRenderingTests.swift
//  PageFlowTests
//
//  The warm-set (keep-alive) invariant: tab switching shows an already-mounted
//  view instead of rebuilding it, bounded by an LRU cap.
//

import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PageFlow

@MainActor
struct TabRenderingTests {
    /// The real production cap, so the eviction test can never drift from it.
    private let cap = TabManager.maxRenderedTabs

    /// A single-tab window keeps exactly its one tab warm — identical to the old
    /// "render only the active tab" behaviour, so nothing regresses for one tab.
    @Test
    func singleTabKeepsOnlyItselfWarm() throws {
        let manager = TabManager()
        let active = try #require(manager.activeTabID)
        #expect(manager.renderedTabIDs == [active])
        #expect(manager.renderedRuntimes.count == 1)
        #expect(manager.renderedRuntimes.first?.tabID == active)
    }

    /// The most-recently-active tab is always the warm set's head.
    @Test
    func mostRecentlyActiveTabIsTheWarmSetHead() throws {
        let manager = TabManager()
        let a = try #require(manager.activeTabID)
        manager.createNewTab(); let b = try #require(manager.activeTabID)
        manager.createNewTab(); let c = try #require(manager.activeTabID)

        #expect(manager.renderedTabIDs.first == c)   // newest active leads

        manager.selectTab(a)
        #expect(manager.renderedTabIDs.first == a)   // re-selecting promotes it
        #expect(manager.activeTabID == a)
        _ = b  // b stays warm in the middle
    }

    /// Beyond the cap the least-recently-active tab is evicted from the warm set,
    /// so its view tears down (bounding memory + window-wide monitors).
    @Test
    func warmSetIsCappedAndEvictsLeastRecentlyActive() throws {
        let manager = TabManager()
        let first = try #require(manager.activeTabID)

        // Create enough additional tabs to exceed the cap (initial + cap more).
        for _ in 0..<cap { manager.createNewTab() }

        #expect(manager.renderedTabIDs.count == cap)
        #expect(manager.renderedRuntimes.count == cap)
        #expect(!manager.renderedTabIDs.contains(first))  // oldest evicted
        #expect(manager.renderedTabIDs.first == manager.activeTabID)
    }

    /// Eviction re-arms the evicted tab's exact-scroll restore: its rebuilt view
    /// must land where the user left off, not at the document top (which would
    /// then be persisted over the real saved position).
    @Test
    func evictionRearmsTheReadingPositionRestore() throws {
        let manager = TabManager()
        let first = try #require(manager.activeTabID)
        let pdfManager = try #require(manager.activePDFManager)

        let document = makeTestDocument(pageCount: 3)
        pdfManager.document = document
        pdfManager.documentURL = URL(fileURLWithPath: "/tmp/evict-rearm-\(UUID()).pdf")
        let page = try #require(document.page(at: 2))
        pdfManager.liveDestinationProvider = { PDFDestination(page: page, at: CGPoint(x: 0, y: 40)) }
        pdfManager.pendingScrollRestore = nil

        for _ in 0..<cap { manager.createNewTab() }   // evicts `first`

        #expect(!manager.renderedTabIDs.contains(first))
        #expect(pdfManager.pendingScrollRestore != nil)
    }

    /// Closing a tab drops it from the warm set immediately.
    @Test
    func closingATabDropsItFromTheWarmSet() throws {
        let manager = TabManager()
        let a = try #require(manager.activeTabID)
        manager.createNewTab()
        let b = try #require(manager.activeTabID)
        #expect(manager.renderedTabIDs.contains(b))

        manager.closeTab(b)
        #expect(!manager.renderedTabIDs.contains(b))
        #expect(manager.activeTabID == a)
        #expect(manager.renderedTabIDs == [a])
    }
}
