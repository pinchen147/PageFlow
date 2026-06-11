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
import os.log

@Observable
@MainActor
final class AnnotationManager {
    private let logger = Logger(subsystem: "com.pageflow", category: "AnnotationManager")

    deinit {
        #if DEBUG
        Swift.print("[deinit] AnnotationManager")
        #endif
    }

    // MARK: - State

    var selectedAnnotation: PDFAnnotation?

    // Track if user explicitly selected a color (nil = use first preset)
    private var _underlineColor: NSColor?
    private var _highlightColor: NSColor?

    var underlineColor: NSColor {
        get { _underlineColor ?? SettingsManager.shared.underlinePresets.first?.color ?? .black }
        set { _underlineColor = newValue }
    }

    var highlightColor: NSColor {
        get { _highlightColor ?? SettingsManager.shared.highlightPresets.first?.color ?? .yellow }
        set { _highlightColor = newValue }
    }

    private weak var pdfManager: PDFManager?
    private var selectionProvider: (() -> (PDFSelection?, PDFPage?))?
    private var undoManagerProvider: (() -> UndoManager?)?

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
        #if DEBUG
        Swift.print("[AnnotationManager] getUndoManager for '\(action)': \(ObjectIdentifier(undoManager)), canUndo=\(undoManager.canUndo)")
        #endif
        return undoManager
    }

    // MARK: - Document Loading

    /// Prepares the manager for a newly loaded document.
    /// Clears stale selection state so existing annotations can be selected fresh.
    /// - Parameter document: The PDFDocument that was loaded
    func loadAnnotations(from document: PDFDocument) {
        // Clear any stale selection from previous document
        selectedAnnotation = nil

        // Note: PDFKit automatically manages annotations on each PDFPage.
        // We don't need to store them separately - they're already accessible
        // via page.annotations and clickable via page.annotation(at:).
        // This method ensures clean state when switching documents.
    }

    /// Clears all annotation state when document is closed.
    func clearAnnotations() {
        selectedAnnotation = nil
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
        guard union.width > 0, union.height > 0 else { return }

        let annotation = PDFAnnotation(bounds: union, forType: subtype, withProperties: nil)
        annotation.markupType = markupType
        annotation.color = color
        annotation.quadrilateralPoints = buildQuadrilateralPoints(from: lineRects, relativeTo: union)

        page.addAnnotation(annotation)
        registerUndoAdd(annotation, on: page, actionName: actionName)

        selectedAnnotation = annotation
        pdfManager?.noteVisibleEdit(on: page)
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
        guard previousColor != color else { return }

        annotation.color = color
        if annotation.markupType == .underline {
            underlineColor = color
        } else if annotation.markupType == .highlight {
            highlightColor = color
        }
        pdfManager?.noteVisibleEdit(on: annotation.page)

        if let undoManager = getUndoManager(for: "Change Annotation Color") {
            undoManager.registerUndo(withTarget: self) { [weak annotation] target in
                MainActor.assumeIsolated {
                    guard let annotation = annotation else { return }
                    target.restoreAnnotationColor(annotation, to: previousColor)
                }
            }
            undoManager.setActionName("Change Annotation Color")
        }
    }

    private func restoreAnnotationColor(_ annotation: PDFAnnotation, to color: NSColor) {
        let currentColor = annotation.color
        annotation.color = color
        pdfManager?.noteVisibleEdit(on: annotation.page)

        if let undoManager = getUndoManager(for: "Change Annotation Color") {
            undoManager.registerUndo(withTarget: self) { [weak annotation] target in
                MainActor.assumeIsolated {
                    guard let annotation = annotation else { return }
                    target.restoreAnnotationColor(annotation, to: currentColor)
                }
            }
            undoManager.setActionName("Change Annotation Color")
        }
    }

    // MARK: - Helpers

    private func registerUndoAdd(_ annotation: PDFAnnotation, on page: PDFPage, actionName: String) {
        guard let undoManager = getUndoManager(for: actionName) else { return }

        undoManager.registerUndo(withTarget: self) { [weak page] target in
            MainActor.assumeIsolated {
                guard let page = page else { return }
                target.remove(annotation, from: page, registerRedo: true)
            }
        }
        undoManager.setActionName(actionName)
        #if DEBUG
        Swift.print("[AnnotationManager] Registered undo '\(actionName)' on \(ObjectIdentifier(undoManager)), canUndo=\(undoManager.canUndo)")
        #endif
    }

    private func remove(_ annotation: PDFAnnotation, from page: PDFPage, registerRedo: Bool) {
        page.removeAnnotation(annotation)
        pdfManager?.pageVersion += 1
        pdfManager?.markThumbnailDirty(for: page)

        if registerRedo, let undoManager = getUndoManager(for: "Remove Annotation") {
            undoManager.registerUndo(withTarget: self) { [weak page] target in
                MainActor.assumeIsolated {
                    guard let page = page else { return }
                    target.reAdd(annotation, to: page)
                }
            }
            undoManager.setActionName("Remove Annotation")
        }
    }

    private func reAdd(_ annotation: PDFAnnotation, to page: PDFPage) {
        page.addAnnotation(annotation)
        pdfManager?.noteVisibleEdit(on: page)

        // Register undo to enable infinite undo/redo cycle
        if let undoManager = getUndoManager(for: "Add Annotation") {
            undoManager.registerUndo(withTarget: self) { [weak page] target in
                MainActor.assumeIsolated {
                    guard let page = page else { return }
                    target.remove(annotation, from: page, registerRedo: true)
                }
            }
            undoManager.setActionName("Add Annotation")
        }
    }
}
