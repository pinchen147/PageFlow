//
//  MarkdownLifecycleTests.swift
//  PageFlowTests
//
//  S6 unified lifecycle: the untitled-Markdown document model and the
//  content-aware command predicates. Headless — drives `TabManager`'s public API
//  directly (no window), the precedent set by MarkdownTabRoutingTests. The modal
//  Save / Save-As / quit-NSAlert paths are NOT headlessly testable (they block on
//  NSSavePanel / NSAlert); this covers the dirty/has-content/predicate state logic
//  those modal paths branch on.
//

import Foundation
import PDFKit
import Testing
@testable import PageFlow

@MainActor
struct MarkdownLifecycleTests {

    // MARK: - Temp-file helper (clean loaded PDF fixture)

    /// A unique temp `.pdf` holding a real, loadable PDF; removed when `body` returns.
    private func withTempPDF(_ body: (URL) throws -> Void) throws {
        let doc = try #require(makeTextDocument(text: "lifecycle fixture"))
        let data = try #require(doc.dataRepresentation())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pf-md-life-\(UUID().uuidString)")
            .appendingPathExtension("pdf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    /// A unique temp `.md` seeded with `bytes`; removed when `body` returns.
    private func withTempMarkdown(bytes: Data, _ body: (URL) async throws -> Void) async rethrows {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pf-md-life-\(UUID().uuidString)")
            .appendingPathExtension("md")
        try? bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try await body(url)
    }

    // MARK: - (a) New untitled Markdown document

    /// `newMarkdownDocument()` creates an active, untitled `.markdown` tab that is
    /// clean, holds no content, and may be silently replaced by an open.
    @Test
    func newMarkdownDocumentCreatesACleanUntitledTab() throws {
        let manager = TabManager()
        manager.newMarkdownDocument()

        let session = try #require(manager.activeSession)
        let markdown = try #require(session.content.markdown)
        #expect(session.content.pdf == nil)

        // Seeded with the Obsidian-style starter heading — PRISTINE (not dirty
        // until the user edits) and still freely replaceable.
        #expect(markdown.documentManager.text == "# Untitled\n\n")
        #expect(!markdown.documentManager.isDirty)
        #expect(session.canReplaceWithoutPrompt)

        // Untitled, with no on-disk URL yet.
        #expect(!markdown.documentManager.hasDocumentURL)
        #expect(manager.activeTab?.title == "Untitled")
        #expect(manager.activeTab?.documentURL == nil)
    }

    // MARK: - (b) First edit protects the buffer

    /// Editing the untitled buffer makes it dirty + content-bearing, so it can no
    /// longer be silently clobbered by an open (the protection of ADR-0012 D6).
    @Test
    func editingUntitledMarkdownMakesItDirtyAndProtected() throws {
        let manager = TabManager()
        manager.newMarkdownDocument()

        let session = try #require(manager.activeSession)
        let markdown = try #require(session.content.markdown)

        markdown.documentManager.text = "First keystroke"

        #expect(markdown.documentManager.isDirty)
        #expect(session.hasContent)
        #expect(!session.canReplaceWithoutPrompt)
    }

    // MARK: - (c) Untitled naming collisions

    /// Two new untitled documents never share a title: "Untitled", then "Untitled 2".
    @Test
    func untitledTitlesDisambiguateOnCollision() {
        let manager = TabManager()

        manager.newMarkdownDocument()
        #expect(manager.activeTab?.title == "Untitled")

        manager.newMarkdownDocument()
        #expect(manager.activeTab?.title == "Untitled 2")

        let titles = manager.tabs.map(\.title)
        #expect(titles.contains("Untitled"))
        #expect(titles.contains("Untitled 2"))
    }

    // MARK: - (d) Content-agnostic dirty aggregation

    /// `dirtyDocuments()` includes a dirty Markdown tab and excludes a clean
    /// Markdown tab and a clean (loaded) PDF tab.
    @Test
    func dirtyDocumentsSpansMarkdownAndExcludesCleanContent() throws {
        try withTempPDF { pdfURL in
            let manager = TabManager()
            // Reuse the placeholder for a clean, loaded PDF.
            manager.openDocument(url: pdfURL, isSecurityScoped: false)
            manager.closeFilePicker()
            let pdfTabID = try #require(manager.activeTabID)
            #expect(manager.activeSession?.pdfManager?.hasDocument == true)
            #expect(manager.activeSession?.pdfManager?.isDirty == false)

            // A clean untitled Markdown tab.
            manager.newMarkdownDocument()
            let cleanMarkdownTabID = try #require(manager.activeTabID)

            // A dirty untitled Markdown tab (edited).
            manager.newMarkdownDocument()
            let dirtyMarkdownTabID = try #require(manager.activeTabID)
            manager.activeSession?.content.markdown?.documentManager.text = "edited body"

            let dirtyTabIDs = Set(manager.dirtyDocuments().map(\.tabID))
            #expect(dirtyTabIDs.contains(dirtyMarkdownTabID))
            #expect(!dirtyTabIDs.contains(cleanMarkdownTabID))
            #expect(!dirtyTabIDs.contains(pdfTabID))
            #expect(dirtyTabIDs == [dirtyMarkdownTabID])
        }
    }

    /// The DirtyDoc handle for a dirty Markdown tab carries its title and the
    /// "needs Save-As" routing flag for an untitled buffer.
    @Test
    func dirtyDocForUntitledMarkdownReportsNeedsSaveAs() throws {
        let manager = TabManager()
        manager.newMarkdownDocument()
        manager.activeSession?.content.markdown?.documentManager.text = "x"

        let doc = try #require(manager.dirtyDocuments().first)
        #expect(doc.tabID == manager.activeTabID)
        #expect(doc.title == "Untitled")
        // Untitled → saveSync can't write (no URL); the caller routes to Save-As.
        #expect(doc.needsSaveAs)
    }

    /// The quit flow walks unsaved documents in tab-strip order, and each
    /// reveals its tab before an untitled buffer's Save As panel.
    @Test
    func dirtyDocumentsFollowTabOrderAndRevealTheirTab() throws {
        let manager = TabManager()
        var ids: [UUID] = []
        for index in 0..<6 {
            manager.newMarkdownDocument()
            let id = try #require(manager.activeTabID)
            ids.append(id)
            if index != 2 { manager.activeSession?.content.markdown?.documentManager.text = "draft \(index)" }
        }
        let expected = ids.enumerated().filter { $0.offset != 2 }.map(\.element)
        let dirty = manager.dirtyDocuments()
        #expect(dirty.map(\.tabID) == expected)
        let first = try #require(dirty.first)
        first.reveal()
        #expect(manager.activeTabID == first.tabID)
    }

    // MARK: - (e) Content-aware command predicates

    /// An empty placeholder (PDF, no document) offers none of Save / Find / Print.
    @Test
    func predicatesAreOffForAnEmptyPlaceholder() {
        let manager = TabManager()
        #expect(!manager.canSave)
        #expect(!manager.canFind)
        #expect(!manager.canPrint)
        // Save As is also off for an empty PDF placeholder (no document to copy).
        #expect(!manager.canSaveAs)
    }

    /// A Markdown tab: Save + Save As track content; Find + Print now follow content
    /// (S7a wired the shared Find surface; S9 wired styled-markdown Print). An empty
    /// untitled buffer is the only no-op case for Find/Print — nothing to search/print.
    @Test
    func predicatesFollowMarkdownContent() throws {
        let manager = TabManager()
        manager.newMarkdownDocument()

        // Untitled seeded: Save (routes to Save-As) + Save As; the starter
        // heading is real text, so Find and Print apply from the first moment.
        #expect(manager.canSave)        // untitled → !hasDocumentURL
        #expect(manager.canSaveAs)      // markdown can always Save As
        #expect(manager.canFind)        // the seed heading is searchable text
        #expect(manager.canPrint)       // …and printable

        // After typing, the buffer has content (and is dirty); Find + Print apply.
        manager.activeSession?.content.markdown?.documentManager.text = "body"
        #expect(manager.canSave)
        #expect(manager.canSaveAs)
        #expect(manager.canFind)        // S7a: shared Find routes ⌘F into the editor
        #expect(manager.canPrint)       // S9: ⌘P prints the styled Live-Preview text
    }

    @Test("Find presentation and close cleanup stay with the targeted window")
    func findPresentationBelongsToWindow() throws {
        let target = TabManager(), other = TabManager()
        defer {
            for manager in [target, other] {
                for id in Array(manager.sessions.keys) { manager.closeSession(for: id) }
            }
        }
        target.newMarkdownDocument()
        other.newMarkdownDocument()
        let first = try #require(target.activeMarkdownContent)
        first.documentManager.text = "needle in first document"
        first.searchManager.setQuery("needle")
        first.searchManager.runSearch()
        let second = try #require(other.activeMarkdownContent)
        second.searchManager.setQuery("other")
        target.requestFind(showReplacement: true)
        #expect(target.showingSearch)
        #expect(target.searchFocusRequest == 1)
        #expect(first.searchManager.showsReplacement)
        #expect(!other.showingSearch)
        #expect(other.searchFocusRequest == 0)
        target.requestFind()
        #expect(target.searchFocusRequest == 2)
        #expect(target.canNavigateFind)
        #expect(target.canReplace)
        target.newMarkdownDocument()
        target.activeMarkdownContent?.searchManager.setQuery("second tab")
        target.showingSearch = false
        #expect(first.searchManager.query.isEmpty)
        #expect(target.activeMarkdownContent?.searchManager.query.isEmpty == true)
        #expect(second.searchManager.query == "other")
        #expect(first.searchManager.showsReplacement)
        #expect(!target.canNavigateFind)
    }

    // MARK: - (f) Live-editor staleness fix (the `liveStorageText` seam)

    /// The data-loss core: the engine commits the live NSTextStorage into the
    /// durable `text` on a ~1s deferred binding write, so a tab edited <1s before
    /// ⌘Q has stale (empty) `text`. With the live text injected through the seam,
    /// reconciling BEFORE the dirty gate makes `dirtyDocuments()` see the live edit
    /// and INCLUDE the tab — without the reconcile it would quit with no prompt.
    @Test
    func reconcileMakesDirtyDocumentsSeeLiveEditNotStaleText() throws {
        let manager = TabManager()
        manager.newMarkdownDocument()

        let tabID = try #require(manager.activeTabID)
        let content = try #require(manager.activeSession?.content.markdown)

        // The editor holds an edit the deferred binding write hasn't drained, so
        // the durable buffer still holds the pristine seed (stale) — the tab
        // looks clean.
        content.liveStorageText = { "live edit" }
        #expect(content.documentManager.text == "# Untitled\n\n")
        #expect(!content.documentManager.isDirty)
        #expect(!manager.dirtyDocuments().contains { $0.tabID == tabID })

        // The quit-time reconcile (the peer of WindowRegistry.flushAllEditors).
        manager.flushMarkdownEditors()

        // Now the durable text carries the live edit, so the tab is dirty and
        // SURFACES in the aggregation that gates the quit save prompt.
        #expect(content.documentManager.text == "live edit")
        #expect(content.documentManager.isDirty)
        #expect(manager.dirtyDocuments().contains { $0.tabID == tabID })
    }

    /// The clobber-safety core: an untitled Markdown tab whose live editor holds
    /// typed text reports `canReplaceWithoutPrompt == true` on stale empty `text`
    /// (it would be silently clobbered by ⌘O). After the reconcile the live text
    /// reaches the durable buffer and the gate flips to `false` — protected.
    @Test
    func reconcileProtectsTypedUntitledMarkdownFromClobber() throws {
        let manager = TabManager()
        manager.newMarkdownDocument()

        let session = try #require(manager.activeSession)
        let content = try #require(session.content.markdown)

        // Live edit not yet drained: the durable buffer is empty, so the gate
        // would (wrongly) permit a silent reuse-and-clobber.
        content.liveStorageText = { "typed but undrained" }
        #expect(session.canReplaceWithoutPrompt)

        // Reconcile (the per-open bridge in openDocument's reuse decision).
        content.reconcileLiveText()

        // The buffer now has content + is dirty, so the open must NOT clobber it.
        #expect(!session.canReplaceWithoutPrompt)
    }

    /// A loaded PDF tab: Save / Save As / Find / Print all available (as today).
    @Test
    func predicatesAreOnForALoadedPDF() throws {
        try withTempPDF { url in
            let manager = TabManager()
            manager.openDocument(url: url, isSecurityScoped: false)
            manager.closeFilePicker()
            #expect(manager.activeSession?.pdfManager?.hasDocument == true)

            #expect(manager.canSave)
            #expect(manager.canSaveAs)
            #expect(manager.canFind)
            #expect(manager.canPrint)
            #expect(!manager.canReplace)
            manager.requestFind(showReplacement: true)
            #expect(!manager.showingSearch)
            manager.requestFind()
            #expect(manager.showingSearch)
        }
    }

    // MARK: - (g) External-change reload decision + apply (ADR-0012 D5, S9)

    /// The should-prompt decision: only a file-backed tab whose on-disk bytes are
    /// newer than our baseline prompts. Untitled (no URL) never prompts; a tab that
    /// still matches disk doesn't prompt.
    @Test
    func shouldPromptForExternalChangeRequiresURLAndNewerDisk() async throws {
        // Untitled: no on-disk source, so it never prompts even when dirty.
        let untitled = MarkdownContent(documentId: UUID().uuidString)
        untitled.documentManager.text = "draft"
        #expect(!untitled.shouldPromptForExternalChange)

        try await withTempMarkdown(bytes: Data("v1\n".utf8)) { url in
            let content = MarkdownContent(documentId: UUID().uuidString)
            try content.documentManager.load(from: url)
            #expect(!content.shouldPromptForExternalChange)     // matches disk

            // Simulate an external edit with a strictly newer modification date.
            let future = Date().addingTimeInterval(5)
            try Data("v2 external\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: url.path)

            #expect(content.shouldPromptForExternalChange)      // disk newer → prompt
        }
    }

    /// The activation check sees only the frontmost window's active tab, so ⌘S and
    /// the quit/close save re-read the disk: Cancel leaves the external edit in
    /// place, Keep writes this version over it.
    @Test
    func saveNeverOverwritesAnUnseenExternalChange() async throws {
        try await withTempMarkdown(bytes: Data("v1\n".utf8)) { url in
            let manager = TabManager()
            manager.openDocument(url: url, isSecurityScoped: false)
            let session = try #require(manager.activeSession)
            let content = try #require(session.content.markdown)
            content.documentManager.text = "local\n"
            try Data("external\n".utf8).write(to: url)
            var prompts = 0
            var answer = MarkdownExternalChangeChoice.cancel
            manager.externalChangePrompt = { _, _ in prompts += 1; return answer }

            guard case .cancelled = await manager.saveActiveDocument() else {
                Issue.record("a cancelled external-change prompt must cancel the save"); return
            }
            #expect(try String(contentsOf: url, encoding: .utf8) == "external\n")
            #expect(!DirtyDoc(session: session, owner: manager).saveSync())
            #expect(try String(contentsOf: url, encoding: .utf8) == "external\n")
            #expect(prompts == 2)

            answer = .keepMine
            _ = await manager.saveActiveDocument()
            #expect(try String(contentsOf: url, encoding: .utf8) == "local\n")
            #expect(prompts == 3)
            #expect(!content.documentManager.isDirty)
        }
    }

    /// Reload re-reads the changed bytes, drops the local draft (clean again), and
    /// resets the editor undo stack (⌘Z can't cross an external rewrite). The baseline
    /// advances so the tab stops re-prompting.
    @Test
    func reloadFromDiskClearsDirtyAndResetsUndo() async throws {
        try await withTempMarkdown(bytes: Data("original\n".utf8)) { url in
            let content = MarkdownContent(documentId: UUID().uuidString)
            try content.documentManager.load(from: url)

            content.documentManager.text = "local draft\n"       // dirty
            #expect(content.documentManager.isDirty)
            content.undoManager.beginUndoGrouping()
            content.undoManager.registerUndo(withTarget: content) { _ in }
            content.undoManager.endUndoGrouping()
            #expect(content.undoManager.canUndo)

            // External rewrite with a newer mod date.
            let future = Date().addingTimeInterval(5)
            try Data("external\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: url.path)
            #expect(content.shouldPromptForExternalChange)

            try content.reloadFromDisk()
            #expect(content.documentManager.text == "external\n")   // re-read
            #expect(!content.documentManager.isDirty)               // draft discarded
            #expect(!content.undoManager.canUndo)                   // undo reset
            #expect(!content.shouldPromptForExternalChange)         // baseline advanced
        }
    }

    // MARK: - (h) One-time encoding-downgrade note (ADR-0008, S9)

    /// The note-fire latch: `consumeEncodingDowngradeNote()` returns true exactly once
    /// for a downgraded document (a UTF-16 source that will save as UTF-8), then stays
    /// false so a later save can't nag.
    @Test
    func encodingDowngradeNoteFiresOnceThenLatches() async throws {
        let text = "héllo\nworld\n"
        let bytes = Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!
        try await withTempMarkdown(bytes: bytes) { url in
            let content = MarkdownContent(documentId: UUID().uuidString)
            try content.documentManager.load(from: url)
            #expect(content.documentManager.encodingWasDowngraded)

            #expect(content.consumeEncodingDowngradeNote())     // first time: surface it
            #expect(!content.consumeEncodingDowngradeNote())    // latched off
            #expect(!content.consumeEncodingDowngradeNote())
        }
    }

    /// A document whose encoding was NOT downgraded never surfaces the note.
    @Test
    func encodingDowngradeNoteStaysSilentForPlainUTF8() async throws {
        try await withTempMarkdown(bytes: Data("plain utf8\n".utf8)) { url in
            let content = MarkdownContent(documentId: UUID().uuidString)
            try content.documentManager.load(from: url)
            #expect(!content.documentManager.encodingWasDowngraded)
            #expect(!content.consumeEncodingDowngradeNote())
        }
    }
}
