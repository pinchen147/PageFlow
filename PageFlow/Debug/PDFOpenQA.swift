#if DEBUG
import AppKit
import PDFKit
import Darwin

@MainActor
enum PDFOpenQA {
    static func run() async {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PAGEFLOW_QA_PDF_URL"], let output = env["PAGEFLOW_QA_OUTPUT_DIR"] else { exit(2) }
        let url = URL(fileURLWithPath: path).pageFlowCanonicalDocumentURL
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        let mode = env["PAGEFLOW_QA_PDF_MODE"] ?? "warm"
        var checks: [String: Bool] = [:]
        var deliveryAccepted = mode == "cold"
        var deliveryError: String?
        let deadline = Date().addingTimeInterval(12)
        while WindowRegistry.shared.anyTabManager() == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        if mode == "warm" {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = !QAPresentation.runsInBackground
            NSWorkspace.shared.open([url], withApplicationAt: Bundle.main.bundleURL, configuration: configuration) { app, error in
                Task { @MainActor in
                    deliveryAccepted = error == nil && app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                    deliveryError = error?.localizedDescription
                }
            }
        }
        var rendered: PDFView?
        while Date() < deadline {
            if let manager = WindowRegistry.shared.anyTabManager(), let pdf = manager.activePDFManager,
               pdf.documentURL?.pageFlowCanonicalDocumentURL == url, let document = pdf.document,
               let window = WindowRegistry.shared.window(for: manager), window.isVisible,
               let content = window.contentView, let view = findPDF(in: content, document: document),
               view.currentPage != nil, view.scaleFactor > 0, !view.isHiddenOrHasHiddenAncestor,
               !view.visibleRect.isEmpty, deliveryAccepted {
                checks = ["macOSDeliveryAccepted": true, "canonicalDocumentLoaded": pdf.hasDocument,
                          "singlePageLoaded": document.pageCount == 1, "visibleWindow": window.isVisible,
                          "livePDFViewOwnsDocument": view.document === document,
                          "PDFKitHasCurrentPage": view.currentPage != nil]
                rendered = view
                break
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        if checks.isEmpty { checks["visiblePDFLoadedBeforeDeadline"] = false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        checks["currentPageRenders"] = false
        checks["pageIntersectsVisibleView"] = false
        if let view = rendered, let page = view.currentPage {
            try? await Task.sleep(for: .milliseconds(350))
            view.layoutSubtreeIfNeeded()
            let rect = NSIntersectionRect(view.convert(page.bounds(for: .mediaBox), from: page), view.visibleRect)
            checks["pageIntersectsVisibleView"] = !rect.isEmpty
            // PDFKit cached-display snapshots omit compositor page content. Render
            // the live view's current page separately; this is not a window screenshot.
            let preview = page.thumbnail(of: NSSize(width: 480, height: 480), for: .mediaBox)
            if let tiff = preview.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let data = bitmap.representation(using: .png, properties: [:]) {
                var darkest = 1.0
                var lightest = 0.0
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
                    for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                        let luminance = Double((color.redComponent + color.greenComponent + color.blueComponent) / 3)
                        darkest = min(darkest, luminance)
                        lightest = max(lightest, luminance)
                    }
                }
                do {
                    try data.write(to: directory.appendingPathComponent("current-page-render.png"))
                    checks["currentPageRenders"] = lightest - darkest > 0.2
                } catch { deliveryError = error.localizedDescription }
            }
        }
        let passed = !checks.isEmpty && checks.values.allSatisfy { $0 }
        let manager = WindowRegistry.shared.anyTabManager()
        let diagnostics: [String: Any] = [
            "registeredManager": manager != nil,
            "activeDocument": manager?.activePDFManager?.documentURL?.path ?? "",
            "hasPDF": manager?.activePDFManager?.hasDocument ?? false,
            "pendingURLs": AppDelegate.shared?.pendingURLs.map(\.path) ?? [],
            "windows": NSApp.windows.map { window in
                ["visible": window.isVisible, "title": window.title,
                 "views": window.contentView.map(describe) ?? []] as [String: Any]
            }
        ]
        let report: [String: Any] = ["diagnostics": diagnostics, "mode": mode, "passed": passed, "checks": checks,
            "document": url.path, "bundleID": Bundle.main.bundleIdentifier ?? "", "deliveryError": deliveryError ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("pdf-open.json"), options: .atomic)
        }
        exit(passed ? 0 : 1)
    }

    private static func describe(_ view: NSView) -> [String] {
        var result: [String] = []
        if let pdf = view as? PDFView {
            result.append("PDFView hidden=\(pdf.isHiddenOrHasHiddenAncestor) page=\(pdf.currentPage != nil) scale=\(pdf.scaleFactor) rect=\(pdf.visibleRect) document=\(pdf.document?.documentURL?.path ?? "")")
        }
        return result + view.subviews.flatMap(describe)
    }

    private static func findPDF(in view: NSView, document: PDFDocument) -> PDFView? {
        if let pdf = view as? PDFView, pdf.document === document { return pdf }
        for child in view.subviews { if let found = findPDF(in: child, document: document) { return found } }
        return nil
    }
}
#endif
