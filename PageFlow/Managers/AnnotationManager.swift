//
//  AnnotationManager.swift
//  PageFlow
//
//  Manages creation and editing of markup annotations (highlight/underline).
//

import Foundation
import PDFKit
import AppKit
import Observation

@Observable
@MainActor
final class AnnotationManager {
    // MARK: - State

    var selectedAnnotation: PDFAnnotation?
    var underlineColor: NSColor = DesignTokens.underlineColor
    var highlightColor: NSColor = DesignTokens.highlightYellow

    private weak var pdfManager: PDFManager?
    private var selectionProvider: (() -> (PDFSelection?, PDFPage?))?

    // MARK: - Configuration

    func configure(
        pdfManager: PDFManager,
        selectionProvider: @escaping () -> (PDFSelection?, PDFPage?)
    ) {
        self.pdfManager = pdfManager
        self.selectionProvider = selectionProvider
    }

    // MARK: - Actions

    func highlightSelection(color: NSColor? = nil) {
        addMarkup(
            subtype: .highlight,
            markupType: .highlight,
            color: color ?? highlightColor,
            actionName: "Add Highlight"
        )
    }

    func underlineSelection(color: NSColor? = nil) {
        addMarkup(
            subtype: .underline,
            markupType: .underline,
            color: color ?? underlineColor,
            actionName: "Add Underline"
        )
    }

    private func addMarkup(
        subtype: PDFAnnotationSubtype,
        markupType: PDFMarkupType,
        color: NSColor,
        actionName: String
    ) {
        guard let (selectionOptional, pageOptional) = selectionProvider?(),
              let selectionCopy = selectionOptional?.copy() as? PDFSelection,
              let page = pageOptional else {
            return
        }

        let lineSelections = selectionCopy.selectionsByLine()
        guard !lineSelections.isEmpty else { return }

        let lineRects = lineSelections
            .map { $0.bounds(for: page) }
            .filter { !$0.isNull && !$0.isEmpty }
        guard let firstRect = lineRects.first else { return }
        let union = lineRects.dropFirst().reduce(firstRect) { partial, rect in
            partial.union(rect)
        }

        let annotation = PDFAnnotation(bounds: union, forType: subtype, withProperties: nil)
        annotation.markupType = markupType
        annotation.color = color
        annotation.quadrilateralPoints = buildQuadrilateralPoints(from: lineRects, relativeTo: union)

        page.addAnnotation(annotation)
        registerUndoAdd(annotation, on: page, actionName: actionName)

        selectedAnnotation = annotation
        pdfManager?.isDirty = true
    }

    func removeSelectedAnnotation() {
        guard let annotation = selectedAnnotation,
              let page = annotation.page else {
            return
        }

        remove(annotation, from: page, registerRedo: true)
        selectedAnnotation = nil
        pdfManager?.isDirty = true
    }

    func removeAnnotation(_ annotation: PDFAnnotation) {
        guard let page = annotation.page else { return }

        remove(annotation, from: page, registerRedo: true)
        if selectedAnnotation === annotation {
            selectedAnnotation = nil
        }
        pdfManager?.isDirty = true
    }

    func updateSelectedAnnotationColor(_ color: NSColor) {
        guard let annotation = selectedAnnotation else { return }
        let previousColor = annotation.color

        annotation.color = color
        if annotation.markupType == .underline {
            underlineColor = color
        } else if annotation.markupType == .highlight {
            highlightColor = color
        }
        pdfManager?.isDirty = true

        if let undoManager = NSApp.keyWindow?.undoManager {
            undoManager.registerUndo(withTarget: self) { target in
                target.updateSelectedAnnotationColor(previousColor)
            }
            undoManager.setActionName("Change Annotation Color")
        }
    }

    // MARK: - Helpers

    private func buildQuadrilateralPoints(from rects: [CGRect], relativeTo union: CGRect) -> [NSValue] {
        var quadPoints: [NSValue] = []

        for rect in rects {
            let tl = CGPoint(x: rect.minX - union.minX, y: rect.maxY - union.minY)
            let tr = CGPoint(x: rect.maxX - union.minX, y: rect.maxY - union.minY)
            let bl = CGPoint(x: rect.minX - union.minX, y: rect.minY - union.minY)
            let br = CGPoint(x: rect.maxX - union.minX, y: rect.minY - union.minY)

            quadPoints.append(contentsOf: [
                NSValue(point: tl),
                NSValue(point: tr),
                NSValue(point: bl),
                NSValue(point: br)
            ])
        }

        return quadPoints
    }

    private func registerUndoAdd(_ annotation: PDFAnnotation, on page: PDFPage, actionName: String) {
        guard let undoManager = NSApp.keyWindow?.undoManager else { return }

        undoManager.registerUndo(withTarget: self) { target in
            target.remove(annotation, from: page, registerRedo: true)
        }
        undoManager.setActionName(actionName)
    }

    private func remove(_ annotation: PDFAnnotation, from page: PDFPage, registerRedo: Bool) {
        page.removeAnnotation(annotation)

        if registerRedo, let undoManager = NSApp.keyWindow?.undoManager {
            undoManager.registerUndo(withTarget: self) { target in
                target.reAdd(annotation, to: page)
            }
            undoManager.setActionName("Remove Annotation")
        }
    }

    private func reAdd(_ annotation: PDFAnnotation, to page: PDFPage) {
        page.addAnnotation(annotation)
        pdfManager?.isDirty = true

        // Register undo to enable infinite undo/redo cycle
        if let undoManager = NSApp.keyWindow?.undoManager {
            undoManager.registerUndo(withTarget: self) { target in
                target.remove(annotation, from: page, registerRedo: true)
            }
            undoManager.setActionName("Add Annotation")
        }
    }
}
