//
//  MarkdownTabRoutingTests.swift
//  PageFlowTests
//
//  S5b routing: a `.md`/`.markdown` URL opens as a first-class Markdown tab —
//  routed by `TabContent`, loaded through `MarkdownDocumentManager` (never the
//  PDF firewall) — while a `.pdf` URL still produces `.pdf` content. Headless:
//  drives `TabManager.openDocument` directly, with no window (the precedent set
//  by DocumentStateTests / MultiDropTests).
//

import Foundation
import PDFKit
import Testing
@testable import PageFlow

@MainActor
struct MarkdownTabRoutingTests {

    // MARK: - Temp-file helpers

    /// A unique temp `.md` seeded with `text`; removed when `body` returns.
    private func withTempMarkdown(
        ext: String = "md", text: String, _ body: (URL) throws -> Void
    ) rethrows {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pf-md-route-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        try? Data(text.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    /// A unique temp `.pdf` holding a real, loadable PDF; removed when `body` returns.
    private func withTempPDF(_ body: (URL) throws -> Void) throws {
        let doc = try #require(makeTextDocument(text: "routing fixture"))
        let data = try #require(doc.dataRepresentation())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pf-pdf-route-\(UUID().uuidString)")
            .appendingPathExtension("pdf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    // MARK: - Markdown routing

    /// Opening a `.md` URL routes to `.markdown` content and loads the file's text
    /// through the text document manager — the whole point of S5b.
    @Test
    func openingMarkdownURLCreatesMarkdownSessionWithItsText() throws {
        try withTempMarkdown(text: "# Hello\n\nLiteral **markdown**.\n") { url in
            let manager = TabManager()
            manager.openDocument(url: url, isSecurityScoped: false)
            manager.closeFilePicker()

            let session = try #require(manager.activeSession)
            // Content is markdown — and is NOT pdf (the firewall side of the contract).
            let markdown = try #require(session.content.markdown)
            #expect(session.content.pdf == nil)

            // The on-disk text reached the document manager via MarkdownDocumentManager.
            #expect(markdown.documentManager.text == "# Hello\n\nLiteral **markdown**.\n")
            #expect(!markdown.documentManager.isDirty)

            // The reused placeholder tab now carries the file's identity + title.
            #expect(manager.activeTab?.documentURL?.pageFlowCanonicalDocumentURL
                    == url.pageFlowCanonicalDocumentURL)
            #expect(manager.activeTab?.title == url.deletingPathExtension().lastPathComponent)
        }
    }

    /// `.markdown` is accepted alongside `.md`.
    @Test
    func openingDotMarkdownExtensionAlsoRoutesToMarkdown() throws {
        try withTempMarkdown(ext: "markdown", text: "body\n") { url in
            let manager = TabManager()
            manager.openDocument(url: url, isSecurityScoped: false)
            manager.closeFilePicker()

            #expect(manager.activeSession?.content.markdown != nil)
            #expect(manager.activeSession?.content.markdown?.documentManager.text == "body\n")
        }
    }

    /// Re-opening the same markdown file focuses the existing tab instead of
    /// creating a second one — the canonical-URL dedup, unchanged for markdown.
    @Test
    func reopeningTheSameMarkdownFileFocusesTheExistingTab() throws {
        try withTempMarkdown(text: "# Doc\n") { url in
            let manager = TabManager()
            manager.openDocument(url: url, isSecurityScoped: false)
            manager.closeFilePicker()
            let markdownTabID = try #require(manager.activeTabID)

            // A second, blank tab becomes active so focus actually has to move back.
            manager.createNewTab()
            manager.closeFilePicker()
            #expect(manager.activeTabID != markdownTabID)
            let tabCountBeforeReopen = manager.tabCount

            // Re-opening the same file selects the original tab — no new tab.
            manager.openDocument(url: url, isSecurityScoped: false)
            #expect(manager.activeTabID == markdownTabID)
            #expect(manager.tabCount == tabCountBeforeReopen)
            #expect(manager.activeSession?.content.markdown != nil)
        }
    }

    // MARK: - PDF routing unchanged

    /// A `.pdf` URL still routes to `.pdf` content and loads through PDFManager —
    /// the PDF path the markdown branch must not perturb.
    @Test
    func openingPDFURLStillCreatesPDFSession() throws {
        try withTempPDF { url in
            let manager = TabManager()
            manager.openDocument(url: url, isSecurityScoped: false)
            manager.closeFilePicker()

            let session = try #require(manager.activeSession)
            #expect(session.content.pdf != nil)
            #expect(session.content.markdown == nil)
            #expect(session.pdfManager?.hasDocument == true)
        }
    }

    // MARK: - Replace-current: atomic, rollback-safe content swap (HIGH-1 / LOW-3)

    /// A non-existent `.md` URL — routed to markdown by extension, its load throws.
    /// Used to drive the rollback paths headlessly (no modal).
    private func missingMarkdownURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pf-md-missing-\(UUID().uuidString)")
            .appendingPathExtension("md")
    }

    /// A markdown open via `replaceCurrent` whose load FAILS must leave the original
    /// PDF tab completely intact — same URL/title, still PDF content — never the
    /// pre-fix corrupt empty markdown tab still advertising the old document.
    @Test
    func failedMarkdownReplaceOverLoadedPDFLeavesOriginalTabIntact() throws {
        try withTempPDF { pdfURL in
            let manager = TabManager()
            manager.openDocument(url: pdfURL, isSecurityScoped: false)
            manager.closeFilePicker()

            let pdfTabID = try #require(manager.activeTabID)
            #expect(manager.activeSession?.pdfManager?.hasDocument == true)

            manager.openDocument(url: missingMarkdownURL(), isSecurityScoped: false, replaceCurrent: true)

            // Same single tab, still the PDF — its identity entirely untouched.
            #expect(manager.tabCount == 1)
            #expect(manager.activeTabID == pdfTabID)
            #expect(manager.activeSession?.content.pdf != nil)
            #expect(manager.activeSession?.content.markdown == nil)
            #expect(manager.activeSession?.pdfManager?.hasDocument == true)
            #expect(manager.activeTab?.documentURL?.pageFlowCanonicalDocumentURL
                    == pdfURL.pageFlowCanonicalDocumentURL)
            #expect(manager.activeTab?.title == pdfURL.deletingPathExtension().lastPathComponent)
        }
    }

    /// A failed markdown load into a documentless placeholder leaves no corrupt or
    /// stale tab — the placeholder stays an empty PDF tab, never a half-open markdown.
    @Test
    func failedMarkdownLoadIntoPlaceholderLeavesNoStaleTab() throws {
        let manager = TabManager()
        let placeholderID = try #require(manager.activeTabID)

        manager.openDocument(url: missingMarkdownURL(), isSecurityScoped: false)
        manager.closeFilePicker()

        #expect(manager.tabCount == 1)
        #expect(manager.activeTabID == placeholderID)
        // Still the empty PDF placeholder — never re-homed to a half-open markdown.
        #expect(manager.activeSession?.content.pdf != nil)
        #expect(manager.activeSession?.content.markdown == nil)
        #expect(manager.activeSession?.pdfManager?.hasDocument == false)
        #expect(manager.activeTab?.documentURL == nil)
        #expect(manager.activeTab?.hasDocument == false)
    }

    /// `replaceCurrent` over a CLEAN PDF with a markdown file replaces the content
    /// in place — same tab, now markdown, with the file's text loaded. The clean
    /// PDF means the dirty gate passes without a modal (headless-safe).
    @Test
    func markdownReplaceOverCleanPDFReplacesInPlace() throws {
        try withTempPDF { pdfURL in
            try withTempMarkdown(text: "# Replaced\n\nNow **markdown**.\n") { mdURL in
                let manager = TabManager()
                manager.openDocument(url: pdfURL, isSecurityScoped: false)
                manager.closeFilePicker()
                let tabID = try #require(manager.activeTabID)
                #expect(manager.activeSession?.pdfManager?.hasDocument == true)
                #expect(manager.activeSession?.pdfManager?.isDirty == false)

                manager.openDocument(url: mdURL, isSecurityScoped: false, replaceCurrent: true)

                // Same tab, replaced in place with markdown content + the file's text.
                #expect(manager.tabCount == 1)
                #expect(manager.activeTabID == tabID)
                let markdown = try #require(manager.activeSession?.content.markdown)
                #expect(manager.activeSession?.content.pdf == nil)
                #expect(markdown.documentManager.text == "# Replaced\n\nNow **markdown**.\n")
                #expect(manager.activeTab?.documentURL?.pageFlowCanonicalDocumentURL
                        == mdURL.pageFlowCanonicalDocumentURL)
                #expect(manager.activeTab?.title == mdURL.deletingPathExtension().lastPathComponent)
            }
        }
    }
}
