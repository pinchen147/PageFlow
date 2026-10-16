//
//  DocumentImageProviderTests.swift
//  PageFlowTests
//
//  `![alt](path)` resolution relative to the note's folder, and the one-read
//  cache (hits and misses alike).
//

import AppKit
import Foundation
import Testing
@testable import PageFlow
import MarkdownEngine

struct DocumentImageProviderTests {
    private let folder = URL(fileURLWithPath: "/tmp/pageflow-test/notes", isDirectory: true)
    private var note: URL { folder.appendingPathComponent("note.md") }

    private func provider(url: URL?) -> DocumentImageProvider {
        DocumentImageProvider { url }
    }

    @Test
    func resolvesRelativeToTheNoteFolder() {
        let provider = provider(url: note)
        #expect(provider.resolve("images/a.png")?.path == "/tmp/pageflow-test/notes/images/a.png")
        #expect(provider.resolve("../shared/b.png")?.path == "/tmp/pageflow-test/shared/b.png")
        #expect(provider.resolve("/abs/c.png")?.path == "/abs/c.png")
        #expect(provider.resolve("file:///abs/d.png")?.path == "/abs/d.png")
    }

    /// Titles and `<…>` are the engine's to remove; the provider maps the
    /// decoded destination, spaces and quotes included, to a file.
    @Test
    func mapsDecodedDestinationsAndPercentEscapes() {
        let provider = provider(url: note)
        #expect(provider.resolve("my 'draft'.png")?.lastPathComponent == "my 'draft'.png")
        #expect(provider.resolve("my%20image.png")?.lastPathComponent == "my image.png")
    }

    @Test
    func remoteAndEmptyReferencesResolveToNothing() {
        let provider = provider(url: note)
        #expect(provider.resolve("https://example.com/a.png") == nil)
        #expect(provider.resolve("") == nil)
        #expect(self.provider(url: nil).resolve("a.png") == nil)
        #expect(provider.fingerprint() == AnyHashable("/tmp/pageflow-test/notes"))
    }

    @Test
    func largeImagesDecodeDownsampledSmallOnesAsTheyAre() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pf-img-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func writePNG(_ name: String, width: Int, height: Int) throws {
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent(name))
        }
        try writePNG("big.png", width: 4_000, height: 2_000)
        try writePNG("small.png", width: 300, height: 200)

        let big = try #require(DocumentImageProvider.read(dir.appendingPathComponent("big.png")))
        #expect(big.size.width == CGFloat(DocumentImageProvider.maxDecodedPixels))
        #expect(big.size.height == CGFloat(DocumentImageProvider.maxDecodedPixels) / 2)
        let small = try #require(DocumentImageProvider.read(dir.appendingPathComponent("small.png")))
        #expect(small.size == NSSize(width: 300, height: 200))
    }

    @Test
    func readsAnImageOnceAndRemembersMisses() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pf-img-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: dir.appendingPathComponent("pic.png"))

        let provider = provider(url: dir.appendingPathComponent("note.md"))
        let first = provider.image(for: EmbeddedImageRequest(name: "pic.png"))
        #expect(first != nil)
        #expect(provider.image(for: EmbeddedImageRequest(name: "pic.png")) === first)

        #expect(provider.image(for: EmbeddedImageRequest(name: "missing.png")) == nil)
        try png.write(to: dir.appendingPathComponent("missing.png"))
        #expect(provider.image(for: EmbeddedImageRequest(name: "missing.png")) == nil)  // the miss is remembered
    }
}
