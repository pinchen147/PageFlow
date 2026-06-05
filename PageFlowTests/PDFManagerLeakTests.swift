//
//  PDFManagerLeakTests.swift
//  PageFlowTests
//
//  Probes the per-tab object graph for retain cycles that would make memory (and
//  therefore responsiveness) grow the longer the app is used.
//
//  The dangerous path is documented on `TabSession.deinit`: a session can be dropped
//  WITHOUT `cleanup()` — e.g. a window closed with tabs still present — in which case
//  `removeAllActions()` / `closeDocument()` never run. If anything in the graph forms
//  a retain cycle, that drop leaks the whole tab: `PDFManager`, its managers, and the
//  loaded `PDFDocument`. These tests exercise that exact drop with no window/PDFView.
//

import PDFKit
import Testing
@testable import PageFlow

@MainActor
struct PDFManagerLeakTests {

    private func makeTwoPageDocument() -> PDFDocument {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        document.insert(PDFPage(), at: 1)
        return document
    }

    /// A bare `PDFManager` that registered a real undo action must still deallocate
    /// once its strong references drop. (Confirms `registerUndo(withTarget:)` does not
    /// strand the target, even when the undo-provider closure is installed.)
    @Test
    func pdfManagerWithRegisteredUndoDeallocates() {
        weak var weakManager: PDFManager?
        weak var weakDocument: PDFDocument?

        autoreleasepool {
            let undoManager = UndoManager()
            let manager = PDFManager()
            let document = makeTwoPageDocument()
            weakManager = manager
            weakDocument = document

            manager.undoManagerProvider = { [weak undoManager] in undoManager }
            manager.document = document
            manager.rotatePage(at: 0, clockwise: true)
            #expect(undoManager.canUndo)
        }

        #expect(weakManager == nil, "PDFManager leaked after a registered undo action")
        #expect(weakDocument == nil, "PDFDocument leaked (held by the leaked PDFManager)")
    }

    /// The real teardown probe: dropping a `TabSession` WITHOUT calling `cleanup()`
    /// (the window-closed-with-tabs path) must free the whole per-tab graph.
    @Test
    func droppingTabSessionWithoutCleanupFreesGraph() {
        weak var weakSession: TabSession?
        weak var weakManager: PDFManager?
        weak var weakDocument: PDFDocument?

        autoreleasepool {
            let session = TabSession(id: UUID())
            let document = makeTwoPageDocument()
            weakSession = session
            weakManager = session.pdfManager
            weakDocument = document

            session.pdfManager.document = document
            // Exercise the wiring that runs on real edits: rotate registers undo;
            // delete fans a PageMutation out to the bookmark/comment managers.
            session.pdfManager.rotatePage(at: 0, clockwise: true)
            session.pdfManager.deletePage(at: 1)

            // Drop the only strong reference WITHOUT cleanup() — exactly what happens
            // when a window is closed while it still owns tabs.
        }

        #expect(weakSession == nil, "TabSession leaked on drop-without-cleanup")
        #expect(weakManager == nil, "PDFManager leaked with its TabSession")
        #expect(weakDocument == nil, "PDFDocument leaked (held by the leaked tab graph)")
    }
}
