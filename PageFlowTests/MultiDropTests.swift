//
//  MultiDropTests.swift
//  PageFlowTests
//
//  Exercises TabManager.openDroppedDocuments — the batch path used when several PDFs
//  are dragged into a window at once. The seam is the manager interface (tabs /
//  documentURLs / failure count); no window or PDFView is needed.
//

import PDFKit
import Testing
@testable import PageFlow

@MainActor
struct MultiDropTests {

    // MARK: - Fixtures

    /// Writes a small valid PDF to a unique temp URL and returns it.
    private func writeBlankPDF(pageCount: Int = 1) -> URL {
        let document = PDFDocument()
        for index in 0..<pageCount {
            let image = NSImage(size: NSSize(width: 32, height: 32))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 32, height: 32).fill()
            image.unlockFocus()
            if let page = PDFPage(image: image) { document.insert(page, at: index) }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        #expect(document.write(to: url))
        return url
    }

    /// Writes a `.pdf` file whose contents are not a PDF, so loading fails.
    private func writeCorruptPDF() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try? Data("not a pdf".utf8).write(to: url)
        return url
    }

    private func cleanup(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Tests

    @Test
    func droppingDistinctPDFsOpensOneTabEachInOrder() {
        let urls = (0..<3).map { _ in writeBlankPDF() }
        defer { cleanup(urls) }

        let tabManager = TabManager()   // starts with one empty tab
        let failed = tabManager.openDroppedDocuments(urls)

        #expect(failed == 0)
        #expect(tabManager.tabs.count == 3)
        #expect(
            tabManager.tabs.map { $0.documentURL?.pageFlowCanonicalDocumentURL }
                == urls.map { $0.pageFlowCanonicalDocumentURL }
        )
        // The last dropped file is active (macOS document convention).
        #expect(tabManager.activeTabID == tabManager.tabs.last?.id)
    }

    @Test
    func firstDroppedFileReusesTheEmptyActiveTab() {
        let url = writeBlankPDF()
        defer { cleanup([url]) }

        let tabManager = TabManager()
        #expect(tabManager.tabs.count == 1)   // initial empty tab

        tabManager.openDroppedDocuments([url])

        #expect(tabManager.tabs.count == 1)   // reused, not a second tab
        #expect(tabManager.tabs.first?.documentURL?.pageFlowCanonicalDocumentURL
                == url.pageFlowCanonicalDocumentURL)
    }

    @Test
    func droppingTheSameFileTwiceDoesNotDuplicate() {
        let url = writeBlankPDF()
        defer { cleanup([url]) }

        let tabManager = TabManager()
        let failed = tabManager.openDroppedDocuments([url, url])

        #expect(failed == 0)
        #expect(tabManager.tabs.count == 1)
    }

    @Test
    func aFailedFileIsCountedAndLeavesNoEmptyTab() {
        let good = writeBlankPDF()
        let bad = writeCorruptPDF()
        defer { cleanup([good, bad]) }

        let tabManager = TabManager()
        let failed = tabManager.openDroppedDocuments([good, bad])

        #expect(failed == 1)
        // Only the good file remains; the failed file left no empty "New Tab".
        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.tabs.first?.documentURL?.pageFlowCanonicalDocumentURL
                == good.pageFlowCanonicalDocumentURL)
    }
}
