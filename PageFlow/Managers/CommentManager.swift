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
import os.log

@Observable
@MainActor
final class CommentManager {
    private static let pageFlowTypeKey = PDFAnnotationKey(rawValue: "PageFlowType")
    private static let pageFlowCommentValue = "pageflow-comment"
    private let logger = Logger(subsystem: "com.pageflow", category: "CommentManager")

    deinit {
        #if DEBUG
        Swift.print("[deinit] CommentManager")
        #endif
    }

    // MARK: - State

    var comments: [CommentModel] = []
    var selectedCommentID: UUID?
    var editingCommentID: UUID?
    private(set) var editingRevision = 0

    /// Comments in sidebar display order (creation time). Lives here so the
    /// display rule is testable through the manager's interface — same pattern
    /// as `BookmarkManager.sortedBookmarks`.
    var sortedComments: [CommentModel] {
        comments.sorted { $0.createdAt < $1.createdAt }
    }

    private weak var pdfManager: PDFManager?
    private var selectionProvider: (() -> (PDFSelection?, PDFPage?))?
    private var undoManagerProvider: (() -> UndoManager?)?
    private var highlights: [UUID: PDFAnnotation] = [:]
    /// The document `comments` were read from. A rebuilt view of it has nothing to read.
    @ObservationIgnored private weak var loadedDocument: PDFDocument?
    @ObservationIgnored private var excerptCache: [UUID: CachedExcerpt] = [:]

    struct Presentation {
        let color: NSColor
        let excerpt: String?
    }

    /// PDFKit annotations are opaque to Observation; pageVersion covers color commands and Undo.
    func presentation(for id: UUID) -> Presentation? {
        _ = pdfManager?.pageVersion
        guard let annotation = highlights[id], let page = annotation.page else { return nil }
        let anchor = ExcerptAnchor(annotation: annotation, page: page)
        let excerpt: String?
        if let cached = excerptCache[id], cached.anchor == anchor {
            excerpt = cached.text
        } else {
            excerpt = anchoredExcerpt(annotation, on: page)
            excerptCache[id] = CachedExcerpt(anchor: anchor, text: excerpt)
        }
        return Presentation(color: annotation.color, excerpt: excerpt)
    }

    private struct ExcerptAnchor: Equatable {
        let annotationID: ObjectIdentifier
        let pageID: ObjectIdentifier
        let bounds: CGRect
        let points: [CGPoint]
        let pointCount: Int

        init(annotation: PDFAnnotation, page: PDFPage) {
            annotationID = ObjectIdentifier(annotation)
            pageID = ObjectIdentifier(page)
            bounds = annotation.bounds
            let values = annotation.quadrilateralPoints ?? []
            pointCount = values.count
            points = values.prefix(128).map(\.pointValue)
        }
    }

    private struct CachedExcerpt {
        let anchor: ExcerptAnchor
        let text: String?
    }

    // MARK: - Configuration

    func configure(
        pdfManager: PDFManager,
        selectionProvider: @escaping () -> (PDFSelection?, PDFPage?),
        undoManagerProvider: @escaping () -> UndoManager?
    ) {
        self.pdfManager = pdfManager
        self.selectionProvider = selectionProvider
        self.undoManagerProvider = undoManagerProvider
    }

    private func getUndoManager(for action: String) -> UndoManager? {
        guard let undoManager = undoManagerProvider?() else {
            logger.error("UndoManager unavailable for action: \(action)")
            return nil
        }
        return undoManager
    }

    // MARK: - Actions

