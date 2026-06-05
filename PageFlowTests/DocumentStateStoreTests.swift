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

        let document = PDFDocument()
        for index in 0..<pageCount {
            let image = NSImage(size: NSSize(width: 32, height: 32))
            image.lockFocus()
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 32, height: 32)).fill()
            image.unlockFocus()
            guard let page = PDFPage(image: image) else {
                throw CocoaError(.fileWriteUnknown)
            }
            document.insert(page, at: index)
        }
        #expect(document.write(to: url))
        return url
    }
}
