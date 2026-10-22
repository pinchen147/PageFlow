//
//  PDFLoadFirewallCharacterizationTests.swift
//  PageFlowTests
//
//  CHARACTERIZATION — the PDF-path byte-safety firewall (CEO/Eng review E1).
//
//  PageFlow is about to grow a Markdown editor as a second TabContent type
//  (docs/md docs/00-15, ADRs 0006-0012). The load-bearing safety guarantee of
//  that whole plan is: a `.md` file is NEVER loaded or saved through the PDF
//  path, so it can never be overwritten with PDF bytes (`document.dataRepresentation()`).
//
//  That guarantee rests on ONE guard: `PDFManager.loadDocument` is EXTENSION-gated
//  to `.pdf` (PDFManager.swift:245 — `guard url.pathExtension.lowercased() == "pdf"`).
//  These tests pin its CURRENT behavior so the upcoming `TabContent` refactor
//  (Slice 0) cannot silently weaken it. They are expected to pass on the current
//  code and to keep passing through the refactor. If one ever fails, the firewall
//  changed — stop and re-verify the markdown-never-reaches-PDF-save invariant.
//

import Foundation
import PDFKit
import Testing
@testable import PageFlow

@MainActor
struct PDFLoadFirewallCharacterizationTests {

    // A real, headless, selectable-text PDF's bytes (PDFTestFixtures.makeTextDocument).
    private func realPDFData() throws -> Data {
        let doc = try #require(makeTextDocument(text: "characterization fixture"))
        return try #require(doc.dataRepresentation())
    }

    // Write `bytes` to a temp file with the given extension; caller removes it.
    private func tempURL(ext: String, bytes: Data) throws -> URL {
        var url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pf-firewall-\(UUID().uuidString)")
        if !ext.isEmpty { url.appendPathExtension(ext) }
        try bytes.write(to: url)
        return url
    }

    private func isFailed(_ r: DocumentLoadResult) -> Bool { if case .failed = r { return true }; return false }
    private func isSuccess(_ r: DocumentLoadResult) -> Bool { if case .success = r { return true }; return false }

    /// THE firewall: a non-`.pdf` extension is rejected even when the file
    /// contains valid PDF bytes. This proves the guard is EXTENSION-based, which
    /// is exactly why a `.md` (whatever its contents) never loads through PDFManager.
    @Test
    func rejectsNonPdfExtensionsEvenWithValidPdfBytes() throws {
        let pdfBytes = try realPDFData()
        for ext in ["md", "markdown", "txt", "rtf", "mdown", ""] {
            let url = try tempURL(ext: ext, bytes: pdfBytes)
            defer { try? FileManager.default.removeItem(at: url) }

            let manager = PDFManager()
            let result = manager.loadDocument(from: url)

            #expect(isFailed(result),
                    "extension '.\(ext)' must be rejected by the PDF firewall even with valid PDF bytes")
            #expect(manager.hasDocument == false,
                    "a rejected load must not leave a document on the manager (no partial mutation)")
        }
    }

    /// The positive side: a real `.pdf` loads, and the extension check is
    /// case-insensitive (`.lowercased()`), so `.PDF` works too.
    @Test
    func acceptsPdfExtensionCaseInsensitively() throws {
        let pdfBytes = try realPDFData()
        for ext in ["pdf", "PDF", "Pdf"] {
            let url = try tempURL(ext: ext, bytes: pdfBytes)
            defer { try? FileManager.default.removeItem(at: url) }

            let manager = PDFManager()
            let result = manager.loadDocument(from: url)

            #expect(isSuccess(result), "extension '.\(ext)' should load through PDFManager")
            #expect(manager.hasDocument, "a successful load must surface a document")
        }
    }

    /// Belt-and-suspenders: the exact filename a markdown editor would hand over
    /// (`notes.md`) is never accepted by the PDF path, even if it somehow holds
    /// PDF bytes. This is the statement the markdown-save-safety guarantee makes.
    @Test
    func markdownFileIsNeverLoadedThroughThePdfPath() throws {
        let pdfBytes = try realPDFData()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pf-md-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mdURL = dir.appendingPathComponent("notes.md")
        try pdfBytes.write(to: mdURL)

        #expect(isFailed(PDFManager().loadDocument(from: mdURL)),
                "notes.md must never load through PDFManager — the markdown-save-safety firewall")
    }
}
