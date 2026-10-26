//
//  DocumentStateStoreTests.swift
//  PageFlowTests
//
//  Covers per-document reading-position persistence: the store's save/restore
//  round-trip, and PDFManager restoring (or falling back) on document load.
//

import AppKit
import CoreGraphics
import PDFKit
import Testing
@testable import PageFlow

@MainActor
struct DocumentStateStoreTests {

    // MARK: - Store round-trip

    @Test
    func savesAndReturnsStatePerURL() {
        let store = makeStore()
        let url = URL(fileURLWithPath: "/tmp/pageflow-test/a.pdf")
        let state = DocumentViewState(pageIndex: 7, scaleFactor: 1.5, isAutoScaling: false,
                                      scrollPoint: CGPoint(x: 4, y: 88))

        store.save(state, for: url)

        #expect(store.state(for: url) == state)
    }

    @Test
    func unknownURLReturnsNil() {
        let store = makeStore()
        #expect(store.state(for: URL(fileURLWithPath: "/tmp/pageflow-test/missing.pdf")) == nil)
    }

    @Test
    func savePersistsAcrossStoreInstances() {
        let defaults = makeDefaults()
        let url = URL(fileURLWithPath: "/tmp/pageflow-test/persist.pdf")
        let state = DocumentViewState(pageIndex: 3, scaleFactor: 2.0, isAutoScaling: true, scrollPoint: nil)

        DocumentStateStore(defaults: defaults).save(state, for: url)

        // A fresh store reading the same defaults restores the value (disk round-trip).
        #expect(DocumentStateStore(defaults: defaults).state(for: url) == state)
    }

    // MARK: - Schema v2: unknown keys survive, v1 migrates

