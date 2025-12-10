//
//  CommentManager.swift
//  PageFlow
//
//  Manages creation, editing, and deletion of PDF comments with grey highlights
//

import Foundation
import PDFKit
import AppKit
import Observation

@Observable
@MainActor
final class CommentManager {
    // MARK: - State

    var comments: [CommentModel] = []
    var selectedCommentID: UUID?
    var editingCommentID: UUID?

    private weak var pdfManager: PDFManager?
    private var selectionProvider: (() -> (PDFSelection?, PDFPage?))?
    private var annotationMap: [UUID: PDFAnnotation] = [:]

    // MARK: - Configuration

    func configure(
        pdfManager: PDFManager,
        selectionProvider: @escaping () -> (PDFSelection?, PDFPage?)
    ) {
        self.pdfManager = pdfManager
        self.selectionProvider = selectionProvider
    }

    // MARK: - Actions

    func addComment() -> UUID? {
        guard let (selectionOptional, pageOptional) = selectionProvider?(),
              let page = pageOptional,
              let document = pdfManager?.document else {
            return nil
        }

        let pageIndex = document.index(for: page)
        let selection = selectionOptional?.copy() as? PDFSelection
        let selectionBounds = selection?.bounds(for: page) ?? .null
        let bounds: CGRect
        if !selectionBounds.isNull, !selectionBounds.isEmpty {
            bounds = selectionBounds
        } else {
            let pageRect = page.bounds(for: .mediaBox)
            let size = CGSize(width: 140, height: 32)
            bounds = CGRect(
                x: pageRect.midX - size.width / 2,
                y: pageRect.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        }

        let highlight = createHighlightAnnotation(selection: selection, page: page, bounds: bounds)
        let commentID = UUID()
        highlight.userName = commentID.uuidString

        page.addAnnotation(highlight)
        annotationMap[commentID] = highlight

        let comment = CommentModel(
            id: commentID,
            text: "",
            pageIndex: pageIndex,
            bounds: bounds
        )

        comments.append(comment)
        selectedCommentID = commentID
        editingCommentID = commentID
        pdfManager?.isDirty = true

        registerUndoAdd(comment, highlight: highlight, page: page)
        return commentID
    }

    func updateComment(_ id: UUID, text: String) {
        guard let index = comments.firstIndex(where: { $0.id == id }) else { return }

        let oldText = comments[index].text
        comments[index].text = text

        // Store text in annotation for persistence
        if let annotation = annotationMap[id] {
            annotation.contents = text
        }

        pdfManager?.isDirty = true
        registerUndoUpdate(id, oldText: oldText, newText: text)
    }

    func deleteComment(_ id: UUID) {
        guard let index = comments.firstIndex(where: { $0.id == id }),
              let annotation = annotationMap[id],
              let page = annotation.page else {
            return
        }

        let comment = comments[index]
        page.removeAnnotation(annotation)
        comments.remove(at: index)
        annotationMap.removeValue(forKey: id)

        if selectedCommentID == id { selectedCommentID = nil }
        if editingCommentID == id { editingCommentID = nil }

        pdfManager?.isDirty = true
        registerUndoDelete(comment, highlight: annotation, page: page)
    }

    func selectComment(_ id: UUID?) {
        selectedCommentID = id
        editingCommentID = nil

        guard let id = id,
              let comment = comments.first(where: { $0.id == id }) else {
            return
        }

        pdfManager?.goToPage(comment.pageIndex)
    }

    func startEditing(_ id: UUID) {
        editingCommentID = id
    }

    func stopEditing() {
        editingCommentID = nil
    }

    // MARK: - Document Loading

    func loadComments(from document: PDFDocument) {
        comments.removeAll()
        annotationMap.removeAll()
        selectedCommentID = nil
        editingCommentID = nil

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }

            for annotation in page.annotations where isCommentHighlight(annotation) {
                guard let userName = annotation.userName,
                      let commentID = UUID(uuidString: userName) else {
                    continue
                }

                let comment = CommentModel(
                    id: commentID,
                    text: annotation.contents ?? "",
                    pageIndex: pageIndex,
                    bounds: annotation.bounds
                )

                comments.append(comment)
                annotationMap[commentID] = annotation
            }
        }
    }

    func clearComments() {
        comments.removeAll()
        annotationMap.removeAll()
        selectedCommentID = nil
        editingCommentID = nil
    }

    // MARK: - Private Helpers

    private func createHighlightAnnotation(selection: PDFSelection?, page: PDFPage, bounds: CGRect) -> PDFAnnotation {
        let highlight = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        highlight.color = DesignTokens.commentHighlightColor

        let lineRects: [CGRect]
        if let selection {
            lineRects = selection.selectionsByLine()
                .map { $0.bounds(for: page) }
                .filter { !$0.isNull && !$0.isEmpty }
        } else {
            lineRects = []
        }

        if let firstRect = lineRects.first {
            let union = lineRects.dropFirst().reduce(firstRect) { $0.union($1) }
            highlight.quadrilateralPoints = buildQuadPoints(from: lineRects, relativeTo: union)
        } else {
            highlight.quadrilateralPoints = buildQuadPoints(from: [bounds], relativeTo: bounds)
        }

        return highlight
    }

    private func buildQuadPoints(from rects: [CGRect], relativeTo union: CGRect) -> [NSValue] {
        var points: [NSValue] = []
        for rect in rects {
            let tl = CGPoint(x: rect.minX - union.minX, y: rect.maxY - union.minY)
            let tr = CGPoint(x: rect.maxX - union.minX, y: rect.maxY - union.minY)
            let bl = CGPoint(x: rect.minX - union.minX, y: rect.minY - union.minY)
            let br = CGPoint(x: rect.maxX - union.minX, y: rect.minY - union.minY)
            points.append(contentsOf: [NSValue(point: tl), NSValue(point: tr), NSValue(point: bl), NSValue(point: br)])
        }
        return points
    }

    private func isCommentHighlight(_ annotation: PDFAnnotation) -> Bool {
        guard annotation.type == "Highlight" else {
            return false
        }

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        annotation.color.usingColorSpace(.deviceRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        let isGrey = abs(r - g) < 0.1 && abs(g - b) < 0.1 && abs(r - b) < 0.1
        return isGrey && a > 0.5 && a < 0.7
    }

    // MARK: - Undo/Redo

    private func registerUndoAdd(_ comment: CommentModel, highlight: PDFAnnotation, page: PDFPage) {
        guard let undoManager = NSApp.keyWindow?.undoManager else { return }

        undoManager.registerUndo(withTarget: self) { target in
            target.undoAdd(comment, highlight: highlight, page: page)
        }
        undoManager.setActionName("Add Comment")
    }

    private func undoAdd(_ comment: CommentModel, highlight: PDFAnnotation, page: PDFPage) {
        page.removeAnnotation(highlight)
        comments.removeAll { $0.id == comment.id }
        annotationMap.removeValue(forKey: comment.id)
        if selectedCommentID == comment.id { selectedCommentID = nil }
        if editingCommentID == comment.id { editingCommentID = nil }
        pdfManager?.isDirty = true

        guard let undoManager = NSApp.keyWindow?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            target.redoAdd(comment, highlight: highlight, page: page)
        }
        undoManager.setActionName("Add Comment")
    }

    private func redoAdd(_ comment: CommentModel, highlight: PDFAnnotation, page: PDFPage) {
        page.addAnnotation(highlight)
        comments.append(comment)
        annotationMap[comment.id] = highlight
        pdfManager?.isDirty = true

        registerUndoAdd(comment, highlight: highlight, page: page)
    }

    private func registerUndoUpdate(_ id: UUID, oldText: String, newText: String) {
        guard let undoManager = NSApp.keyWindow?.undoManager else { return }

        undoManager.registerUndo(withTarget: self) { target in
            target.updateComment(id, text: oldText)
        }
        undoManager.setActionName("Edit Comment")
    }

    private func registerUndoDelete(_ comment: CommentModel, highlight: PDFAnnotation, page: PDFPage) {
        guard let undoManager = NSApp.keyWindow?.undoManager else { return }

        undoManager.registerUndo(withTarget: self) { target in
            target.undoDelete(comment, highlight: highlight, page: page)
        }
        undoManager.setActionName("Delete Comment")
    }

    private func undoDelete(_ comment: CommentModel, highlight: PDFAnnotation, page: PDFPage) {
        page.addAnnotation(highlight)
        comments.append(comment)
        annotationMap[comment.id] = highlight
        pdfManager?.isDirty = true

        guard let undoManager = NSApp.keyWindow?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            target.deleteComment(comment.id)
        }
        undoManager.setActionName("Delete Comment")
    }
}
