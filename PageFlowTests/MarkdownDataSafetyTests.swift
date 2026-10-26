//
//  MarkdownDataSafetyTests.swift
//  PageFlowTests
//
//  A note's text must never be dropped or rewritten without the user seeing
//  it: a deleted backing file keeps its tab unsaved, and a disk check reports
//  deletion apart from modification.
//

import Foundation
import Testing
@testable import PageFlow

@MainActor
struct MarkdownDataSafetyTests {
    private func temporaryNote(_ source: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("markdown-safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("note.md")
        try Data(source.utf8).write(to: url)
        return url
    }

    private func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test
    func aDeletedFileReadsAsMissingNotModified() throws {
        let url = try temporaryNote("only copy\n")
        defer { cleanUp(url) }
        let manager = MarkdownDocumentManager()
        try manager.load(from: url)
        try FileManager.default.removeItem(at: url)

        #expect(manager.diskChange() == .missing)
        #expect(!manager.diskWasModifiedExternally())
        #expect(!manager.isDirty, "the tab only turns unsaved once kept or closed")
    }

    @Test
    func keepingAMissingFileStaysUnsavedUntilSaveWritesItBack() async throws {
        let url = try temporaryNote("only copy\n")
        defer { cleanUp(url) }
        let manager = MarkdownDocumentManager()
        try manager.load(from: url)
        try FileManager.default.removeItem(at: url)

        manager.keepAfterMissingFile()
        #expect(manager.isDirty)
        #expect(manager.diskChange() == .unchanged, "a kept missing file prompts once")

        #expect(await manager.save())
        #expect(try String(contentsOf: url, encoding: .utf8) == "only copy\n")
        #expect(!manager.isDirty && !manager.isBackingFileMissing)
    }

    @Test
    func closeAndQuitBoundariesNoticeAVanishedFile() async throws {
        let url = try temporaryNote("only copy\n")
        defer { cleanUp(url) }
        let manager = TabManager()
        await manager.openDocument(url: url, isSecurityScoped: false)?.value
        let session = try #require(manager.activeSession)
        try FileManager.default.removeItem(at: url)
        #expect(!session.isDirty)

        manager.flushMarkdownEditors()

        #expect(session.isDirty, "quit and window close must offer to write it back")
        #expect(manager.dirtyDocuments().map(\.tabID) == [session.id])
    }

    @Test
    func aReturningFileWithTheSameSourceClearsTheMissingState() throws {
        let url = try temporaryNote("only copy\n")
        defer { cleanUp(url) }
        let manager = MarkdownDocumentManager()
        try manager.load(from: url)
        try FileManager.default.removeItem(at: url)
        manager.keepAfterMissingFile()

        try Data("only copy\n".utf8).write(to: url)

        #expect(manager.diskChange() == .unchanged)
        #expect(!manager.isDirty)
    }

    @Test(arguments: [false, true])
    func saveCannotInferEqualityFromAnUnreadableFileWithAnOlderDate(synchronous: Bool) async throws {
        let url = try temporaryNote("Original file\n")
        defer { cleanUp(url) }
        let owner = TabManager()
        await owner.openDocument(url: url, isSecurityScoped: false, bringsToFront: false)?.value
        let content = try #require(owner.activeMarkdownContent)
        defer { for session in owner.sessions.values { session.cleanup() } }
        let date = try #require(content.documentManager.contentModificationDate)
        content.documentManager.text = "Local draft must survive"
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let child = url.appendingPathComponent("preserve.txt")
        try Data("Separate contents".utf8).write(to: child)
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(-60)], ofItemAtPath: url.path)
        if synchronous {
            let session = try #require(owner.activeSession)
            #expect(!DirtyDoc(session: session, owner: owner).saveSync())
        } else {
            let result = await owner.saveActiveDocument()
            if case .cancelled = result {} else { Issue.record("An unreadable backing file must not authorize an overwrite") }
        }
        #expect((try? Data(contentsOf: child)) == Data("Separate contents".utf8))
        #expect(content.documentManager.text == "Local draft must survive" && content.documentManager.isDirty)
    }

    @Test(arguments: [false, true])
    func commandSaveAllowsReadableEmptyAndMissingFiles(fileMissing: Bool) async throws {
        let url = try temporaryNote("")
        defer { cleanUp(url) }
        let owner = TabManager()
        await owner.openDocument(url: url, isSecurityScoped: false, bringsToFront: false)?.value
        let content = try #require(owner.activeMarkdownContent)
        defer { for session in owner.sessions.values { session.cleanup() } }
        content.documentManager.text = "Saved local draft\n"
        if fileMissing { try FileManager.default.removeItem(at: url) }
        if case .success = await owner.saveActiveDocument() {} else { Issue.record("The draft could not be saved") }
        #expect(try Data(contentsOf: url) == Data("Saved local draft\n".utf8))
        #expect(!content.documentManager.isDirty)
    }

    @Test
    func aStaleObservationNeverPrompts() async throws {
        let url = try temporaryNote("v1\n")
        defer { cleanUp(url) }
        let manager = MarkdownDocumentManager()
        try manager.load(from: url)
        let probe = try #require(manager.diskProbe())
        manager.text = "v2\n"
        #expect(await manager.save())

        // Read after our own save landed, against the probe taken before it.
        let observation = MarkdownDocumentManager.observe(probe)
        #expect(manager.resolve(observation, for: probe) == .unchanged)
    }

    @Test
    func savingADamagedUTF8NoteAsksOnceBeforeReplacingItsBytes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("markdown-safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("damaged.md")
        var bytes = Data("café\n".utf8)
        bytes.append(0xFF)
        try bytes.write(to: url)

        let manager = TabManager()
        await manager.openDocument(url: url, isSecurityScoped: false)?.value
        let content = try #require(manager.activeSession?.content.markdown)
        #expect(content.documentManager.hasInvalidUTF8)
        content.documentManager.text += "more\n"
        var asked = 0
        var answer = false
        manager.invalidUTF8SavePrompt = { _ in asked += 1; return answer }

        guard case .cancelled = await manager.saveActiveDocument() else {
            Issue.record("declining must cancel the save"); return
        }
        #expect(try Data(contentsOf: url) == bytes)

        answer = true
        _ = await manager.saveActiveDocument()
        #expect(try String(contentsOf: url, encoding: .utf8) == "café\n\u{FFFD}more\n")
        #expect(!content.documentManager.hasInvalidUTF8)

        content.documentManager.text += "again\n"
        _ = await manager.saveActiveDocument()
        #expect(asked == 2, "a saved file is valid UTF-8, so later saves never ask")
    }

    @Test
    func aBinaryFileNamedMarkdownNeverOpens() async throws {
        let url = try temporaryNote("")
        defer { cleanUp(url) }
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x0D, 0x0A]).write(to: url)
        let manager = TabManager()

        await manager.openDocument(url: url, isSecurityScoped: false)?.value

        #expect(manager.tabID(for: url) == nil)
        #expect(try Data(contentsOf: url).count == 8, "the file is never rewritten")
    }

    @Test
    func anEditInsideTheDamagedEncodingPromptRevokesTheSave() async throws {
        let url = try temporaryNote("")
        defer { cleanUp(url) }
        var bytes = Data("café\n".utf8)
        bytes.append(0xFF)
        try bytes.write(to: url)
        let owner = TabManager()
        await owner.openDocument(url: url, isSecurityScoped: false, bringsToFront: false)?.value
        let content = try #require(owner.activeMarkdownContent)
        defer { for session in owner.sessions.values { session.cleanup() } }
        try #require(content.documentManager.hasInvalidUTF8)
        content.documentManager.text = "Approved draft"
        var prompts = 0
        owner.invalidUTF8SavePrompt = { _ in
            prompts += 1
            content.documentManager.text = "Changed while the prompt was open"
            return true
        }
        let result = await owner.saveActiveDocument()
        #expect(prompts == 1)
        if case .cancelled = result {} else { Issue.record("A changed draft must revoke encoding replacement approval") }
        #expect(try Data(contentsOf: url) == bytes)
        #expect(content.documentManager.text == "Changed while the prompt was open" && content.documentManager.isDirty)
    }

    @Test
    func aUTF16NoteWithItsByteOrderMarkStillOpens() async throws {
        let url = try temporaryNote("")
        defer { cleanUp(url) }
        var bytes = Data([0xFF, 0xFE])
        bytes.append(try #require("hi\n".data(using: .utf16LittleEndian)))
        try bytes.write(to: url)
        let manager = TabManager()

        await manager.openDocument(url: url, isSecurityScoped: false)?.value

        #expect(manager.tabID(for: url) != nil)
    }

    @Test
    func aLargeNoteAsksBeforeOpening() async throws {
        let url = try temporaryNote(String(repeating: "a", count: TabManager.largeNoteWarningBytes + 1))
        defer { cleanUp(url) }
        let manager = TabManager()
        var asked = 0
        var answer = false
        manager.largeNoteOpenPrompt = { _, size in
            asked += 1
            #expect(size == TabManager.largeNoteWarningBytes + 1)
            return answer
        }

        await manager.openDocument(url: url, isSecurityScoped: false)?.value
        #expect(manager.tabID(for: url) == nil)

        answer = true
        await manager.openDocument(url: url, isSecurityScoped: false)?.value
        #expect(manager.tabID(for: url) != nil)
        #expect(asked == 2)
    }

    @Test
    func aLocalFileIsNeverTreatedAsCloudOnly() throws {
        let url = try temporaryNote("local\n")
        defer { cleanUp(url) }
        #expect(!url.pageFlowIsDataless)
        #expect(url.pageFlowFileSize == 6)
        #expect(url.pageFlowDownloadContents(isSecurityScoped: false))
    }

    @Test
    func sourceEqualityIsByteExact() {
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        #expect(composed == decomposed, "Swift calls them equal")
        #expect(!composed.hasSameSource(as: decomposed), "but they save different bytes")
        #expect("same".hasSameSource(as: "same"))
        #expect("".hasSameSource(as: ""))
        let bridged = NSString(string: "bridged é") as String
        #expect(bridged.hasSameSource(as: "bridged é"))
    }
}
