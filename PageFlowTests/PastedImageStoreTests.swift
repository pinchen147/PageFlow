//
//  PastedImageStoreTests.swift
//  PageFlowTests
//
//  The markdown an image becomes when dropped or pasted into a note: file
//  links, and image data saved beside the note.
//

import AppKit
import Foundation
import Testing
@testable import PageFlow

struct PastedImageStoreTests {
    private let note = URL(fileURLWithPath: "/tmp/pageflow-test/notes/note.md")

    @Test
    func linkIsRelativeInsideTheNoteFolderAndAbsoluteOutside() {
        #expect(PastedImageStore.link(for: URL(fileURLWithPath: "/tmp/pageflow-test/notes/pics/a.png"), documentURL: note)
                == "![a](pics/a.png)")
        #expect(PastedImageStore.link(for: URL(fileURLWithPath: "/Users/x/Downloads/b.jpg"), documentURL: note)
                == "![b](/Users/x/Downloads/b.jpg)")
        #expect(PastedImageStore.link(for: URL(fileURLWithPath: "/Users/x/Downloads/c.jpg"), documentURL: nil)
                == "![c](/Users/x/Downloads/c.jpg)")
    }

    @Test
    func pathsWithSpacesOrParenthesesAreAngleBracketed() {
        let spaced = URL(fileURLWithPath: "/Users/x/Downloads/on earth we're briefly gorgeous back.jpg")
        #expect(PastedImageStore.link(for: spaced, documentURL: nil)
                == "![on earth we're briefly gorgeous back](</Users/x/Downloads/on earth we're briefly gorgeous back.jpg>)")
        #expect(PastedImageStore.link(for: URL(fileURLWithPath: "/tmp/pageflow-test/notes/shot (1).png"), documentURL: note)
                == "![shot (1)](<shot (1).png>)")
    }

    @Test @MainActor
    func onlyImageFilesOnThePasteboardBecomeLinks() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pf-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let access = PastedImageStore(defaults: UserDefaults(suiteName: "pf-test-\(UUID().uuidString)")!)

        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/pageflow-test/doc.pdf") as NSURL])
        #expect(access.markdownLinks(for: pasteboard, documentURL: note) == nil)

        pasteboard.clearContents()
        pasteboard.writeObjects([
            URL(fileURLWithPath: "/tmp/pageflow-test/notes/a.png") as NSURL,
            URL(fileURLWithPath: "/tmp/pageflow-test/doc.pdf") as NSURL,
            URL(fileURLWithPath: "/tmp/pageflow-test/b.jpeg") as NSURL,
        ])
        #expect(access.markdownLinks(for: pasteboard, documentURL: note)
                == "![a](a.png)\n\n![b](/tmp/pageflow-test/b.jpeg)")
    }

    @Test @MainActor
    func imageDataIsSavedBesideTheNoteAndLinkedRelatively() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pf-paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = folder.appendingPathComponent("note.md")
        let store = PastedImageStore(defaults: UserDefaults(suiteName: "pf-test-\(UUID().uuidString)")!,
                                     folderAccess: FolderAccessStore(defaults: UserDefaults(suiteName: "pf-test-\(UUID().uuidString)")!))
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pf-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([image])

        let link = try #require(store.markdownLinks(for: pasteboard, documentURL: note))
        #expect(link.hasPrefix("![Pasted image ") && link.contains("](<attachments/Pasted image ") && link.hasSuffix(".png>)"))
        let saved = try #require(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("attachments").path).first)
        #expect(saved.hasPrefix("Pasted image ") && saved.hasSuffix(".png"))
        #expect(NSImage(contentsOf: folder.appendingPathComponent("attachments/\(saved)")) != nil, "a decodable PNG was written")
    }

    @Test @MainActor
    func collidingPastesPreserveEarlierImagesAndExistingAttachments() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pf-paste-collision-\(UUID().uuidString)", isDirectory: true)
        let attachments = folder.appendingPathComponent(PastedImageStore.attachmentsFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "pf-paste-collision-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PastedImageStore(defaults: defaults, folderAccess: FolderAccessStore(defaults: defaults))
        let note = folder.appendingPathComponent("note.md")
        let name = PastedImageStore.pastedImageName(at: Date(timeIntervalSince1970: 1_800_000_000))
        let existing = attachments.appendingPathComponent(name)
        let existingBytes = Data([0, 1, 2])
        let firstBytes = Data([3, 4, 5])
        let secondBytes = Data([6, 7, 8])
        try existingBytes.write(to: existing)

        let first = try #require(store.save(firstBytes, documentURL: note, name: name))
        let second = try #require(store.save(secondBytes, documentURL: note, name: name))

        #expect(first != second)
        #expect(first != existing && second != existing)
        #expect(first.deletingLastPathComponent() == attachments && second.deletingLastPathComponent() == attachments)
        #expect(first.pathExtension == "png" && second.pathExtension == "png")
        #expect(try Data(contentsOf: existing) == existingBytes)
        #expect(try Data(contentsOf: first) == firstBytes)
        #expect(try Data(contentsOf: second) == secondBytes)
    }

    @Test
    func pastedImageNamesFollowObsidian() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let name = PastedImageStore.pastedImageName(at: date)
        #expect(name.hasPrefix("Pasted image 20") && name.hasSuffix(".png") && name.count == "Pasted image 20260913220512.png".count)
    }

    @Test
    func imageDetectionFollowsTheFileExtension() {
        for ext in ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"] {
            #expect(PastedImageStore.isImage(URL(fileURLWithPath: "/x/f.\(ext)")), Comment(rawValue: ext))
        }
        for ext in ["md", "pdf", "txt", ""] {
            #expect(!PastedImageStore.isImage(URL(fileURLWithPath: "/x/f.\(ext)")), Comment(rawValue: ext))
        }
    }

    @Test @MainActor
    func savingAnUntitledNoteMovesItsPastedImagesBesideIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adopt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fallback = root.appendingPathComponent("Fallback")
        let notes = root.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let pasted = fallback.appendingPathComponent("Pasted image (1).png")
        try Data([0x89, 0x50]).write(to: pasted)
        let defaults = UserDefaults(suiteName: "pf-test-\(UUID().uuidString)")!
        let store = PastedImageStore(defaults: defaults, folderAccess: FolderAccessStore(defaults: defaults),
                                     fallbackFolder: fallback)
        let content = MarkdownContent(documentId: UUID().uuidString)
        content.documentManager.text = "Intro\n\n![Chart](<\(pasted.path)>)\n\nEnd\n"

        content.adoptPastedImages(savedAt: notes.appendingPathComponent("Note.md"), store: store)

        #expect(content.documentManager.text == "Intro\n\n![Chart](<attachments/Pasted image (1).png>)\n\nEnd\n")
        #expect(FileManager.default.fileExists(atPath: notes.appendingPathComponent("attachments/Pasted image (1).png").path))
        #expect(!FileManager.default.fileExists(atPath: pasted.path))
    }

    @Test @MainActor
    func linksOutsideTheFallbackFolderStayPut() throws {
        let defaults = UserDefaults(suiteName: "pf-test-\(UUID().uuidString)")!
        let store = PastedImageStore(defaults: defaults, folderAccess: FolderAccessStore(defaults: defaults),
                                     fallbackFolder: FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID().uuidString)"))
        let content = MarkdownContent(documentId: UUID().uuidString)
        let text = "![a](/Users/someone/pic.png) and ![b](relative.png)\n"
        content.documentManager.text = text
        content.adoptPastedImages(savedAt: URL(fileURLWithPath: "/tmp/Note.md"), store: store)
        #expect(content.documentManager.text == text)
    }
}
