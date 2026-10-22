//
//  PDFPermissionTests.swift
//  PageFlowTests
//
//  Commands a restricted PDF forbids must change nothing: PDFKit refuses those
//  edits silently, so dirty state, Undo, thumbnails and page tracking would
//  otherwise record edits that never happened.
//

import AppKit
import PDFKit
import Testing
@testable import PageFlow

@MainActor
@Suite("PDF permission gating", .serialized)
struct PDFPermissionTests {
    private static let pages = ["First page", "Second page", "Third page"]

    /// A document encrypted with only an owner password: it opens without a
    /// password and reports exactly `allowed`.
    private func restricted(_ allowed: [PDFAccessPermissions], annotated: Bool = false) throws -> PDFDocument {
        let plain = try #require(makeTextDocument(pages: Self.pages))
        if annotated {
            let page = try #require(plain.page(at: 0))
            page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 80, height: 16), forType: .highlight, withProperties: nil))
        }
        let bits = allowed.reduce(UInt(0)) { $0 | $1.rawValue }
        let data = try #require(plain.dataRepresentation(options: [
            PDFDocumentWriteOption.ownerPasswordOption: "owner-secret",
            PDFDocumentWriteOption.accessPermissionsOption: NSNumber(value: bits),
        ]))
        let document = try #require(PDFDocument(data: data))
        try #require(document.isEncrypted && !document.isLocked && document.permissionsStatus == .user)
        return document
    }

    private struct State: Equatable {
        let texts: [String]
        let rotations: [Int]
        let annotations: [Int]
    }

    private func state(_ document: PDFDocument) -> State {
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0) }
        return State(texts: pages.map { $0.string ?? "" }, rotations: pages.map(\.rotation), annotations: pages.map(\.annotations.count))
    }

    private func manager(for document: PDFDocument) -> (PDFManager, UndoManager, () -> [PageMutation]) {
        let manager = PDFManager()
        manager.document = document
        manager.currentPageIndex = 0
        manager.currentPage = document.page(at: 0)
        let undo = UndoManager()
        manager.undoManagerProvider = { undo }
        var mutations: [PageMutation] = []
        manager.pageMutationHandler = { mutations.append($0) }
        return (manager, undo, { mutations })
    }

    @Test("permissions follow the document's narrowest bits; a locked or absent document allows nothing")
    func permissionsReflectDocument() throws {
        #expect(PDFPermissions(nil) == PDFPermissions())
        let open = try #require(makeTextDocument(pages: Self.pages))
        #expect(PDFPermissions(open) == PDFPermissions(annotate: true, editPages: true, copy: true, print: true))
        let limited = try restricted([.allowsCommenting, .allowsLowQualityPrinting])
        #expect(PDFPermissions(limited) == PDFPermissions(annotate: true, editPages: false, copy: false, print: true))
        let data = try #require(open.dataRepresentation(options: [
            PDFDocumentWriteOption.ownerPasswordOption: "o", PDFDocumentWriteOption.userPasswordOption: "u",
        ]))
        let locked = try #require(PDFDocument(data: data))
        try #require(locked.isLocked)
        #expect(PDFPermissions(locked) == PDFPermissions())
    }

    @Test("page commands without assembly permission leave pages, dirty state, Undo and thumbnails alone",
          arguments: ["rotate", "delete", "duplicate", "move", "cut", "paste"])
    func pageCommandsRefused(command: String) throws {
        let document = try restricted([.allowsCommenting, .allowsContentCopying])
        let (manager, undo, mutations) = manager(for: document)
        let before = state(document)
        let pageVersion = manager.pageVersion
        try #require(!undo.canUndo)
        switch command {
        case "rotate": manager.rotatePage(at: 1, clockwise: true)
        case "delete": manager.deletePage(at: 1)
        case "duplicate": manager.duplicatePage(at: 1)
        case "move": manager.movePage(from: 0, to: 2)
        case "cut": manager.cutPage(at: 1)
        default:
            manager.copyPage(at: 0)
            #expect(!manager.pastePage(after: 1))
        }
        #expect(state(document) == before)
        #expect(!manager.isDirty)
        #expect(manager.pageVersion == pageVersion)
        #expect(mutations().isEmpty)
        #expect(!undo.canUndo)
        #expect(manager.currentPageIndex == 0)
    }

    @Test("copying a page needs copy permission, and so does cutting one")
    func copyAndCutPageRefused() throws {
        let document = try restricted([.allowsDocumentAssembly, .allowsCommenting])
        let (manager, undo, mutations) = manager(for: document)
        let before = state(document)
        manager.copyPage(at: 0)
        #expect(!manager.canPaste)
        manager.cutPage(at: 1)
        #expect(state(document) == before)
        #expect(!manager.isDirty)
        #expect(mutations().isEmpty)
        #expect(!undo.canUndo)
    }

    @Test("annotation and comment commands without commenting permission change nothing")
    func annotationCommandsRefused() throws {
        let document = try restricted([.allowsDocumentAssembly, .allowsContentCopying], annotated: true)
        let (manager, undo, _) = manager(for: document)
        let page = try #require(document.page(at: 0))
        let existing = try #require(page.annotations.first)
        let bounds = page.bounds(for: PDFDisplayBox.mediaBox)
        let selection = try #require(page.selection(for: bounds))
        let annotations = AnnotationManager()
        annotations.configure(pdfManager: manager, selectionProvider: { (selection, page) }, undoManagerProvider: { undo })
        let comments = CommentManager()
        comments.configure(pdfManager: manager, selectionProvider: { (selection, page) }, undoManagerProvider: { undo })
        let before = state(document)
        let color = existing.color

        annotations.highlightSelection()
        annotations.removeAnnotation(existing)
        annotations.selectedAnnotation = existing
        annotations.updateSelectedAnnotationColor(.systemPurple)
        #expect(comments.addComment(text: "Note") == nil)
        #expect(!comments.canEdit)
        comments.startEditing(UUID())
        #expect(comments.editingCommentID == nil)

        #expect(state(document) == before)
        #expect(existing.color == color)
        #expect(comments.comments.isEmpty)
        #expect(!manager.isDirty)
        #expect(!undo.canUndo)
    }

    @Test("a comment is only added to a page of the open document")
    func commentRejectsForeignPage() throws {
        let document = try #require(makeTextDocument(pages: Self.pages))
        let foreign = try #require(makeTextDocument(pages: ["Elsewhere"])?.page(at: 0))
        let (manager, undo, _) = manager(for: document)
        let comments = CommentManager()
        comments.configure(pdfManager: manager, selectionProvider: { (nil, foreign) }, undoManagerProvider: { undo })
        #expect(comments.addComment(text: "Note") == nil)
        #expect(foreign.annotations.isEmpty)
        #expect(comments.comments.isEmpty)
        #expect(!undo.canUndo)
    }
}
