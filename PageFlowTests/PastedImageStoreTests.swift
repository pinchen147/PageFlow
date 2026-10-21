//
//  PastedImageStoreTests.swift
//  PageFlowTests
//
//  The markdown an image becomes when dropped or pasted into a note: files
//  copied beside the note (or linked where they already are), and image
//  data saved there.
//

import AppKit
import Foundation
import Testing
import MarkdownEngine
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

    @Test(arguments: ["chart|300", "draft[final]", "x](y", "back\\slash", "literal%20name", "colon:name", "line\nbreak"])
    func filenamesRemainDescriptionsAndResolveToTheOriginalImage(_ name: String) throws {
        let url = note.deletingLastPathComponent().appendingPathComponent(name + ".png")
        let link = PastedImageStore.link(for: url, documentURL: note)
        let altEnd = try #require(link.range(of: "](", options: .backwards))
        let alt = String(link[link.index(link.startIndex, offsetBy: 2)..<altEnd.lowerBound])
        let metadata = ImageAltTokens.parse(alt)
        #expect(metadata.width == nil && metadata.crop == nil && metadata.alignment == .left)
        #expect(metadata.displayDescription == name.replacingOccurrences(of: "\n", with: ""))
        #expect(!link.contains("\n"))
        var destination = String(link[altEnd.upperBound..<link.index(before: link.endIndex)])
        if destination.hasPrefix("<") { destination = String(destination.dropFirst().dropLast()) }
        let provider = DocumentImageProvider { self.note }
        #expect(provider.resolve(destination) == url)
    }

    @Test @MainActor
    func importedImageDescriptionsAndEncodedFallbackLinksSurviveSaving() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let image = try fixture.png("literal%20name[1]|300.png", in: fixture.outside)
        let imported = fixture.store.importImageFiles([image], documentURL: nil)
        let link = try #require(imported.links.first)
        #expect(link.hasPrefix(#"![literal%20name\[1\]\|300]"#))
        #expect(link.contains("literal%2520name%5B1%5D%7C300.png"))

        let edits = fixture.store.adoptFallbackImages(in: link + "\n\n" + link, savedAt: fixture.note)
        let edit = try #require(edits.first)
        #expect(edits.count == 2)
        #expect(edits.allSatisfy { $0.link == edit.link })
        #expect(edit.link == #"![literal%20name\[1\]\|300](attachments/literal%2520name%5B1%5D%7C300.png)"#)
        #expect(FileManager.default.fileExists(atPath: fixture.notes.appendingPathComponent("attachments/literal%20name[1]|300.png").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.fallback.appendingPathComponent("literal%20name[1]|300.png").path))
    }

    @Test @MainActor
    func onlyImageFilesOnThePasteboardBecomeLinksAndPastedFilesAreCopied() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pf-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()

        pasteboard.writeObjects([fixture.outside.appendingPathComponent("doc.pdf") as NSURL])
        #expect(fixture.store.markdownLinks(for: pasteboard, documentURL: fixture.note) == nil)

        let inside = try fixture.png("a.png", in: fixture.notes)
        let outside = try fixture.png("b.jpeg", in: fixture.outside)
        pasteboard.clearContents()
        pasteboard.writeObjects([inside as NSURL, fixture.outside.appendingPathComponent("doc.pdf") as NSURL, outside as NSURL])
        var reported: [String] = []
        #expect(fixture.store.markdownLinks(for: pasteboard, documentURL: fixture.note, report: { reported.append($0) })
                == "![a](a.png)\n\n![b](attachments/b.jpeg)")
        #expect(reported.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.notes.appendingPathComponent("attachments/b.jpeg").path))

        pasteboard.clearContents()
        pasteboard.writeObjects([fixture.outside.appendingPathComponent("gone.png") as NSURL])
        #expect(fixture.store.markdownLinks(for: pasteboard, documentURL: fixture.note, report: { reported.append($0) }) == nil)
        #expect(reported == ["Couldn’t add “gone.png”. Try again."])
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
    // MARK: - Importing image files (doc 26 §9.2, §9.4)

    /// A folder with a note in it, a store over fresh defaults, and a place
    /// outside the folder for files to come from.
    private struct ImportFixture {
        let root: URL
        let notes: URL
        let outside: URL
        let fallback: URL
        let note: URL
        let store: PastedImageStore

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("pf-import-\(UUID().uuidString)", isDirectory: true)
            notes = root.appendingPathComponent("Notes", isDirectory: true)
            outside = root.appendingPathComponent("Downloads", isDirectory: true)
            fallback = root.appendingPathComponent("Fallback", isDirectory: true)
            for folder in [notes, outside] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            note = notes.appendingPathComponent("note.md")
            let defaults = try #require(UserDefaults(suiteName: "pf-import-\(UUID().uuidString)"))
            store = PastedImageStore(defaults: defaults, folderAccess: FolderAccessStore(defaults: defaults), fallbackFolder: fallback)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        /// A real 2 × 2 PNG at `folder/name`.
        @discardableResult
        func png(_ name: String, in folder: URL) throws -> URL {
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let url = folder.appendingPathComponent(name)
            try #require(rep.representation(using: .png, properties: [:])).write(to: url)
            return url
        }
    }

    @Test @MainActor
    func aFileOutsideTheNoteFolderIsCopiedIntoAttachmentsAndNumberedOnAClash() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let shot = try fixture.png("shot.png", in: fixture.outside)

        let first = fixture.store.importImageFiles([shot], documentURL: fixture.note)
        let second = fixture.store.importImageFiles([shot], documentURL: fixture.note)

        #expect(first.links == ["![shot](attachments/shot.png)"])
        #expect(second.links == ["![shot](<attachments/shot (1).png>)"])
        #expect(first.messages.isEmpty && second.messages.isEmpty)
        let attachments = fixture.notes.appendingPathComponent("attachments")
        #expect(try FileManager.default.contentsOfDirectory(atPath: attachments.path).sorted() == ["shot (1).png", "shot.png"])
        #expect(FileManager.default.fileExists(atPath: shot.path), "the original stays where it was")
    }

    @Test @MainActor
    func aFileInsideTheNoteFolderIsLinkedInPlace() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let pics = fixture.notes.appendingPathComponent("pics", isDirectory: true)
        try FileManager.default.createDirectory(at: pics, withIntermediateDirectories: true)
        let inside = try fixture.png("in.png", in: pics)

        let imported = fixture.store.importImageFiles([inside], documentURL: fixture.note)

        #expect(imported.links == ["![in](pics/in.png)"])
        #expect(!FileManager.default.fileExists(atPath: fixture.notes.appendingPathComponent("attachments").path),
                "nothing was copied")
    }

    @Test @MainActor
    func anUntitledNoteCopiesIntoTheFallbackFolderAndAdoptsOnSave() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let shot = try fixture.png("shot.png", in: fixture.outside)

        let imported = fixture.store.importImageFiles([shot], documentURL: nil)
        let copy = fixture.fallback.appendingPathComponent("shot.png")
        #expect(imported.links == ["![shot](\(copy.standardizedFileURL.path))"])
        #expect(FileManager.default.fileExists(atPath: copy.path))

        let content = MarkdownContent(documentId: UUID().uuidString)
        content.documentManager.text = "Intro\n\n\(imported.links[0])\n"
        content.adoptPastedImages(savedAt: fixture.note, store: fixture.store)
        #expect(content.documentManager.text == "Intro\n\n![shot](attachments/shot.png)\n")
        #expect(FileManager.default.fileExists(atPath: fixture.notes.appendingPathComponent("attachments/shot.png").path))
        #expect(!FileManager.default.fileExists(atPath: copy.path))
    }

    @Test @MainActor
    func limitsRejectLargeEmptyAndVectorFilesAndCapTheCount() throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let large = fixture.outside.appendingPathComponent("large.png")
        #expect(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(21 * 1024 * 1024))
        try handle.close()
        let empty = fixture.outside.appendingPathComponent("empty.png")
        #expect(FileManager.default.createFile(atPath: empty.path, contents: Data()))
        let vector = fixture.outside.appendingPathComponent("logo.svg")
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8).write(to: vector)

        let rejected = fixture.store.importImageFiles([large, empty, vector], documentURL: fixture.note)
        #expect(rejected.links.isEmpty)
        #expect(rejected.messages == [
            "“large.png” is too large to add (20 MB max).",
            "“empty.png” is empty.",
            "“logo.svg” isn’t a supported image. Use a PNG, JPEG, GIF, WebP, HEIC or TIFF file.",
        ])
        #expect(rejected.message == "“large.png” is too large to add (20 MB max). (2 more not added)")

        let many = try (0..<21).map { try fixture.png("p\($0).png", in: fixture.outside) }
        let capped = fixture.store.importImageFiles(many, documentURL: fixture.note)
        #expect(capped.links.count == 20)
        #expect(capped.links.first == "![p0](attachments/p0.png)" && capped.links.last == "![p19](attachments/p19.png)")
        #expect(capped.messages == ["Only the first 20 images were added."])
    }

    @Test(arguments: [false, true]) @MainActor
    func anImportSurvivesSaveAsBeforeDelivery(initiallyUntitled: Bool) async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let shot = try fixture.png("shot.png", in: fixture.outside)
        let manager = MarkdownDocumentManager()
        defer { manager.close() }
        if !initiallyUntitled {
            try Data("Note\n".utf8).write(to: fixture.note)
            try manager.load(from: fixture.note)
        }
        let destination = fixture.outside.appendingPathComponent("saved.md")
        let imported = await withCheckedContinuation { continuation in
            fixture.store.importImages([shot], data: nil, documentURL: { manager.documentURL }) { result in
                continuation.resume(returning: result)
            }
            // Delivery is queued on main, so this real Save As completes first.
            #expect(manager.saveAsSync(to: destination))
        }
        let link = try #require(imported.links.first)
        let opener = try #require(link.range(of: "](", options: .backwards))
        var target = String(link[opener.upperBound..<link.index(before: link.endIndex)])
        if target.hasPrefix("<") { target = String(target.dropFirst().dropLast()) }
        let savedURL = manager.documentURL
        let provider = DocumentImageProvider { savedURL }
        let resolved = try #require(provider.resolve(target))
        #expect(FileManager.default.fileExists(atPath: resolved.path), "the delivered image must resolve beside the saved note")
        #expect(try Data(contentsOf: resolved) == Data(contentsOf: shot))
        #expect(imported.messages.isEmpty)
    }

    @Test @MainActor
    func aDropCopiesOffTheMainThreadAndAnswersOnIt() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let shot = try fixture.png("shot.png", in: fixture.outside)
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus(); NSColor.green.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let data = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))

        let imported = await withCheckedContinuation { continuation in
            fixture.store.importImages([shot], data: data, documentURL: { fixture.note }) { result in
                #expect(Thread.isMainThread)
                continuation.resume(returning: result)
            }
        }
        #expect(imported.links.count == 2)
        #expect(imported.links.first == "![shot](attachments/shot.png)")
        #expect(imported.links.last?.hasPrefix("![Pasted image ") == true)
        #expect(imported.links.last?.contains("](<attachments/Pasted image ") == true)
        #expect(imported.messages.isEmpty)
    }
}
