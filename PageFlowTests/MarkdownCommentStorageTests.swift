//
//  MarkdownCommentStorageTests.swift
//  PageFlowTests
//
//  A note's comments (doc 25) live in the note: a hidden block at the end of
//  the file, split off at load so the editor never sees it and written back
//  with the note.
//

import Foundation
import MarkdownEngine
import Testing
@testable import PageFlow

@MainActor
struct MarkdownCommentStorageTests {
    private func withNote(_ contents: String, _ body: (URL) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("comments-\(UUID().uuidString).md")
        try Data(contents.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try await body(url)
    }

    private func onDisk(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    private func thread(_ quote: String, _ body: String) -> MarkdownCommentThread {
        MarkdownCommentThread(anchor: MarkdownCommentAnchor(prefix: "", exact: quote, suffix: ""),
                              root: MarkdownComment(body: body, createdAt: Date(timeIntervalSince1970: 1_760_400_000)))
    }

    /// What the editor does when a comment changes: its store holds the threads, and it reports them.
    private func comment(_ threads: [MarkdownCommentThread], in content: MarkdownContent) {
        content.editorController.commentThreads = threads
        content.editorController.onCommentThreadsChange?(threads)
    }

    @Test
    func aNoteOpensWithoutItsBlockAndItsCommentsGoToTheEditor() async throws {
        let block = MarkdownCommentBlock.block(for: [thread("Monday", "Is Monday realistic?")])
        try await withNote("# Plan\n\nShip on Monday.\n\n" + block) { url in
            let content = MarkdownContent(documentId: UUID().uuidString)
            try content.documentManager.load(from: url)
            content.loadComments()
            #expect(content.documentManager.text == "# Plan\n\nShip on Monday.\n")
            #expect(content.documentManager.commentBlock == block)
            #expect(!content.documentManager.isDirty)
            #expect(content.editorController.commentThreads.map(\.root.body) == ["Is Monday realistic?"])
            #expect(content.openCommentCount == 1)
            #expect(content.documentManager.wordCount == WordCount.count("# Plan\n\nShip on Monday.\n"),
                    "the block is not part of the note's text")
        }
    }

    @Test
    func aCommentMakesTheNoteUnsavedAndSavingWritesItAtTheEnd() async throws {
        try await withNote("# Plan\n\nShip on Monday.\n") { url in
            let content = MarkdownContent(documentId: UUID().uuidString)
            try content.documentManager.load(from: url)
            content.loadComments()
            comment([thread("Monday", "Is Monday realistic?")], in: content)
            #expect(content.documentManager.isDirty, "the comment is unsaved until the note is")
            #expect(onDisk(url) == "# Plan\n\nShip on Monday.\n")
            #expect(content.saveSync())
            #expect(!content.documentManager.isDirty)
            let saved = onDisk(url)
            #expect(saved.hasPrefix("# Plan\n\nShip on Monday.\n\n<!-- pageflow-comments\n"))
            #expect(saved.hasSuffix("\n-->\n"))
            #expect(MarkdownCommentBlock.threads(in: MarkdownCommentBlock.split(saved).block).map(\.root.body)
                == ["Is Monday realistic?"])
        }
    }

    @Test
    func savingWithoutChangesKeepsTheFileByteForByte() async throws {
        let block = MarkdownCommentBlock.block(for: [thread("Monday", "Why?")])
        let original = "Ship on Monday.\n\n" + block
        try await withNote(original) { url in
            let content = MarkdownContent(documentId: UUID().uuidString)
            try content.documentManager.load(from: url)
            content.loadComments()
            content.documentManager.text = "Ship on Monday!\n"
            content.documentManager.text = "Ship on Monday.\n"
            #expect(!content.documentManager.isDirty)
            #expect(content.saveSync())
            #expect(onDisk(url) == original)
        }
        try await withNote("No comments here.\n") { url in
            let content = MarkdownContent(documentId: UUID().uuidString)
            try content.documentManager.load(from: url)
            content.loadComments()
            content.documentManager.text = "No comments here, edited.\n"
            #expect(content.saveSync())
            #expect(onDisk(url) == "No comments here, edited.\n", "a note without comments gets no block")
        }
    }

    @Test
    func deletingTheLastCommentRemovesTheBlock() async throws {
        let block = MarkdownCommentBlock.block(for: [thread("Monday", "Why?")])
        try await withNote("Ship on Monday.\n\n" + block) { url in
            let content = MarkdownContent(documentId: UUID().uuidString)
            try content.documentManager.load(from: url)
            content.loadComments()
            comment([], in: content)
            #expect(content.documentManager.isDirty)
            #expect(content.saveSync())
            #expect(onDisk(url) == "Ship on Monday.\n")
        }
    }

    @Test
    func aReloadReadsTheCommentsTheFileHasNow() async throws {
        try await withNote("Ship on Monday.\n") { url in
            let content = MarkdownContent(documentId: UUID().uuidString)
            try content.documentManager.load(from: url)
            content.loadComments()
            let block = MarkdownCommentBlock.block(for: [thread("Monday", "Added elsewhere")])
            try Data(("Ship on Monday.\n\n" + block).utf8).write(to: url)
            #expect(content.documentManager.diskWasModifiedExternally())
            try content.reloadFromDisk()
            #expect(content.documentManager.text == "Ship on Monday.\n")
            #expect(content.editorController.commentThreads.map(\.root.body) == ["Added elsewhere"])
            #expect(!content.documentManager.isDirty)
        }
    }

    @Test
    func aCRLFNoteKeepsItsLineEndingsWithItsComments() async throws {
        try await withNote("Ship on Monday.\r\n") { url in
            let content = MarkdownContent(documentId: UUID().uuidString)
            try content.documentManager.load(from: url)
            content.loadComments()
            comment([thread("Monday", "Why?")], in: content)
            #expect(content.saveSync())
            let saved = onDisk(url)
            #expect(saved.hasPrefix("Ship on Monday.\r\n\r\n<!-- pageflow-comments\r\n"))
            #expect(!saved.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "every line ends in CRLF")
            let reopened = MarkdownContent(documentId: UUID().uuidString)
            try reopened.documentManager.load(from: url)
            reopened.loadComments()
            #expect(reopened.documentManager.text == "Ship on Monday.\n")
            #expect(reopened.editorController.commentThreads.map(\.root.body) == ["Why?"])
        }
    }
}
