//
//  MarkdownLocalLinkTests.swift
//  PageFlowTests
//
//  Local links in a note (D8): headings jump, documents open in tabs, other
//  files ask first, and apps or scripts never open from a link.
//

import Foundation
import Testing
@testable import PageFlow

@MainActor
struct MarkdownLocalLinkTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test
    func headingSlugsMatchTitleAndAnchorForms() {
        #expect(MarkdownContent.headingSlug("Getting Started!") == "getting-started")
        #expect(MarkdownContent.headingSlug("getting-started") == "getting-started")
        #expect(MarkdownContent.headingSlug("Part 2: Setup") == "part-2-setup")
    }

    @Test
    func relativeLinksResolveFromTheNotesFolder() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = directory.appendingPathComponent("note.md")
        try Data("# Note\n".utf8).write(to: note)
        let content = MarkdownContent(documentId: UUID().uuidString)
        try content.documentManager.load(from: note)

        #expect(content.localLinkTarget(try #require(URL(string: "sub/other%20note.md")))?.path
                == directory.appendingPathComponent("sub/other note.md").standardizedFileURL.path)
        #expect(content.localLinkTarget(try #require(URL(string: "/abs/x.md")))?.path == "/abs/x.md")
        #expect(MarkdownContent(documentId: "untitled").localLinkTarget(try #require(URL(string: "x.md"))) == nil)
    }

    @Test
    func aLinkedNoteOpensInATab() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = directory.appendingPathComponent("note.md")
        let other = directory.appendingPathComponent("other.md")
        try Data("[next](other.md)\n".utf8).write(to: note)
        try Data("# Other\n".utf8).write(to: other)
        let manager = TabManager()
        manager.openDocument(url: note, isSecurityScoped: false)
        let content = try #require(manager.activeSession?.content.markdown)

        manager.openLocalLink(try #require(URL(string: "other.md")), from: content)

        #expect(manager.tabID(for: other) != nil)
    }

    @Test
    func scriptsNeverOpenAndOtherFilesAskFirst() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = directory.appendingPathComponent("note.md")
        try Data("links\n".utf8).write(to: note)
        try Data("#!/bin/sh\n".utf8).write(to: directory.appendingPathComponent("run.sh"))
        try Data("a,b\n".utf8).write(to: directory.appendingPathComponent("data.csv"))
        let manager = TabManager()
        manager.openDocument(url: note, isSecurityScoped: false)
        let content = try #require(manager.activeSession?.content.markdown)
        var asked: [String] = []
        manager.localFileLinkPrompt = { asked.append($0); return false }

        manager.openLocalLink(try #require(URL(string: "run.sh")), from: content)
        manager.openLocalLink(try #require(URL(string: "data.csv")), from: content)

        #expect(asked == ["data.csv"], "a script is refused before any prompt")
    }
}
