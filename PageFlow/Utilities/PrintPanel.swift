//
//  PrintPanel.swift
//  PageFlow
//
//  Runs the modal AppKit print panel for a PDF, a note or a book. UI-layer helper
//  so the document managers stay out of print orchestration.
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

/// Print settings for a book: its pages carry their own margins and fill the paper,
/// so the panel's paper and orientation decide the whole layout. The text's size is
/// the reader's, so there is no scale. A COPY, as for Markdown, so the shared
/// settings keep their margins.
@MainActor
func makeEPUBPrintInfo() -> NSPrintInfo {
    let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
    printInfo.leftMargin = 0
    printInfo.rightMargin = 0
    printInfo.topMargin = 0
    printInfo.bottomMargin = 0
    printInfo.horizontalPagination = .clip
    printInfo.verticalPagination = .clip
    printInfo.scalingFactor = 1
    printInfo.isHorizontallyCentered = false
    printInfo.isVerticallyCentered = false
    return printInfo
}

/// The operation for a laid-out book. A view's panel starts with copies and page
/// range alone; a book also takes its paper and orientation from it.
@MainActor
func makeEPUBPrintOperation(view: EPUBPrintView, printInfo: NSPrintInfo, jobTitle: String) -> NSPrintOperation {
    let printOperation = NSPrintOperation(view: view, printInfo: printInfo)
    printOperation.jobTitle = jobTitle
    printOperation.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsPreview])
    return printOperation
}

/// The modal tail shared by every print path: show the panel + progress, sheet onto
/// `parent` (the key window, unless the caller has waited and knows better) when there
/// is one, else run app-modal (an edge case — never sheet onto a throwaway NSWindow
/// that never closes).
@MainActor
func present(_ printOperation: NSPrintOperation, parent: NSWindow? = NSApp.keyWindow) {
    printOperation.showsPrintPanel = true
    printOperation.showsProgressPanel = true
    if let window = parent {
        printOperation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    } else {
        printOperation.run()
    }
}