    @discardableResult
    func addComment(text: String = "") -> UUID? {
        guard let manager = pdfManager, manager.permissions.annotate,
              let (selectionOptional, pageOptional) = selectionProvider?(),
              let page = pageOptional,
              let document = manager.document,
              page.document === document, document.index(for: page) != NSNotFound else {
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
        highlight.setValue(Self.pageFlowCommentValue, forAnnotationKey: Self.pageFlowTypeKey)
        highlight.modificationDate = Date()
        // What the highlight holds is what gets saved: the list is only read from it.
        if !text.isEmpty { highlight.contents = text }

        page.addAnnotation(highlight)

        let model = CommentModel(
            id: commentID,
            text: text,
            pageIndex: document.index(for: page),
            bounds: highlight.bounds
        )

        comments.append(model)
        highlights[commentID] = highlight
        let excerpt = liveExcerpt(selection, on: page)
        excerptCache[commentID] = CachedExcerpt(anchor: ExcerptAnchor(annotation: highlight, page: page), text: excerpt)
        selectedCommentID = commentID
        editingCommentID = commentID
        editingRevision &+= 1
        pdfManager?.noteVisibleEdit(on: page)

        registerUndoAdd(model, highlight: highlight, page: page)
        return commentID
    }

    func updateComment(_ id: UUID, text: String) {
        guard pdfManager?.permissions.annotate == true,
              let index = comments.firstIndex(where: { $0.id == id }) else {
            return
        }

        guard let highlight = highlights[id] else {
            logger.error("Orphaned comment missing highlight for ID \(id.uuidString, privacy: .public)")
            removeOrphanedComment(at: index, id: id)
            return
        }

        comments[index].text = text
        highlight.contents = text
        pdfManager?.isDirty = true
    }

    func deleteComment(_ id: UUID) {
        guard pdfManager?.permissions.annotate == true,
              let index = comments.firstIndex(where: { $0.id == id }),
              let highlight = highlights[id] else {
            return
        }

        let comment = comments[index]
        let page = highlight.page

        page?.removeAnnotation(highlight)

        comments.remove(at: index)
        highlights.removeValue(forKey: id)
        excerptCache.removeValue(forKey: id)

        if selectedCommentID == id { selectedCommentID = nil }
        if editingCommentID == id { editingCommentID = nil }
        pdfManager?.noteVisibleEdit(on: page)

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

        // Jump to the comment's location on its page, not just the page top.
        if let highlight = highlights[id], let page = highlight.page {
            let pageBounds = page.bounds(for: .mediaBox)
            let bounds = highlight.bounds
            // A little headroom above the highlight so it isn't flush to the top edge.
            let y = min(bounds.maxY + DesignTokens.spacingLG, pageBounds.maxY)
            // Use the highlight's own x (not the page's left edge) so a right-side
            // comment stays on screen when the page is wider than the viewport (zoom).
            let destination = PDFDestination(page: page, at: CGPoint(x: bounds.minX, y: y))
            pdfManager?.goToDestination(destination)
        } else {
            pdfManager?.jump(toPage: comment.pageIndex)
        }
    }

    func selectAnnotation(_ annotation: PDFAnnotation) -> Bool {
        guard let match = highlights.first(where: { $0.value === annotation }) else {
            return false
        }

        selectComment(match.key)
        return true
    }

    /// Whether the open document lets comments be added, edited or removed.
    var canEdit: Bool { pdfManager?.permissions.annotate == true }

    func startEditing(_ id: UUID) {
        guard canEdit else { return }
        editingCommentID = id
        editingRevision &+= 1
    }

    func stopEditing() {
        editingCommentID = nil
    }

    func commentID(for annotation: PDFAnnotation) -> UUID? {
        annotation.userName.flatMap { UUID(uuidString: $0) }
    }

    func updateCommentColor(_ id: UUID, color: NSColor) {
        guard pdfManager?.permissions.annotate == true, let highlight = highlights[id] else { return }
        let previousColor = highlight.color
        guard previousColor != color else { return }

        highlight.color = color
        pdfManager?.noteVisibleEdit(on: highlight.page)

        if let undoManager = getUndoManager(for: "Change Comment Color") {
            undoManager.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated {
                    target.updateCommentColor(id, color: previousColor)
                }
            }
            undoManager.setActionName("Change Comment Color")
        }
    }

    // MARK: - Document Loading

    /// Reads the comments of a document new to this tab. A rebuilt view of the
    /// same one keeps them, the selection and edit mode, and walks no pages.
    func loadCommentsIfNeeded(from document: PDFDocument) {
        guard loadedDocument !== document else { return }
        loadComments(from: document)
    }