    /// The known-key list is what the merge replaces; it must match exactly what
    /// this build encodes, or a renamed field would be kept twice (stale + new).
    @Test
    func knownKeysMatchWhatTheStateEncodes() throws {
        let full = DocumentViewState(pageIndex: 1, scaleFactor: 1, isAutoScaling: true, scrollPoint: CGPoint(x: 1, y: 2),
                                     markdownAnchorOffset: 3, markdownOffsetInViewport: 4, markdownScaleFactor: 5,
                                     markdownTableColumnWidths: ["k-0": [nil, 224]])
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(full)) as? [String: Any])
        #expect(Set(object.keys) == DocumentViewState.knownKeys)
    }

    /// A field this build does not know (written by a newer one) rides through
    /// a save untouched; the fields it does know are replaced, nil included.
    @Test
    func saveKeepsUnknownKeysAndReplacesKnownOnes() throws {
        let defaults = makeDefaults()
        let url = URL(fileURLWithPath: "/tmp/pageflow-test/future.md")
        let key = url.pageFlowCanonicalDocumentURL.path
        let stored: [String: Any] = [key: [
            "updatedAt": Date().timeIntervalSinceReferenceDate,
            "state": ["pageIndex": 0, "scaleFactor": 1, "isAutoScaling": false,
                      "markdownAnchorOffset": 40, "markdownScaleFactor": 2, "futureField": "kept"]
        ]]
        defaults.set(try JSONSerialization.data(withJSONObject: stored), forKey: DocumentStateStore.storageKey)

        let store = DocumentStateStore(defaults: defaults)
        #expect(store.state(for: url)?.markdownAnchorOffset == 40)
        store.save(.markdown(anchorOffset: 99, offsetInViewport: 7, scaleFactor: 1), for: url)

        let data = try #require(defaults.data(forKey: DocumentStateStore.storageKey))
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        let state = try #require(raw[key]?["state"] as? [String: Any])
        #expect(state["futureField"] as? String == "kept")
        #expect(state["markdownAnchorOffset"] as? Int == 99)
        #expect(state["markdownOffsetInViewport"] as? Double == 7)
        #expect(state["scrollPoint"] == nil)
        #expect(DocumentStateStore(defaults: defaults).state(for: url)?.markdownAnchorOffset == 99)
    }

    /// Table column widths (view-only, per table key) round-trip, Auto as nil.
    @Test
    func tableColumnWidthsRoundTrip() {
        let defaults = makeDefaults()
        let url = URL(fileURLWithPath: "/tmp/pageflow-test/widths.md")
        let widths: [String: [Double?]] = ["a1b2-0": [nil, 224, nil], "c3-1": [112]]
        DocumentStateStore(defaults: defaults).save(
            .markdown(anchorOffset: 3, offsetInViewport: 0, scaleFactor: 1, tableColumnWidths: widths), for: url)
        #expect(DocumentStateStore(defaults: defaults).state(for: url)?.markdownTableColumnWidths == widths)
    }

    /// With no v2 blob the v1 blob is read (same record shape), and the first
    /// save writes v2 — v1 is left alone for an older build.
    @Test
    func readsTheLegacyBlobWhenNoV2Exists() throws {
        let defaults = makeDefaults()
        let url = URL(fileURLWithPath: "/tmp/pageflow-test/legacy.pdf")
        let legacy = DocumentViewState(pageIndex: 4, scaleFactor: 1.25, isAutoScaling: false, scrollPoint: CGPoint(x: 0, y: 9))
        struct LegacyEntry: Codable { var state: DocumentViewState; var updatedAt: Date }
        let blob = try JSONEncoder().encode([url.pageFlowCanonicalDocumentURL.path: LegacyEntry(state: legacy, updatedAt: Date())])
        defaults.set(blob, forKey: DocumentStateStore.legacyStorageKey)

        let store = DocumentStateStore(defaults: defaults)
        #expect(store.state(for: url) == legacy)
        store.save(legacy, for: url)
        #expect(defaults.data(forKey: DocumentStateStore.storageKey) != nil)
        #expect(defaults.data(forKey: DocumentStateStore.legacyStorageKey) == blob)
    }

    // MARK: - Restore on document load

    @Test
    func loadDocumentRestoresSavedReadingPosition() throws {
        let url = try writeTemporaryDocument(pageCount: 10)
        defer { try? FileManager.default.removeItem(at: url) }

        let store = makeStore()
        store.save(
            DocumentViewState(pageIndex: 6, scaleFactor: 1.75, isAutoScaling: false,
                              scrollPoint: CGPoint(x: 0, y: 120)),
            for: url
        )

        let manager = PDFManager()
        manager.documentStateStore = store
        guard case .success = manager.loadDocument(from: url) else {
            Issue.record("Expected the document to load successfully.")
            return
        }

        #expect(manager.currentPageIndex == 6)
        #expect(manager.scaleFactor == 1.75)
        #expect(manager.isAutoScaling == false)
        #expect(manager.pendingFit == nil)             // explicit restore, not a fit
        #expect(manager.pendingScrollRestore != nil)   // exact scroll point armed
    }

    @Test
    func loadDocumentWithoutSavedStateUsesDefaults() throws {
        let url = try writeTemporaryDocument(pageCount: 3)
        defer { try? FileManager.default.removeItem(at: url) }

        let manager = PDFManager()
        manager.documentStateStore = makeStore()       // empty
        guard case .success = manager.loadDocument(from: url) else {
            Issue.record("Expected the document to load successfully.")
            return
        }

        #expect(manager.currentPageIndex == 0)
        #expect(manager.scaleFactor == DesignTokens.pdfDefaultScale)
        #expect(manager.pendingFit == FitRequest(scrollToTop: true))
        #expect(manager.pendingScrollRestore == nil)
    }

    @Test
    func outOfRangeSavedPageFallsBackToDefaults() throws {
        // Simulates a file that shrank since the position was saved (e.g. pages removed).
        let url = try writeTemporaryDocument(pageCount: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let store = makeStore()
        store.save(
            DocumentViewState(pageIndex: 50, scaleFactor: 2.0, isAutoScaling: false, scrollPoint: nil),
            for: url
        )

        let manager = PDFManager()
        manager.documentStateStore = store
        guard case .success = manager.loadDocument(from: url) else {
            Issue.record("Expected the document to load successfully.")
            return
        }

        #expect(manager.currentPageIndex == 0)
        #expect(manager.pendingFit == FitRequest(scrollToTop: true))
    }

    // MARK: - Helpers

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "pageflow.tests.\(UUID().uuidString)")!
    }

    private func makeStore() -> DocumentStateStore {
        DocumentStateStore(defaults: makeDefaults())
    }

    private func writeTemporaryDocument(pageCount: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("doc.pdf")

        #expect(makeTestDocument(pageCount: pageCount).write(to: url))
        return url
    }
}
