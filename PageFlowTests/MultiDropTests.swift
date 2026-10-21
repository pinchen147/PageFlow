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
import UniformTypeIdentifiers
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

    struct Batch: Sendable {
        let kinds: [String]
        let destination: String
        let cloudDelayed: Bool
    }
    static let batches = [["pdf", "pdf", "pdf"], ["md", "markdown", "md"],
                          ["md", "pdf", "markdown"], ["pdf", "md", "pdf"]].flatMap { kinds in
        ["empty", "pdf", "markdown"].flatMap { destination in
            [false, true].map { Batch(kinds: kinds, destination: destination, cloudDelayed: $0) }
        }
    }

    @Test(arguments: batches)
    func droppingDistinctDocumentsOpensOneTabEachInOrder(_ batch: Batch) async throws {
        let kinds = batch.kinds, destination = batch.destination
        var files: [URL] = []
        defer { cleanup(files) }
        let urls = try kinds.enumerated().map { index, kind in
            let url: URL
            if kind == "pdf" { url = writeBlankPDF() }
            else {
                url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(kind)
                try Data("# Dropped note \(index)\n".utf8).write(to: url)
            }
            files.append(url)
            return url
        }

        let tabManager = TabManager()
        var existing: [URL] = []
        if destination == "pdf" {
            let url = writeBlankPDF()
            files.append(url)
            existing.append(url)
            tabManager.openDocument(url: url, isSecurityScoped: false, bringsToFront: false)
        } else if destination == "markdown" {
            tabManager.newMarkdownDocument()
            tabManager.activeSession?.content.markdown?.documentManager.text = "Existing unsaved note\n"
        }
        let originalSession = tabManager.activeSession
        if batch.cloudDelayed {
            var cloudURLs = Set(urls.map(\.pageFlowCanonicalDocumentURL))
            // The real scratch files supply download/read bytes; this replaces
            // only cloud metadata admission, separately for each document.
            tabManager.isCloudOnly = { cloudURLs.remove($0.pageFlowCanonicalDocumentURL) != nil }
        }
        let failed = tabManager.openDroppedDocuments(urls)
        let downloads = Array(tabManager.downloadingTasks.values)
        for task in downloads { await task.value }
        let pending = tabManager.sessions.values.compactMap { $0.pendingMarkdownOpen?.task }
        for task in pending { await task.value }

        #expect(failed == 0)
        #expect(tabManager.tabs.count == (destination == "empty" ? 3 : 4))
        #expect(
            tabManager.tabs.compactMap { $0.documentURL?.pageFlowCanonicalDocumentURL }
                == (existing + urls).map { $0.pageFlowCanonicalDocumentURL }
        )
        if destination == "markdown" {
            #expect(tabManager.sessions[try #require(originalSession).id] === originalSession)
            #expect(originalSession?.content.markdown?.documentManager.text == "Existing unsaved note\n")
        }
        // The last dropped file is active (macOS document convention).
        #expect(tabManager.activeTabID == tabManager.tabs.last?.id)
    }

    @Test(arguments: [0, 1, 2], ["pdf", "md"])
    func oneUnreadableFileDoesNotDiscardTheRestOfTheBatch(position: Int, kind: String) async throws {
        let first = writeBlankPDF()
        let last = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("md")
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(kind)
        defer { cleanup([first, last, bad]) }
        try Data("# Last note\n".utf8).write(to: last)
        try Data([0, 1, 2, 3]).write(to: bad)
        var urls = [first, last]
        urls.insert(bad, at: position)
        let manager = TabManager()
        #expect(manager.openDroppedDocuments(urls) == (kind == "pdf" ? 1 : 0))
        let pending = manager.sessions.values.compactMap { $0.pendingMarkdownOpen?.task }
        for task in pending { await task.value }
        #expect(manager.tabs.compactMap(\.documentURL).map(\.pageFlowCanonicalDocumentURL)
                == [first, last].map(\.pageFlowCanonicalDocumentURL))
        #expect(manager.tabs.count == 2)
    }

    @Test
    func finishingCloudDropsDoesNotTakeTheSelectionFromANewDraft() async throws {
        let urls = [writeBlankPDF(), writeBlankPDF()]
        defer { cleanup(urls) }
        let manager = TabManager()
        var cloudURLs = Set(urls.map(\.pageFlowCanonicalDocumentURL))
        manager.isCloudOnly = { cloudURLs.remove($0.pageFlowCanonicalDocumentURL) != nil }
        manager.openDroppedDocuments(urls)
        let downloads = Array(manager.downloadingTasks.values)
        manager.newMarkdownDocument()
        let draft = try #require(manager.activeSession)
        draft.content.markdown?.documentManager.text = "Keep writing here\n"
        for task in downloads { await task.value }
        #expect(manager.activeSession === draft)
        #expect(draft.content.markdown?.documentManager.text == "Keep writing here\n")
        #expect(Set(manager.tabs.compactMap(\.documentURL).map(\.pageFlowCanonicalDocumentURL))
                == Set(urls.map(\.pageFlowCanonicalDocumentURL)))
    }

    @Test(arguments: [false, true])
    func everyFileURLProviderResolvesItsOwnFile(dataRepresentation: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drop-providers-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { cleanup([directory]) }
        let urls = ["One.pdf", "Two 中文.md", "Three.markdown"].map { directory.appendingPathComponent($0) }
        for url in urls { try Data("fixture".utf8).write(to: url) }
        let providers = urls.map { url in
            if !dataRepresentation { return NSItemProvider(object: url as NSURL) }
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { complete in
                DispatchQueue.global().async { complete(url.dataRepresentation, nil) }
                return nil
            }
            return provider
        }
        var resolved: [URL] = []
        for provider in providers {
            if let url = await provider.loadDroppedFileURL() { resolved.append(url) }
        }
        #expect(resolved == urls)
    }

    @Test
    func theNewestCloudDropOwnsSelectionWhenAnOlderDropFinishesFirst() async throws {
        let first = writeBlankPDF(), second = writeBlankPDF()
        defer { cleanup([first, second]) }
        let gate = DropCoordinationGate()
        let writer = Task.detached {
            var error: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: second, options: [], error: &error) { _ in gate.hold() }
            return error == nil
        }
        defer { gate.release() }
        let deadline = ContinuousClock.now + .seconds(3)
        while !gate.isHolding, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(gate.isHolding, "the native writer must own the second file before dropping")
        let manager = TabManager()
        var cloudURLs = Set([first, second].map(\.pageFlowCanonicalDocumentURL))
        manager.isCloudOnly = { cloudURLs.remove($0.pageFlowCanonicalDocumentURL) != nil }
        manager.openDroppedDocuments([first])
        manager.openDroppedDocuments([second])
        let downloads = Array(manager.downloadingTasks.values)
        let readyDeadline = ContinuousClock.now + .seconds(3)
        while manager.tabID(for: first) == nil, ContinuousClock.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let olderFinishedFirst = manager.tabID(for: first) != nil && manager.tabID(for: second) == nil
        gate.release()
        #expect(await writer.value)
        for task in downloads { await task.value }
        try #require(olderFinishedFirst, "the second native read must remain blocked until the first drop finishes")
        #expect(manager.activeTabID == manager.tabID(for: second))
        #expect(manager.tabs.count == 2)
    }

    @Test(arguments: ["pdf", "md"])
    func repeatedCloudFilesDoNotDuplicateOrReverseTheBatch(kind: String) async throws {
        let first = kind == "pdf" ? writeBlankPDF() : FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("md")
        let second = writeBlankPDF()
        defer { cleanup([first, second]) }
        if kind == "md" { try Data("# First\n".utf8).write(to: first) }
        let manager = TabManager()
        var cloudURLs = Set([first, second].map(\.pageFlowCanonicalDocumentURL))
        manager.isCloudOnly = { cloudURLs.remove($0.pageFlowCanonicalDocumentURL) != nil }
        manager.openDroppedDocuments([first, second, first])
        let downloads = Array(manager.downloadingTasks.values)
        for task in downloads { await task.value }
        #expect(manager.tabs.compactMap(\.documentURL).map(\.pageFlowCanonicalDocumentURL)
                == [first, second].map(\.pageFlowCanonicalDocumentURL))
        #expect(manager.activeTabID == manager.tabID(for: first))
    }

    @Test
    func droppingTheSamePendingCloudFileAgainSelectsItsOneResult() async throws {
        let url = writeBlankPDF()
        defer { cleanup([url]) }
        let gate = DropCoordinationGate()
        let writer = Task.detached {
            var error: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &error) { _ in gate.hold() }
            return error == nil
        }
        defer { gate.release() }
        let deadline = ContinuousClock.now + .seconds(3)
        while !gate.isHolding, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(gate.isHolding)
        let manager = TabManager()
        manager.newMarkdownDocument()
        let draft = try #require(manager.activeSession)
        draft.content.markdown?.documentManager.text = "Unsaved original\n"
        var cloudOnly = true
        manager.isCloudOnly = { _ in cloudOnly }
        manager.openDroppedDocuments([url])
        manager.openDroppedDocuments([url])
        let downloads = Array(manager.downloadingTasks.values)
        let oneDownload = downloads.count == 1
        cloudOnly = false
        gate.release()
        #expect(await writer.value)
        for task in downloads { await task.value }
        try #require(oneDownload, "the second drop must share the existing native download")
        #expect(manager.activeTabID == manager.tabID(for: url))
        #expect(manager.tabs.count == 2)
        #expect(draft.content.markdown?.documentManager.text == "Unsaved original\n")
    }

    @Test
    func aFileAlreadyOpenInAnotherWindowIsRetainedThereWhileOtherFilesOpenHere() async throws {
        let shared = writeBlankPDF(), fresh = writeBlankPDF()
        defer { cleanup([shared, fresh]) }
        let other = TabManager(), destination = TabManager()
        other.openDocument(url: shared, isSecurityScoped: false, bringsToFront: false)
        let original = try #require(other.activeSession)
        let windows = [other, destination].map { owner in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            WindowRegistry.shared.register(owner, window: window)
            return window
        }
        defer {
            for (owner, window) in zip([other, destination], windows) {
                WindowRegistry.shared.unregister(owner)
                window.close()
            }
        }
        #expect(destination.openDroppedDocuments([shared, fresh]) == 0)
        #expect(destination.tabs.compactMap(\.documentURL).map(\.pageFlowCanonicalDocumentURL)
                == [fresh.pageFlowCanonicalDocumentURL])
        #expect(other.activeSession === original)
        #expect(other.tabs.compactMap(\.documentURL).map(\.pageFlowCanonicalDocumentURL)
                == [shared.pageFlowCanonicalDocumentURL])
    }

    @Test
    func passwordProtectedFilesRemainQueuedWhileEveryOtherDroppedFileOpens() throws {
        var files: [URL] = []
        defer { cleanup(files) }
        let locked = try (0..<2).map { _ -> URL in
            let url = writeBlankPDF()
            files.append(url)
            let document = try #require(PDFDocument(url: url))
            let data = try #require(document.dataRepresentation(options: [
                PDFDocumentWriteOption.ownerPasswordOption: "owner",
                PDFDocumentWriteOption.userPasswordOption: "reader"
            ]))
            try data.write(to: url)
            return url
        }
        let plain = writeBlankPDF()
        files.append(plain)
        let urls = [locked[0], plain, locked[1]]
        let manager = TabManager()
        #expect(manager.openDroppedDocuments(urls) == 0)
        #expect(manager.tabs.count == 3)
        #expect(manager.tabID(for: plain) != nil)
        for url in locked {
            let prompt = try #require(manager.pendingPasswordRequest)
            #expect(prompt.url.pageFlowCanonicalDocumentURL == url.pageFlowCanonicalDocumentURL)
            #expect(manager.submitPassword("reader", for: prompt))
        }
        #expect(manager.pendingPasswordRequest == nil)
        #expect(manager.tabs.compactMap(\.documentURL).map(\.pageFlowCanonicalDocumentURL)
                == urls.map(\.pageFlowCanonicalDocumentURL))
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

    @Test
    func savingADroppedSymlinkedNoteWritesItsTarget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { cleanup([directory]) }
        let target = directory.appendingPathComponent("vault-note.md")
        let link = directory.appendingPathComponent("linked-note.md")
        try Data("v1\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let tabManager = TabManager()
        #expect(tabManager.openDroppedDocuments([link]) == 0)
        await tabManager.openDocument(url: target, isSecurityScoped: false, bringsToFront: false)?.value
        let content = try #require(tabManager.activeSession?.content.markdown)
        content.documentManager.text = "v2\n"
        _ = await tabManager.saveActiveDocument()

        let linkAttributes = try FileManager.default.attributesOfItem(atPath: link.path)
        #expect(linkAttributes[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(try String(contentsOf: target, encoding: .utf8) == "v2\n")
    }

    /// Doc 26 §9.1: over a note's text the editor decides the window overlay.
    /// Documents keep it; images hide it so the editor's drop line shows.
    @Test
    func theEditorDecidesTheDropOverlayWhileADragIsOverItsText() {
        let tabManager = TabManager()
        #expect(!tabManager.isFileDropHovering)
        tabManager.isTabSurfaceDropHovering = true
        #expect(tabManager.isFileDropHovering)
        tabManager.editorFileDragShowsOverlay = false
        #expect(!tabManager.isFileDropHovering)
        tabManager.isTabSurfaceDropHovering = false
        tabManager.editorFileDragShowsOverlay = true
        #expect(tabManager.isFileDropHovering)
        tabManager.editorFileDragShowsOverlay = nil
        #expect(!tabManager.isFileDropHovering)
    }
}

/// Holds a real file-coordination write grant without changing file bytes.
/// It controls native read admission instead of substituting download results.
private nonisolated final class DropCoordinationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var holding = false
    private var released = false
    var isHolding: Bool {
        condition.lock()
        defer { condition.unlock() }
        return holding
    }
    func hold() {
        condition.lock()
        holding = true
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
    }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
