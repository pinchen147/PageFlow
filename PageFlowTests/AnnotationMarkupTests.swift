import AppKit
import PDFKit
import Testing
@testable import PageFlow

@MainActor
@Suite("Cross-page PDF markup", .serialized)
struct AnnotationMarkupTests {
    private let text = [
        "First page selection\nSecond line on the first page",
        "Middle page selection\nSecond line on the middle page",
        "Final page selection\nSecond line on the final page"
    ]

    private struct AnnotationState {
        let type: String?
        let bounds: CGRect
        let points: [CGPoint]
    }

    private struct PageState {
        let text: String?
        let bounds: CGRect
        let annotations: [AnnotationState]
    }

    private func selection(in document: PDFDocument) throws -> PDFSelection {
        let first = try #require(document.page(at: 0))
        let last = try #require(document.page(at: document.pageCount - 1))
        try #require(last.numberOfCharacters > 0)
        let selection = try #require(document.selection(
            from: first, atCharacterIndex: 0,
            to: last, atCharacterIndex: last.numberOfCharacters - 1
        ))
        try #require(selection.pages.count == 3, "The regression needs one real selection spanning all three pages")
        return selection
    }

    private func snapshot(_ document: PDFDocument) throws -> [PageState] {
        try (0..<document.pageCount).map { index in
            let page = try #require(document.page(at: index))
            return PageState(text: page.string, bounds: page.bounds(for: .mediaBox), annotations: page.annotations.map {
                AnnotationState(type: $0.type, bounds: $0.bounds, points: $0.quadrilateralPoints?.map(\.pointValue) ?? [])
            })
        }
    }

    private func expectPoint(_ actual: CGPoint, _ expected: CGPoint) {
        #expect(abs(actual.x - expected.x) < 0.01)
        #expect(abs(actual.y - expected.y) < 0.01)
    }

    private func expectBounds(_ actual: CGRect, _ expected: CGRect) {
        expectPoint(actual.origin, expected.origin)
        #expect(abs(actual.width - expected.width) < 0.01)
        #expect(abs(actual.height - expected.height) < 0.01)
    }

    private func expectSaved(_ manager: PDFManager, at url: URL, matching expected: [PageState]) throws {
        try #require(manager.saveSync())
        #expect(!manager.isDirty)
        let reopened = try #require(PDFDocument(url: url))
        let actual = try snapshot(reopened)
        try #require(actual.count == expected.count)
        for (page, original) in zip(actual, expected) {
            #expect(page.text == original.text)
            expectBounds(page.bounds, original.bounds)
            try #require(page.annotations.count == original.annotations.count)
            for (annotation, originalAnnotation) in zip(page.annotations, original.annotations) {
                #expect(annotation.type == originalAnnotation.type)
                expectBounds(annotation.bounds, originalAnnotation.bounds)
                try #require(annotation.points.count == originalAnnotation.points.count)
                for (point, originalPoint) in zip(annotation.points, originalAnnotation.points) {
                    expectPoint(point, originalPoint)
                }
            }
        }
    }

    @Test("one cross-page markup command saves and undoes every selected page", arguments: [false, true])
    func markupAcrossPages(underline: Bool) throws {
        let document = try #require(makeTextDocument(pages: text))
        let selection = try selection(in: document)
        let original = try snapshot(document)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("markup-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = PDFManager()
        manager.document = document
        manager.documentURL = url
        let annotations = AnnotationManager()
        let undo = UndoManager()
        undo.groupsByEvent = false
        annotations.configure(pdfManager: manager,
                              selectionProvider: { (selection, selection.pages.first) },
                              undoManagerProvider: { undo })
        let revisions = (0..<3).map { manager.thumbnailRevision(for: $0) }
        let action = underline ? "Add Underline" : "Add Highlight"

        // A caller-owned group also lets the original implementation reach the
        // cross-page behavior instead of throwing for ungrouped registration.
        undo.beginUndoGrouping()
        if underline { annotations.underlineSelection() } else { annotations.highlightSelection() }
        #expect(undo.groupingLevel == 1, "The command must not close its caller's group")
        undo.endUndoGrouping()
        #expect(undo.undoActionName == action)
        try #require(selection.pages.allSatisfy { $0.annotations.count == 1 })
        for (index, page) in selection.pages.enumerated() {
            let annotation = try #require(page.annotations.first)
            #expect(annotation.type == (underline ? "Underline" : "Highlight"))
            #expect(annotation.markupType == (underline ? .underline : .highlight))
            #expect(page.string == original[index].text)
            expectBounds(annotation.bounds, selection.bounds(for: page))
            let lines = selection.selectionsByLine().filter { $0.pages.contains { $0 === page } }
            let points = try #require(annotation.quadrilateralPoints).map(\.pointValue)
            try #require(points.count == lines.count * 4)
            for (lineIndex, line) in lines.enumerated() {
                let rect = line.bounds(for: page)
                let corners = [
                    CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
                    CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY)
                ]
                for corner in 0..<4 {
                    let point = points[lineIndex * 4 + corner]
                    expectPoint(CGPoint(x: point.x + annotation.bounds.minX, y: point.y + annotation.bounds.minY), corners[corner])
                }
            }
            #expect(manager.thumbnailRevision(for: index).pageVersion == revisions[index].pageVersion + 1)
        }
        try #require(annotations.selectedAnnotation?.page != nil)
        let markedUp = try snapshot(document)
        try expectSaved(manager, at: url, matching: markedUp)

        undo.undo()
        #expect(selection.pages.allSatisfy { $0.annotations.isEmpty })
        #expect(annotations.selectedAnnotation == nil)
        #expect(!undo.canUndo, "All pages must belong to one history entry")
        #expect(undo.redoActionName == action)
        #expect(manager.isDirty)
        for index in 0..<3 {
            #expect(manager.thumbnailRevision(for: index).pageVersion == revisions[index].pageVersion + 2)
        }
        try expectSaved(manager, at: url, matching: original)

        undo.redo()
        #expect(selection.pages.allSatisfy { $0.annotations.count == 1 })
        #expect(!undo.canRedo)
        #expect(undo.undoActionName == action)
        #expect(manager.isDirty)
        for index in 0..<3 {
            #expect(manager.thumbnailRevision(for: index).pageVersion == revisions[index].pageVersion + 3)
        }
        try expectSaved(manager, at: url, matching: markedUp)
    }

    @Test("markup owns a complete Undo group when event grouping is disabled")
    func markupWithoutOuterUndoGroup() throws {
        let document = try #require(makeTextDocument(pages: text))
        let selection = try selection(in: document)
        let manager = PDFManager()
        manager.document = document
        let annotations = AnnotationManager()
        let undo = UndoManager()
        undo.groupsByEvent = false
        annotations.configure(pdfManager: manager,
                              selectionProvider: { (selection, selection.pages.first) },
                              undoManagerProvider: { undo })
        annotations.highlightSelection()
        #expect(undo.groupingLevel == 0)
        try #require(selection.pages.allSatisfy { $0.annotations.count == 1 })
        undo.undo()
        #expect(selection.pages.allSatisfy { $0.annotations.isEmpty })
        #expect(!undo.canUndo)
        undo.redo()
        #expect(selection.pages.allSatisfy { $0.annotations.count == 1 })
        #expect(!undo.canRedo)
    }

    @Test("user-password permission denial leaves source and history untouched", arguments: [false, true])
    func rejectsCommentingDenied(underline: Bool) throws {
        let document = try #require(makeTextDocument(pages: text))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("markup-permission-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try #require(document.write(to: url, withOptions: [
            .ownerPasswordOption: "owner-secret", .userPasswordOption: "user-secret",
            .accessPermissionsOption: NSNumber(value: 1 << 4) // PDFAllowsContentCopying only.
        ]))
        let restricted = try #require(PDFDocument(url: url))
        try #require(restricted.isLocked)
        try #require(restricted.unlock(withPassword: "user-secret"))
        try #require(restricted.permissionsStatus == .user)
        try #require(!restricted.isLocked && restricted.allowsCopying && !restricted.allowsCommenting)
        let selection = try selection(in: restricted)
        try #require(selection.pages.allSatisfy { $0.document === restricted && restricted.index(for: $0) != NSNotFound })
        let manager = PDFManager()
        manager.document = restricted
        try expectRejected(manager: manager, selection: selection, underline: underline)
    }

    @Test("a selection from the replaced PDF cannot mutate either document", arguments: [false, true])
    func rejectsStaleSelection(underline: Bool) throws {
        let old = try #require(makeTextDocument(pages: text))
        let selection = try selection(in: old)
        let replacement = try #require(makeTextDocument(pages: ["New first", "New middle", "New last"]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("markup-replacement-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try #require(replacement.write(to: url))
        let manager = PDFManager()
        manager.document = old
        guard case .success = manager.loadDocument(from: url) else {
            Issue.record("Replacement PDF must load through the real document owner")
            return
        }
        let active = try #require(manager.document)
        try #require(active !== old && !active.isLocked && active.allowsCommenting)
        try expectRejected(manager: manager, selection: selection, underline: underline)
    }

    @Test("every selected page must still belong to the active document")
    func rejectsSelectionContainingMovedPage() throws {
        let document = try #require(makeTextDocument(pages: text))
        let selection = try selection(in: document)
        let moved = try #require(document.page(at: 2))
        let other = try #require(makeTextDocument(pages: ["Other one", "Other two", "Other three"]))
        document.removePage(at: 2)
        other.insert(moved, at: other.pageCount)
        try #require(selection.pages.count == 3)
        try #require(selection.pages.first?.document === document)
        try #require(selection.pages.contains { $0 === moved && $0.document === other })
        let manager = PDFManager()
        manager.document = document
        try expectRejected(manager: manager, selection: selection, underline: false)
    }

    private func expectRejected(manager: PDFManager, selection: PDFSelection, underline: Bool) throws {
        let document = try #require(manager.document)
        let pages = try (0..<document.pageCount).map { try #require(document.page(at: $0)) }
        let revisions = (0..<document.pageCount).map { manager.thumbnailRevision(for: $0) }
        let version = manager.pageVersion
        let closeRevision = manager.closeRevision
        let annotations = AnnotationManager()
        let undo = UndoManager()
        annotations.configure(pdfManager: manager,
                              selectionProvider: { (selection, selection.pages.first) },
                              undoManagerProvider: { undo })
        try #require(!undo.canUndo && !undo.canRedo)
        if underline { annotations.underlineSelection() } else { annotations.highlightSelection() }
        #expect(pages.allSatisfy { $0.annotations.isEmpty })
        #expect(selection.pages.allSatisfy { $0.annotations.isEmpty })
        #expect(annotations.selectedAnnotation == nil)
        #expect(!undo.canUndo && !undo.canRedo)
        #expect(!manager.isDirty)
        #expect(manager.pageVersion == version)
        #expect(manager.closeRevision == closeRevision)
        #expect((0..<document.pageCount).map { manager.thumbnailRevision(for: $0) } == revisions)
    }
}
