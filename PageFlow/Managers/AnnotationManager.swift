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

    // MARK: - Document Changes

    /// Clears the stale annotation selection when the loaded document changes.
    /// PDFKit owns annotation storage (page.annotations / page.annotation(at:));
    /// the selection is the only per-document state this manager keeps.
    func resetSelection() {
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
        guard let manager = pdfManager, manager.permissions.annotate, let document = manager.document,
              let (selectionOptional, _) = selectionProvider?(),
              let selection = selectionOptional?.copy() as? PDFSelection else { return }
        let pages = selection.pages
        guard !pages.isEmpty,
              pages.allSatisfy({ $0.document === document && document.index(for: $0) != NSNotFound }) else { return }

        // Prepare every page before mutating any of them: stale selections or unusable
        // geometry cannot leave a partially applied cross-page command.
        var rectsByPage: [ObjectIdentifier: [CGRect]] = [:]
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let rect = line.bounds(for: page)
                guard !rect.isNull, !rect.isEmpty else { continue }
                rectsByPage[ObjectIdentifier(page), default: []].append(rect)
            }
        }
        var additions: [(page: PDFPage, annotation: PDFAnnotation)] = []
        for page in pages {
            let rects = rectsByPage[ObjectIdentifier(page)] ?? []
            guard let first = rects.first else { continue }
            let bounds = rects.dropFirst().reduce(first) { $0.union($1) }
            guard rects.allSatisfy(Self.isFinite), Self.isFinite(bounds) else { return }

            let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
            annotation.markupType = markupType
            annotation.color = color
            annotation.quadrilateralPoints = buildQuadrilateralPoints(from: rects, relativeTo: bounds)
            additions.append((page, annotation))
        }
        guard !additions.isEmpty else { return }

        // An explicit group is also needed when the host disables event grouping.
        // Nested groups preserve a caller's larger operation without closing it.
        let undoManager = getUndoManager(for: actionName)
        undoManager?.beginUndoGrouping()
        for addition in additions {
            addition.page.addAnnotation(addition.annotation)
            registerUndoAdd(addition.annotation, on: addition.page, actionName: actionName)
            pdfManager?.noteVisibleEdit(on: addition.page)
        }
        undoManager?.setActionName(actionName)
        undoManager?.endUndoGrouping()
        selectedAnnotation = additions.last?.annotation
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
    }

    func removeSelectedAnnotation() {
        guard let annotation = selectedAnnotation,
              let page = annotation.page else {
            return
        }

        remove(annotation, from: page, actionName: "Remove Annotation")
    }

    func removeAnnotation(_ annotation: PDFAnnotation) {
        guard let page = annotation.page else { return }

        remove(annotation, from: page, actionName: "Remove Annotation")
    }

    func updateSelectedAnnotationColor(_ color: NSColor) {
        guard pdfManager?.permissions.annotate == true, let annotation = selectedAnnotation else { return }
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
        guard pdfManager?.permissions.annotate == true else { return }
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
                target.remove(annotation, from: page, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
        #if DEBUG
        Swift.print("[AnnotationManager] Registered undo '\(actionName)' on \(ObjectIdentifier(undoManager)), canUndo=\(undoManager.canUndo)")
        #endif
    }

    private func remove(_ annotation: PDFAnnotation, from page: PDFPage, actionName: String) {
        guard pdfManager?.permissions.annotate == true else { return }
        page.removeAnnotation(annotation)
        if selectedAnnotation === annotation { selectedAnnotation = nil }
        pdfManager?.noteVisibleEdit(on: page)

        if let undoManager = getUndoManager(for: actionName) {
            undoManager.registerUndo(withTarget: self) { [weak page] target in
                MainActor.assumeIsolated {
                    guard let page = page else { return }
                    target.reAdd(annotation, to: page, actionName: actionName)
                }
            }
            undoManager.setActionName(actionName)
        }
    }

    private func reAdd(_ annotation: PDFAnnotation, to page: PDFPage, actionName: String) {
        guard pdfManager?.permissions.annotate == true else { return }
        page.addAnnotation(annotation)
        pdfManager?.noteVisibleEdit(on: page)
        registerUndoAdd(annotation, on: page, actionName: actionName)
    }
}