    func loadComments(from document: PDFDocument) {
        loadedDocument = document
        comments.removeAll()
        highlights.removeAll()
        excerptCache.removeAll()
        selectedCommentID = nil
        editingCommentID = nil

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }

            let commentHighlights = page.annotations.filter(isCommentHighlight)

            for highlight in commentHighlights {
                let existingUUID = highlight.userName.flatMap { UUID(uuidString: $0) }
                let isOwnID = existingUUID.map { highlights[$0] == nil } ?? false
                let commentID = isOwnID ? existingUUID ?? UUID() : UUID()
                if !isOwnID {
                    // A missing or invalid userName, or one a copied page shares
                    // (a row must stand for one highlight to be deleted with it).
                    highlight.userName = commentID.uuidString
                }

                let model = CommentModel(
                    id: commentID,
                    text: highlight.contents ?? "",
                    pageIndex: pageIndex,
                    bounds: highlight.bounds,
                    createdAt: highlight.modificationDate ?? Date()
                )

                comments.append(model)
                highlights[commentID] = highlight
            }
        }
    }

    /// A copied page's highlights keep their comments' ids. Each becomes a
    /// comment of its own, so deleting it never reaches the one it was copied from.
    func adoptCopiedComments(onPageAt index: Int) {
        guard let page = pdfManager?.document?.page(at: index) else { return }
        for highlight in page.annotations.filter(isCommentHighlight) {
            guard let id = commentID(for: highlight), let original = highlights[id], original !== highlight else { continue }
            let copyID = UUID()
            highlight.userName = copyID.uuidString
            comments.append(CommentModel(id: copyID, text: highlight.contents ?? "", pageIndex: index, bounds: highlight.bounds,
                                         createdAt: highlight.modificationDate ?? Date()))
            highlights[copyID] = highlight
        }
    }

    func clearComments() {
        loadedDocument = nil
        comments.removeAll()
        highlights.removeAll()
        excerptCache.removeAll()
        selectedCommentID = nil
        editingCommentID = nil
    }

    func reconcilePageIndices() {
        guard let document = pdfManager?.document else { return }

        var updatedComments: [CommentModel] = []
        var updatedHighlights: [UUID: PDFAnnotation] = [:]
        var orphanedPairs: [(CommentModel, PDFAnnotation)] = []

        for comment in comments {
            guard let highlight = highlights[comment.id] else { continue }

            if let page = highlight.page {
                let pageIndex = document.index(for: page)
                if pageIndex != NSNotFound {
                    var updatedComment = comment
                    updatedComment.pageIndex = pageIndex
                    updatedComment.bounds = highlight.bounds
                    updatedComments.append(updatedComment)
                    updatedHighlights[comment.id] = highlight
                    continue
                }
            }

            orphanedPairs.append((comment, highlight))
        }

        if let selectedCommentID, updatedHighlights[selectedCommentID] == nil {
            self.selectedCommentID = nil
        }

        if let editingCommentID, updatedHighlights[editingCommentID] == nil {
            self.editingCommentID = nil
        }

        comments = updatedComments
        highlights = updatedHighlights
        excerptCache = excerptCache.filter { updatedHighlights[$0.key] != nil }

        // Register undo for orphaned comments so they restore when the page returns.
        if !orphanedPairs.isEmpty, let undoManager = undoManagerProvider?() {
            undoManager.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated {
                    target.restoreCommentsForUndo(orphanedPairs)
                }
            }
        }
    }

    private func restoreCommentsForUndo(_ pairs: [(CommentModel, PDFAnnotation)]) {
        let document = pdfManager?.document

        for (comment, highlight) in pairs {
            var restored = comment
            if let document, let page = highlight.page {
                let pageIndex = document.index(for: page)
                if pageIndex != NSNotFound {
                    restored.pageIndex = pageIndex
                    restored.bounds = highlight.bounds
                }
            }
            comments.append(restored)
            highlights[comment.id] = highlight
        }

        if let undoManager = undoManagerProvider?() {
            undoManager.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated {
                    target.removeCommentsForRedo(pairs)
                }
            }
        }
    }

    private func removeCommentsForRedo(_ pairs: [(CommentModel, PDFAnnotation)]) {
        let idsToRemove = Set(pairs.map { $0.0.id })
        comments.removeAll { idsToRemove.contains($0.id) }
        highlights = highlights.filter { !idsToRemove.contains($0.key) }
        excerptCache = excerptCache.filter { !idsToRemove.contains($0.key) }

        if let selectedCommentID, idsToRemove.contains(selectedCommentID) {
            self.selectedCommentID = nil
        }
        if let editingCommentID, idsToRemove.contains(editingCommentID) {
            self.editingCommentID = nil
        }

        if let undoManager = undoManagerProvider?() {
            undoManager.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated {
                    target.restoreCommentsForUndo(pairs)
                }
            }
        }
    }

    // MARK: - Private Helpers

    /// Capture the actual selection once at creation, including separated lines on this page.
    private func liveExcerpt(_ selection: PDFSelection?, on page: PDFPage) -> String? {
        guard let selection else { return nil }
        let lines = selection.selectionsByLine().filter { $0.pages.contains { $0 === page } }
        guard !lines.isEmpty, lines.count <= 32 else { return nil }
        return excerptText(lines.compactMap(\.string))
    }

    /// Reloaded anchors are interpreted one axis-aligned quadrilateral at a time.
    /// Unknown/skewed geometry is omitted rather than quoting the loose union rectangle.
    private func anchoredExcerpt(_ annotation: PDFAnnotation, on page: PDFPage) -> String? {
        let bounds = annotation.bounds
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
              let values = annotation.quadrilateralPoints, !values.isEmpty,
              values.count <= 128, values.count.isMultiple(of: 4) else { return nil }
        // No-selection comments use this reserved location without a text anchor.
        let fallback = defaultCommentRect(on: page)
        if abs(bounds.minX - fallback.minX) < 0.01 && abs(bounds.minY - fallback.minY) < 0.01
            && abs(bounds.width - fallback.width) < 0.01 && abs(bounds.height - fallback.height) < 0.01 {
            return nil
        }
        let points = values.map(\.pointValue)
        let epsilon: CGFloat = 0.01
        let localBounds = CGRect(origin: .zero, size: bounds.size).insetBy(dx: -epsilon, dy: -epsilon)
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && localBounds.contains($0) }) else { return nil }
        var rects: [CGRect] = []
        var lines: [String] = []
        for offset in stride(from: 0, to: points.count, by: 4) {
            let topLeft = points[offset], topRight = points[offset + 1]
            let bottomLeft = points[offset + 2], bottomRight = points[offset + 3]
            guard abs(topLeft.y - topRight.y) < epsilon, abs(bottomLeft.y - bottomRight.y) < epsilon,
                  abs(topLeft.x - bottomLeft.x) < epsilon, abs(topRight.x - bottomRight.x) < epsilon,
                  topRight.x > topLeft.x, topLeft.y > bottomLeft.y else { return nil }
            let rect = CGRect(x: bounds.minX + topLeft.x, y: bounds.minY + bottomLeft.y,
                              width: topRight.x - topLeft.x, height: topLeft.y - bottomLeft.y)
            guard page.bounds(for: .mediaBox).insetBy(dx: -epsilon, dy: -epsilon).contains(rect),
                  !rects.contains(where: { $0.intersects(rect) }),
                  let selection = page.selection(for: rect), selection.selectionsByLine().count == 1,
                  rect.insetBy(dx: -1, dy: -1).contains(selection.bounds(for: page)),
                  let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            rects.append(rect)
            lines.append(text)
        }
        return excerptText(lines)
    }

    private func excerptText(_ lines: [String]) -> String? {
        let text = lines.prefix(32).map { String($0.prefix(1024)).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        return text.isEmpty ? nil : String(text.prefix(1024))
    }

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
        highlight.color = SettingsManager.shared.commentPresets.first?.color ?? DesignTokens.commentHighlightColor
        highlight.quadrilateralPoints = buildQuadrilateralPoints(from: rects, relativeTo: union)
        return highlight
    }

    private func isCommentHighlight(_ annotation: PDFAnnotation) -> Bool {
        // No slash: PDFKit's `type` drops the one in `PDFAnnotationSubtype.highlight.rawValue` ("/Highlight").
        guard annotation.type == "Highlight" else { return false }

        // Primary: userName is a valid UUID (created by PageFlow)
        if let userName = annotation.userName, UUID(uuidString: userName) != nil {
            return true
        }

        // Secondary: annotation has PageFlowType key
        return annotation.value(forAnnotationKey: Self.pageFlowTypeKey) as? String == Self.pageFlowCommentValue
    }

    private func removeOrphanedComment(at index: Int, id: UUID) {
        comments.remove(at: index)
        highlights.removeValue(forKey: id)
        excerptCache.removeValue(forKey: id)

        if selectedCommentID == id {
            selectedCommentID = nil
        }
        if editingCommentID == id {
            editingCommentID = nil
        }
    }

    // MARK: - Undo/Redo

    private func registerUndoAdd(_ comment: CommentModel, highlight: PDFAnnotation, page: PDFPage) {
        guard let undoManager = getUndoManager(for: "Add Comment") else { return }

        undoManager.registerUndo(withTarget: self) { [highlight, page] target in
            MainActor.assumeIsolated {
                target.undoAdd(comment, highlight: highlight, page: page)
            }
        }
        undoManager.setActionName("Add Comment")
    }

    private func undoAdd(_ comment: CommentModel, highlight: PDFAnnotation, page: PDFPage) {
        // Capture current text before removing (user may have edited since creation)
        let currentText = comments.first { $0.id == comment.id }?.text ?? comment.text
        let updatedComment = CommentModel(
            id: comment.id,
            text: currentText,
            pageIndex: comment.pageIndex,
            bounds: comment.bounds
        )

        page.removeAnnotation(highlight)
        comments.removeAll { $0.id == comment.id }
        highlights.removeValue(forKey: comment.id)
        excerptCache.removeValue(forKey: comment.id)
        if selectedCommentID == comment.id { selectedCommentID = nil }
        if editingCommentID == comment.id { editingCommentID = nil }
        pdfManager?.noteVisibleEdit(on: page)

        guard let undoManager = getUndoManager(for: "Add Comment") else { return }
        undoManager.registerUndo(withTarget: self) { [highlight, page] target in
            MainActor.assumeIsolated {
                target.redoAdd(updatedComment, highlight: highlight, page: page)
            }
        }
        undoManager.setActionName("Add Comment")
    }

    private func redoAdd(_ comment: CommentModel, highlight: PDFAnnotation, page: PDFPage) {
        page.addAnnotation(highlight)
        highlight.contents = comment.text
        comments.append(comment)
        highlights[comment.id] = highlight
        pdfManager?.noteVisibleEdit(on: page)

        registerUndoAdd(comment, highlight: highlight, page: page)
    }

    private func registerUndoDelete(_ comment: CommentModel, highlight: PDFAnnotation, page: PDFPage) {
        guard let undoManager = getUndoManager(for: "Delete Comment") else { return }

        undoManager.registerUndo(withTarget: self) { [highlight, page] target in
            MainActor.assumeIsolated {
                target.undoDelete(comment, highlight: highlight, page: page)
            }
        }
        undoManager.setActionName("Delete Comment")
    }

    private func undoDelete(_ comment: CommentModel, highlight: PDFAnnotation, page: PDFPage) {
        page.addAnnotation(highlight)
        highlight.contents = comment.text
        comments.append(comment)
        highlights[comment.id] = highlight
        pdfManager?.noteVisibleEdit(on: page)

        guard let undoManager = getUndoManager(for: "Delete Comment") else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.deleteComment(comment.id)
            }
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
