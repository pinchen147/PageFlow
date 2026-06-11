//
//  PrintPanel.swift
//  PageFlow
//
//  Runs the modal AppKit print panel for a PDF document. UI-layer helper so
//  PDFManager stays out of print orchestration.
//

import AppKit
import PDFKit

/// Presents the system print panel for `document`, scaled to fit the page.
@MainActor
func runPrintPanel(for document: PDFDocument) {
    let printInfo = NSPrintInfo.shared
    printInfo.horizontalPagination = .fit
    printInfo.verticalPagination = .automatic
    printInfo.isHorizontallyCentered = true
    printInfo.isVerticallyCentered = false

    guard let printOperation = document.printOperation(
        for: printInfo,
        scalingMode: .pageScaleToFit,
        autoRotate: true
    ) else {
        return
    }

    printOperation.showsPrintPanel = true
    printOperation.showsProgressPanel = true
    if let window = NSApp.keyWindow {
        printOperation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    } else {
        // No key window (edge case): run app-modal instead of sheeting onto a
        // throwaway NSWindow that never closes.
        printOperation.run()
    }
}
