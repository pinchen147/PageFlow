//
//  CommentManager.swift
//  PageFlow
//
//  Manages creation, editing, deletion, and loading of PDF comments.
//

import AppKit
import Foundation
import Observation
import PDFKit

@Observable
@MainActor
final class CommentManager {
    // MARK: - State

    var comments: [CommentModel] = []
    var selectedCommentID: UUID?
    var editingCommentID: UUID?

    private weak var pdfManager: PDFManager?
    private var selectionProvider: (() -> (PDFSelection?, PDFPage?))?
    private var highlights: [UUID: PDFAnnotation] = [:]

    // MARK: - Configuration

    func configure(
        pdfManager: PDFManager,
        selectionProvider: @escaping () -> (PDFSelection?, PDFPage?)
    ) {
        self.pdfManager = pdfManager
        self.selectionProvider = selectionProvider
    }

    // MARK: - Actions

    @discardableResult
    func addComment(text: String = "") -> UUID? {
        guard let (selectionOptional, pageOptional) = selectionProvider?(),
              let page = pageOptional,
              let document = pdfManager?.document else {
            return nil
        }

        let selection = selectionOptional?.copy() as? PDFSelection
        let (lineRects, union) = selectionLineRects(selection, on: page)

        let unionRect = union ?? defaultCommentRect(on: page)
        guard let highlight = createHighlight(for: lineRects.rectsOrFallback(unionRect), union: unionRect) else {
            return nil
        }

        let commentID = UUID()
        highlight.userName = commentID.uuidString

        page.addAnnotation(highlight)

        let model = CommentModel(
            id: commentID,
            text: text,
            pageIndex: document.index(for: page),
            bounds: highlight.bounds
        )

        comments.append(model)
        highlights[commentID] = highlight
        selectedCommentID = commentID
        editingCommentID = commentID
        pdfManager?.isDirty = true

        registerUndoAdd(model, highlight: highlight, page: page)
        return commentID
    }

    func updateComment(_ id: UUID, text: String) {
        guard let index = comments.firstIndex(where: { $0.id == id }) else {
            return
        }

        let oldText = comments[index].text
        comments[index].text = text
        pdfManager?.isDirty = true

        registerUndoUpdate(id, oldText: oldText, newText: text)
    }

    func deleteComment(_ id: UUID) {
        guard let index = comments.firstIndex(where: { $0.id == id }),
              let highlight = highlights[id] else {
            return
        }

        let comment = comments[index]
        let page = highlight.page

        if let page = highlight.page {
            page.removeAnnotation(highlight)
        }

        comments.remove(at: index)
        highlights.removeValue(forKey: id)

        if selectedCommentID == id { selectedCommentID = nil }
        if editingCommentID == id { editingCommentID = nil }
        pdfManager?.isDirty = true

        if let page {
            registerUndoDelete(comment, highlight: highlight, page: page)
        }
    }

    func selectComment(_ id: UUID?) {
        selectedCommentID = id
        editingCommentID = nil

        guard let id,
              let comment = comments.first(where: { $0.id == id }) else {
            return
        }

        pdfManager?.goToPage(comment.pageIndex)
    }

    func selectAnnotation(_ annotation: PDFAnnotation) -> Bool {
        guard let match = highlights.first(where: { $0.value === annotation }) else {
            return false
        }

        selectComment(match.key)
        return true
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
        highlights.removeAll()
        selectedCommentID = nil
        editingCommentID = nil

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }

            let commentHighlights = page.annotations.filter(isCommentHighlight)

            for highlight in commentHighlights {
                let commentID = UUID(uuidString: highlight.userName ?? "") ?? UUID()
                highlight.userName = commentID.uuidString

                let model = CommentModel(
                    id: commentID,
                    text: highlight.contents ?? "",
                    pageIndex: pageIndex,
                    bounds: highlight.bounds
                )

                comments.append(model)
                highlights[commentID] = highlight
            }
        }
    }

    func clearComments() {
        comments.removeAll()
        highlights.removeAll()
        selectedCommentID = nil
        editingCommentID = nil
    }

    // MARK: - Private Helpers

    private func selectionLineRects(_ selection: PDFSelection?, on page: PDFPage) -> ([CGRect], CGRect?) {
        guard let selection else { return ([], nil) }

        let rects = selection.selectionsByLine()
            .map { $0.bounds(for: page) }
            .filter { !$0.isNull && !$0.isEmpty }

        let union = rects.unionRect
        return (rects, union)
    }

    private func defaultCommentRect(on page: PDFPage) -> CGRect {
        let pageRect = page.bounds(for: .mediaBox)
        let size = CGSize(width: DesignTokens.commentDefaultRectWidth, height: DesignTokens.commentDefaultRectHeight)
        return CGRect(
            x: pageRect.midX - size.width / 2,
            y: pageRect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func createHighlight(for rects: [CGRect], union: CGRect) -> PDFAnnotation? {
        guard !rects.isEmpty else { return nil }

        let highlight = PDFAnnotation(bounds: union, forType: .highlight, withProperties: nil)
        highlight.markupType = .highlight
        highlight.color = DesignTokens.commentHighlightColor
        highlight.quadrilateralPoints = buildQuadPoints(from: rects, relativeTo: union)
        return highlight
    }

    private func buildQuadPoints(from rects: [CGRect], relativeTo union: CGRect) -> [NSValue] {
        rects.flatMap { rect -> [NSValue] in
            let tl = CGPoint(x: rect.minX - union.minX, y: rect.maxY - union.minY)
            let tr = CGPoint(x: rect.maxX - union.minX, y: rect.maxY - union.minY)
            let bl = CGPoint(x: rect.minX - union.minX, y: rect.minY - union.minY)
            let br = CGPoint(x: rect.maxX - union.minX, y: rect.minY - union.minY)
            return [tl, tr, bl, br].map(NSValue.init(point:))
        }
    }

    private func isCommentHighlight(_ annotation: PDFAnnotation) -> Bool {
        guard annotation.type == PDFAnnotationSubtype.highlight.rawValue else { return false }
        guard let color = annotation.color.usingColorSpace(.deviceRGB) else { return false }

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)

        let target = DesignTokens.commentHighlightColor.usingColorSpace(.deviceRGB)
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        target?.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)

        let tolerance: CGFloat = 0.1
        let matches =
            abs(r - tr) < tolerance &&
            abs(g - tg) < tolerance &&
            abs(b - tb) < tolerance &&
            abs(a - ta) < 0.15
        return matches
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
        highlights.removeValue(forKey: comment.id)
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
        highlights[comment.id] = highlight
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
        highlights[comment.id] = highlight
        pdfManager?.isDirty = true

        guard let undoManager = NSApp.keyWindow?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            target.deleteComment(comment.id)
        }
        undoManager.setActionName("Delete Comment")
    }
}

private extension Array where Element == CGRect {
    var unionRect: CGRect? {
        guard let first = first else { return nil }
        return dropFirst().reduce(first) { $0.union($1) }
    }

    func rectsOrFallback(_ fallback: CGRect) -> [CGRect] {
        isEmpty ? [fallback] : self
    }
}
