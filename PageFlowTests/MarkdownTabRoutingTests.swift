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
import AppKit
import PDFKit
import Testing
@testable import PageFlow

@MainActor
struct MarkdownTabRoutingTests {

    // MARK: - Temp-file helpers

    /// A unique temp `.md` seeded with `text`; removed when `body` returns.
    private func withTempMarkdown(
        ext: String = "md", text: String, _ body: (URL) async throws -> Void
    ) async rethrows {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pf-md-route-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        try? Data(text.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try await body(url)
    }

    /// A unique temp `.pdf` holding a real, loadable PDF; removed when `body` returns.
    private func withTempPDF(_ body: (URL) async throws -> Void) async throws {
        let doc = try #require(makeTextDocument(text: "routing fixture"))
        let data = try #require(doc.dataRepresentation())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pf-pdf-route-\(UUID().uuidString)")
            .appendingPathExtension("pdf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try await body(url)
    }

    /// File opening must return to the main actor before installing the note.
    /// Closing that slot before delivery must revoke the in-flight open.
    @Test
    func markdownOpenYieldsAndCloseRevokesDelivery() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pf-pending-open-\(UUID().uuidString).md")
        try Data("# Pending\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = TabManager()
        let original = try #require(manager.activeSession)
        let opening = manager.openDocument(url: url, isSecurityScoped: false, bringsToFront: false)
        #expect(manager.activeSession === original)
        manager.closeTab(original.id)
        await opening?.value
        #expect(manager.tabID(for: url) == nil)
        #expect(manager.sessions[original.id] == nil)
    }

    // MARK: - Markdown routing

    @Test(arguments: ["duplicate", "move", "move-unregistered", "cancel", "supersede", "new-draft", "restore-order"])
    func pendingOpenPreservesOwnershipAndNavigation(action: String) async throws {
        try await withTempMarkdown(text: "# First\n") { first in
            try await withTempMarkdown(text: "# Second\n") { second in
                let source = TabManager()
                let destination = TabManager(createInitialTab: false)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                      styleMask: [.titled], backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                if action != "move-unregistered" { WindowRegistry.shared.register(destination, window: window) }
                defer {
                    WindowRegistry.shared.unregister(destination)
                    for owner in [source, destination] { for session in owner.sessions.values { session.cleanup() } }
                    window.close()
                }
                let opening = source.openDocument(url: first, isSecurityScoped: false, bringsToFront: false)
                let id = try #require(source.activeTabID)
                let request = try #require(source.sessions[id]?.pendingMarkdownOpen)
                #expect(!source.hasOnlyPlaceholderTab)
                var latest: Task<Void, Never>?
                switch action {
                case "duplicate":
                    source.openDocument(url: first, isSecurityScoped: false, bringsToFront: false)
                    #expect(source.tabs.count == 1 && source.sessions[id]?.pendingMarkdownOpen === request)
                    source.createNewTab()
                case "move", "move-unregistered":
                    #expect(source.moveTab(id, to: destination, at: 0))
                    destination.newMarkdownDocument()
                case "cancel": opening?.cancel()
                case "supersede":
                    latest = source.openDocument(url: second, isSecurityScoped: false, replaceCurrent: true, bringsToFront: false)
                case "new-draft":
                    source.newMarkdownDocument()
                    source.activeMarkdownContent?.documentManager.text = "Typing while the file opens"
                case "restore-order":
                    latest = source.openDocument(url: second, isSecurityScoped: false, bringsToFront: false)
                    let capture = try #require(source.captureWindowSession())
                    #expect(capture.tabs.map(\.path) == [first.pageFlowCanonicalDocumentURL.path, second.pageFlowCanonicalDocumentURL.path])
                    #expect(capture.activeIndex == 1)
                default: Issue.record("Unknown action")
                }
                let moved = action == "move" || action == "move-unregistered"
                let activeBeforeDelivery = moved ? destination.activeTabID : source.activeTabID
                await opening?.value
                await latest?.value
                if action == "cancel" {
                    #expect(source.sessions[id]?.pendingMarkdownOpen == nil)
                    #expect(source.tabID(for: first) == nil)
                    await source.openDocument(url: first, isSecurityScoped: false, bringsToFront: false)?.value
                }
                let owner = moved ? destination : source
                #expect(owner.activeTabID == activeBeforeDelivery)
                #expect(owner.sessions[id]?.content.markdown?.documentManager.text == (action == "supersede" ? "# Second\n" : "# First\n"))
                if action == "new-draft" {
                    #expect(source.activeMarkdownContent?.documentManager.text == "Typing while the file opens")
                }
                if moved { #expect(source.sessions[id] == nil) }
                if action == "restore-order" {
                    #expect(source.activeMarkdownContent?.documentManager.text == "# Second\n")
                }
            }
        }
    }

    @Test
    func decliningAnObsoleteLargeNoteWarningKeepsItsPDFReplacement() async throws {
        try await withTempPDF { pdf in
            try await withTempMarkdown(text: String(repeating: "a", count: TabManager.largeNoteWarningBytes + 1)) { note in
                let manager = TabManager()
                defer { for session in manager.sessions.values { session.cleanup() } }
                manager.newMarkdownDocument()
                manager.activeMarkdownContent?.documentManager.text = "Retain this draft"
                let draftID = manager.activeTabID
                var replacementID: UUID?
                manager.largeNoteOpenPrompt = { _, _ in
                    replacementID = manager.activeTabID
                    manager.openDocument(url: pdf, isSecurityScoped: false, replaceCurrent: true, bringsToFront: false)
                    return false
                }
                await manager.openDocument(url: note, isSecurityScoped: false, bringsToFront: false)?.value
                #expect(manager.tabID(for: pdf) == replacementID)
                let replaced = try #require(replacementID)
                let draft = try #require(draftID)
                #expect(manager.sessions[replaced]?.pdfManager?.hasDocument == true)
                #expect(manager.sessions[draft]?.content.markdown?.documentManager.text == "Retain this draft")
            }
        }
    }

    /// Opening a `.md` URL routes to `.markdown` content and loads the file's text
    /// through the text document manager — the whole point of S5b.
    @Test
    func openingMarkdownURLCreatesMarkdownSessionWithItsText() async throws {
        try await withTempMarkdown(text: "# Hello\n\nLiteral **markdown**.\n") { url in
            let manager = TabManager()
            await manager.openDocument(url: url, isSecurityScoped: false)?.value
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
    func openingDotMarkdownExtensionAlsoRoutesToMarkdown() async throws {
        try await withTempMarkdown(ext: "markdown", text: "body\n") { url in
            let manager = TabManager()
            await manager.openDocument(url: url, isSecurityScoped: false)?.value
            manager.closeFilePicker()

            #expect(manager.activeSession?.content.markdown != nil)
            #expect(manager.activeSession?.content.markdown?.documentManager.text == "body\n")
        }
    }

    /// Re-opening the same markdown file focuses the existing tab instead of
    /// creating a second one — the canonical-URL dedup, unchanged for markdown.
    @Test
    func reopeningTheSameMarkdownFileFocusesTheExistingTab() async throws {
        try await withTempMarkdown(text: "# Doc\n") { url in
            let manager = TabManager()
            await manager.openDocument(url: url, isSecurityScoped: false)?.value
            manager.closeFilePicker()
            let markdownTabID = try #require(manager.activeTabID)

            // A second, blank tab becomes active so focus actually has to move back.
            manager.createNewTab()
            manager.closeFilePicker()
            #expect(manager.activeTabID != markdownTabID)
            let tabCountBeforeReopen = manager.tabCount

            // Re-opening the same file selects the original tab — no new tab.
            await manager.openDocument(url: url, isSecurityScoped: false)?.value
            #expect(manager.activeTabID == markdownTabID)
            #expect(manager.tabCount == tabCountBeforeReopen)
            #expect(manager.activeSession?.content.markdown != nil)
        }
    }

    // MARK: - PDF routing unchanged

    /// A `.pdf` URL still routes to `.pdf` content and loads through PDFManager —
    /// the PDF path the markdown branch must not perturb.
    @Test
    func openingPDFURLStillCreatesPDFSession() async throws {
        try await withTempPDF { url in
            let manager = TabManager()
            await manager.openDocument(url: url, isSecurityScoped: false)?.value
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
    func failedMarkdownReplaceOverLoadedPDFLeavesOriginalTabIntact() async throws {
        try await withTempPDF { pdfURL in
            let manager = TabManager()
            await manager.openDocument(url: pdfURL, isSecurityScoped: false)?.value
            manager.closeFilePicker()

            let pdfTabID = try #require(manager.activeTabID)
            #expect(manager.activeSession?.pdfManager?.hasDocument == true)

            await manager.openDocument(url: missingMarkdownURL(), isSecurityScoped: false, replaceCurrent: true)?.value

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
    func failedMarkdownLoadIntoPlaceholderLeavesNoStaleTab() async throws {
        let manager = TabManager()
        let placeholderID = try #require(manager.activeTabID)

        await manager.openDocument(url: missingMarkdownURL(), isSecurityScoped: false)?.value
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
    func markdownReplaceOverCleanPDFReplacesInPlace() async throws {
        try await withTempPDF { pdfURL in
            try await withTempMarkdown(text: "# Replaced\n\nNow **markdown**.\n") { mdURL in
                let manager = TabManager()
                await manager.openDocument(url: pdfURL, isSecurityScoped: false)?.value
                manager.closeFilePicker()
                let tabID = try #require(manager.activeTabID)
                #expect(manager.activeSession?.pdfManager?.hasDocument == true)
                #expect(manager.activeSession?.pdfManager?.isDirty == false)

                await manager.openDocument(url: mdURL, isSecurityScoped: false, replaceCurrent: true)?.value

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
