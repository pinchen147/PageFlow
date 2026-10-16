//
//  TabManagerCharacterizationTests.swift
//  PageFlowTests
//
//  CHARACTERIZATION — the TabManager seams the `TabContent` refactor reshapes.
//
//  PageFlow is about to make Markdown a first-class TabContent peer of PDF
//  (docs/md docs/06, ADR-0006). Stage 4 turns `TabSession`'s fixed PDF-manager
//  bundle into a content-discriminated `enum TabContent`, which means rewriting
//  the positional `TabRuntime`, the warm-set eviction, the dirty-doc aggregation,
//  and the per-tab accessors. That refactor must be PURE — zero change to the PDF
//  path's observable behavior.
//
//  These tests pin that behavior NOW, on the current PDF-only code, so the Stage 4
//  diff is provably non-regressing. They complement the existing suites that
//  already cover Projector/Ingest (PDFViewStateTests), tear-off + view-snapshot
//  (TabSessionTests), and the load firewall
//  (PDFLoadFirewallCharacterizationTests). If one of these ever fails after the
//  refactor, a load-bearing tab invariant moved — stop and re-verify.
//

import AppKit
import PDFKit
import Testing
@testable import PageFlow

@MainActor
struct TabManagerCharacterizationTests {

    /// Adds one tab and returns its id. `createNewTab()` with no URL would open a
    /// file picker; headless there is no key window, so it schedules a deferred
    /// retry that `closeFilePicker()` disarms — leaving a clean, picker-free tab.
    private func addTab(to manager: TabManager) throws -> UUID {
        manager.createNewTab()
        manager.closeFilePicker()
        return try #require(manager.activeTabID)
    }

    // MARK: - Runtime composition (the positional struct Stage 4 reshapes)

    /// `activeRuntime` and the per-manager accessors are pure projections of the
    /// active session's manager instances — same identities, no copies. Stage 4
    /// moves these managers behind `TabContent.pdf`; this pins the 1:1 mapping the
    /// refactor must preserve.
    @Test
    func activeRuntimeProjectsTheActiveSessionManagersOneToOne() throws {
        let manager = TabManager()
        let session = try #require(manager.activeSession)
        let runtime = try #require(manager.activeRuntime)

        #expect(runtime.tabID == session.id)
        #expect(runtime.pdfManager === session.pdfManager)
        #expect(runtime.searchManager === session.searchManager)
        #expect(runtime.annotationManager === session.annotationManager)
        #expect(runtime.commentManager === session.commentManager)
        #expect(runtime.bookmarkManager === session.bookmarkManager)
        #expect(runtime.undoManager === session.undoManager)

        // The convenience accessors forward to the same instances.
        #expect(manager.activePDFManager === session.pdfManager)
        #expect(manager.activeSearchManager === session.searchManager)
        #expect(manager.activeUndoManager === session.undoManager)
    }

    /// With no active tab there is no runtime and no active managers — the nil the
    /// refactor's `content.pdf` optional-chaining must keep returning.
    @Test
    func noActiveTabYieldsNoRuntimeOrManagers() {
        let manager = TabManager(createInitialTab: false)
        #expect(manager.activeTabID == nil)
        #expect(manager.activeRuntime == nil)
        #expect(manager.activePDFManager == nil)
        #expect(manager.activeUndoManager == nil)
    }

    // MARK: - Warm set (LRU eviction)

    /// Activating tabs past the cap keeps exactly `maxRenderedTabs` warm,
    /// most-recently-active first with the active tab at the head; the
    /// least-recently-active tabs are evicted. This bounds memory and the
    /// window-wide event monitors, and is the invariant Stage 4 must not perturb.
    @Test
    func warmSetCapsAtMaxRenderedTabsMostRecentFirst() throws {
        let manager = TabManager()
        let t1 = try #require(manager.activeTabID)
        let t2 = try addTab(to: manager)
        let t3 = try addTab(to: manager)
        let t4 = try addTab(to: manager)
        let t5 = try addTab(to: manager)
        let t6 = try addTab(to: manager)

        #expect(manager.renderedTabIDs.count == TabManager.maxRenderedTabs)
        #expect(manager.renderedTabIDs == [t6, t5, t4, t3])
        // The two oldest activations fell out of the warm set.
        #expect(!manager.renderedTabIDs.contains(t1))
        #expect(!manager.renderedTabIDs.contains(t2))
    }

    /// Re-selecting an already-warm tab promotes it to the head without evicting
    /// anyone (the set was already full but the tab was in it).
    @Test
    func reSelectingAWarmTabPromotesItWithoutEviction() throws {
        let manager = TabManager()
        _ = try #require(manager.activeTabID)
        _ = try addTab(to: manager)
        let t3 = try addTab(to: manager)
        _ = try addTab(to: manager)
        _ = try addTab(to: manager)
        let t6 = try addTab(to: manager)
        // Warm: [t6, t5, t4, t3], active t6.

        manager.selectTab(t3)

        #expect(manager.renderedTabIDs.first == t3)
        #expect(manager.renderedTabIDs.count == TabManager.maxRenderedTabs)
        #expect(manager.renderedTabIDs.contains(t6))
    }

