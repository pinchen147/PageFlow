//
//  PageOperationTests.swift
//  PageFlowTests
//
//  Characterization tests pinning PDFManager's destructive page operations:
//  document mutation, current-page tracking, dirty/version flags, the page-
//  mutation fan-out, and undo round-trips.
//

import AppKit
import PDFKit
import Testing
@testable import PageFlow

@MainActor
struct PageOperationTests {

    // MARK: - Fixtures

    /// A PDFManager backed by an N-page document, with an undo manager wired for
    /// deterministic (run-loop-free) undo: `groupsByEvent = false` plus explicit
    /// grouping around each operation.
    private func makeManager(pages: Int, current: Int = 0) -> (manager: PDFManager, undo: UndoManager) {
        let manager = PDFManager()
        manager.document = makeTestDocument(pageCount: pages)
        manager.currentPageIndex = current
        manager.currentPage = manager.document?.page(at: current)
        let undo = UndoManager()
        undo.groupsByEvent = false
        manager.undoManagerProvider = { undo }
        return (manager, undo)
    }

    private func grouped(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    // MARK: - Delete

    @Test
    func deletePageRemovesMarksDirtyAndUndoRestores() {
        let (manager, undo) = makeManager(pages: 4)
        var mutations: [PageMutation] = []
        manager.pageMutationHandler = { mutations.append($0) }

        grouped(undo) { manager.deletePage(at: 1) }

        #expect(manager.pageCount == 3)
        #expect(manager.isDirty)
        #expect(mutations == [.deleted(at: 1)])
        #expect(undo.canUndo)

        undo.undo()
        #expect(manager.pageCount == 4)  // the page was re-inserted
    }

    @Test
    func deletePageBeforeCurrentShiftsCurrentIndex() {
        let (manager, _) = makeManager(pages: 4, current: 3)
        manager.deletePage(at: 1)
        #expect(manager.currentPageIndex == 2)
    }

    @Test
    func deletePageRefusesToEmptyTheDocument() {
        let (manager, _) = makeManager(pages: 1)
        manager.deletePage(at: 0)
        #expect(manager.pageCount == 1)  // guard: the last page is never deleted
        #expect(!manager.isDirty)
    }

    // MARK: - Copy / Paste

    @Test
    func copyThenPasteInsertsAfterBumpsVersionAndUndoRemoves() {
        let (manager, undo) = makeManager(pages: 2)
        var mutations: [PageMutation] = []
        manager.pageMutationHandler = { mutations.append($0) }
        let versionBefore = manager.pageVersion

        manager.copyPage(at: 0)
        #expect(manager.canPaste)

        grouped(undo) { _ = manager.pastePage(after: 0) }

        #expect(manager.pageCount == 3)
        #expect(manager.currentPageIndex == 1)   // lands on the pasted page
        #expect(manager.pageVersion > versionBefore)
        #expect(mutations == [.inserted(at: 1)])

        undo.undo()
        #expect(manager.pageCount == 2)
    }

    @Test
    func pasteWithoutACopiedPageFails() {
        let (manager, _) = makeManager(pages: 2)
        #expect(!manager.pastePage(after: 0))
        #expect(manager.pageCount == 2)
    }

    // MARK: - Duplicate

    @Test
    func duplicateInsertsACopyAndUndoRemovesIt() {
        let (manager, undo) = makeManager(pages: 3)
        var mutations: [PageMutation] = []
        manager.pageMutationHandler = { mutations.append($0) }

        grouped(undo) { manager.duplicatePage(at: 1) }

        #expect(manager.pageCount == 4)
        #expect(mutations == [.inserted(at: 2)])
        #expect(manager.isDirty)

        undo.undo()
        #expect(manager.pageCount == 3)
    }

    // MARK: - Move

    @Test
    func movePageReordersFiresMovedAndUndoRestores() {
        let (manager, undo) = makeManager(pages: 4)
        var mutations: [PageMutation] = []
        manager.pageMutationHandler = { mutations.append($0) }
        let firstPage = manager.document?.page(at: 0)

        grouped(undo) { manager.movePage(from: 0, to: 2) }

        #expect(mutations == [.moved(from: 0, to: 2)])
        #expect(manager.document?.page(at: 2) === firstPage)  // page 0 now sits at index 2
        #expect(manager.isDirty)

        undo.undo()
        #expect(manager.document?.page(at: 0) === firstPage)  // moved back
    }

    @Test
    func moveFollowsTheCurrentPage() {
        let (manager, _) = makeManager(pages: 4, current: 0)
        manager.movePage(from: 0, to: 2)
        #expect(manager.currentPageIndex == 2)
    }

    // MARK: - Visible edits

    @Test
    func noteVisibleEditOnAPageMarksDirtyBumpsVersionAndItsThumbnail() {
        let (manager, _) = makeManager(pages: 3)
        let versionBefore = manager.pageVersion
        let editedRevisionBefore = manager.thumbnailRevision(for: 1)
        let otherRevisionBefore = manager.thumbnailRevision(for: 0)

        manager.noteVisibleEdit(on: manager.document?.page(at: 1))

        #expect(manager.isDirty)
        #expect(manager.pageVersion == versionBefore + 1)
        #expect(manager.thumbnailRevision(for: 1) != editedRevisionBefore)  // edited page invalidated
        #expect(manager.thumbnailRevision(for: 0) == otherRevisionBefore)   // other pages untouched
    }

    @Test
    func noteVisibleEditWithoutAPageMarksDirtyAndBumpsVersionOnly() {
        let (manager, _) = makeManager(pages: 3)
        let versionBefore = manager.pageVersion
        let revisionBefore = manager.thumbnailRevision(for: 0)

        manager.noteVisibleEdit(on: nil)

        #expect(manager.isDirty)
        #expect(manager.pageVersion == versionBefore + 1)
        #expect(manager.thumbnailRevision(for: 0) == revisionBefore)  // no thumbnail invalidated
    }

    // MARK: - Rotate

    @Test
    func rotateChangesRotationMarksDirtyAndUndoReverts() {
        let (manager, undo) = makeManager(pages: 2)
        let page = manager.document!.page(at: 0)!
        let original = page.rotation

        grouped(undo) { manager.rotatePage(at: 0, clockwise: true) }

        #expect(page.rotation == (original + 90) % 360)
        #expect(manager.isDirty)

        undo.undo()
        #expect(page.rotation == original)
    }
}
