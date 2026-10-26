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

    present(printOperation)
}

/// Presents the system print panel for a STYLED Markdown document (S9). The full
/// document is laid out on the printable page width by a fresh view built THROUGH
/// the engine (`makePrintView`) — it carries the editor's custom layout-fragment
/// delegate, so math (`$…$` / `$$…$$`), narrow tables, and code-block backgrounds
/// print exactly as on screen. (A stock `NSTextView` draws those `.clear`-foreground
/// custom-attribute glyphs blank.) `makePrintView` is passed the printable content
/// width and returns the configured view, or `nil` if no editor is mounted.
@MainActor
func runMarkdownPrintPanel(jobTitle: String, makePrintView: (_ pageWidth: CGFloat) -> NSView?) {
    // A COPY so the shared PDF print path's use of `NSPrintInfo.shared` is untouched.
    let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
    printInfo.horizontalPagination = .fit
    printInfo.verticalPagination = .automatic
    printInfo.isHorizontallyCentered = false

    let contentWidth = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
    let contentHeight = printInfo.paperSize.height - printInfo.topMargin - printInfo.bottomMargin
    guard contentWidth > 0, contentHeight > 0 else { return }

    guard let printView = makePrintView(contentWidth) else { return }

    let printOperation = NSPrintOperation(view: printView, printInfo: printInfo)
    printOperation.jobTitle = jobTitle
    present(printOperation)
}

/// The modal tail shared by both print paths: show the panel + progress, sheet onto
/// the key window when there is one, else run app-modal (an edge case — never sheet
/// onto a throwaway NSWindow that never closes).
@MainActor
private func present(_ printOperation: NSPrintOperation) {
    printOperation.showsPrintPanel = true
    printOperation.showsProgressPanel = true
    if let window = NSApp.keyWindow {
        printOperation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    } else {
        printOperation.run()
    }
}