    /// Re-selecting a COLD (evicted) tab re-warms it at the head and evicts the
    /// current least-recently-active tab — the path that re-arms the rebuilt
    /// view's exact-scroll restore.
    @Test
    func reSelectingAColdTabReWarmsItAndEvictsTheLRU() throws {
        let manager = TabManager()
        let t1 = try #require(manager.activeTabID)
        _ = try addTab(to: manager)
        let t3 = try addTab(to: manager)
        _ = try addTab(to: manager)
        _ = try addTab(to: manager)
        _ = try addTab(to: manager)
        // Warm: [t6, t5, t4, t3]; t1 is cold.
        #expect(!manager.renderedTabIDs.contains(t1))

        manager.selectTab(t1)

        #expect(manager.renderedTabIDs.first == t1)
        #expect(manager.renderedTabIDs.count == TabManager.maxRenderedTabs)
        // t3 was the LRU and is now evicted.
        #expect(!manager.renderedTabIDs.contains(t3))
    }

    /// `renderedRuntimes` projects the warm set in order, active-first, onto live
    /// runtimes — the list the window mounts. Stage 4 reshapes how each runtime is
    /// built; the order and the active-first head must hold.
    @Test
    func renderedRuntimesTrackTheWarmSetActiveFirst() throws {
        let manager = TabManager()
        _ = try #require(manager.activeTabID)
        _ = try addTab(to: manager)
        _ = try addTab(to: manager)

        #expect(manager.renderedRuntimes.map(\.tabID) == manager.renderedTabIDs)
        #expect(manager.renderedRuntimes.first?.tabID == manager.activeTabID)
        #expect(manager.renderedRuntimes.first?.pdfManager === manager.activePDFManager)
    }

    // MARK: - Dirty aggregation (the set the DirtyDoc handle unifies)

    /// The PDF entries of `dirtyDocuments()` are exactly the sessions whose document
    /// is dirty, keyed by tab id — clean tabs are excluded. `DirtyDoc` spans PDF +
    /// Markdown; this pins the PDF half's contract (the former `dirtyPDFManagers()`).
    @Test
    func dirtyDocumentsPDFArmsAreExactlyTheDirtySessions() throws {
        let manager = TabManager()
        let t1 = try #require(manager.activeTabID)
        let t2 = try addTab(to: manager)
        let t3 = try addTab(to: manager)

        // Mark t1 and t3 dirty (via each tab's live manager); leave t2 clean.
        manager.selectTab(t1)
        try #require(manager.activePDFManager).isDirty = true
        manager.selectTab(t3)
        try #require(manager.activePDFManager).isDirty = true

        let dirty: [(UUID, PDFManager)] = manager.dirtyDocuments().compactMap { doc in
            if let pdf = doc.document as? PDFContent { return (doc.tabID, pdf.pdfManager) }
            return nil
        }
        #expect(Set(dirty.map(\.0)) == [t1, t3])
        #expect(!dirty.map(\.0).contains(t2))
        #expect(dirty.allSatisfy { $0.1.isDirty })
    }

    /// A fresh window with an untouched document reports no dirty PDF — the empty
    /// aggregation the quit/close path relies on to skip its save prompt.
    @Test
    func dirtyDocumentsIsEmptyWhenNothingIsDirty() {
        let manager = TabManager()
        let dirtyPDFs = manager.dirtyDocuments().filter { $0.document is PDFContent }
        #expect(dirtyPDFs.isEmpty)
    }

    // MARK: - saveCurrentTabState (the capture seam on every switch)

    /// Switching away from a tab captures its live page/zoom into the session's
    /// view snapshot, so the reused view re-projects correctly on return. Pinned
    /// at the `selectTab` boundary (TabSessionTests covers the unit underneath).
    @Test
    func selectTabCapturesTheOutgoingTabSnapshot() throws {
        let manager = TabManager()
        let t1 = try #require(manager.activeTabID)
        let outgoing = try #require(manager.activeSession)
        let t2 = try addTab(to: manager)

        // Give t1 a live document and a non-default reading position.
        manager.selectTab(t1)
        try #require(manager.activePDFManager).document = makeTestDocument(pageCount: 5)
        manager.activePDFManager?.goToPage(3)

        // Switching away from t1 must capture page 3 into its snapshot.
        manager.selectTab(t2)
        #expect(outgoing.viewSnapshot.pageIndex == 3)
    }
}
