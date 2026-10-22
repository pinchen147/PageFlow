//
//  MarkdownPrintRendererTests.swift
//  MarkdownEngineTests
//
//  PageFlow fork seam (S9 styled-Markdown print). The print view is built
//  THROUGH the engine (the custom layout-fragment delegate draws rendered
//  blocks) from the document's source, styled for paper: nothing revealed as
//  raw markup, every deferred pass run, wide tables scaled to the page. The
//  actual rendered pixels are verified by a live print.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Markdown print renderer (S9 seam)")
struct MarkdownPrintRendererTests {
    private let pageWidth: CGFloat = 468   // US-Letter minus 1in margins

    private func printView(_ source: String) -> NSTextView {
        MarkdownPrintRenderer.makePrintTextView(
            source: source,
            configuration: .default,
            fontName: NSFont.systemFont(ofSize: 16).fontName,
            fontSize: 16,
            baseFont: NSFont.systemFont(ofSize: 16),
            pageWidth: pageWidth
        )
    }

    private func pointSize(of needle: String, in view: NSTextView) -> CGFloat? {
        guard let storage = view.textStorage else { return nil }
        let location = (storage.string as NSString).range(of: needle).location
        guard location != NSNotFound else { return nil }
        return (storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont)?.pointSize
    }

    @Test
    func buildsAnEngineWiredViewThatRetainsItsDelegate() throws {
        let view = printView("# Title\n\nbody")
        let native = try #require(view as? NativeTextView)
        #expect(view.textLayoutManager?.delegate is MarkdownLayoutManagerDelegate)
        #expect(native.printLayoutDelegate === view.textLayoutManager?.delegate as? MarkdownLayoutManagerDelegate)
        #expect(view.textStorage?.string == "# Title\n\nbody")
        #expect(view.frame.height > 0)
        let operation = NSPrintOperation(view: view, printInfo: NSPrintInfo())
        #expect(operation.view === view)
    }

    @Test
    func nothingPrintsAsRawMarkup() throws {
        let view = printView("**bold** text")
        let storage = try #require(view.textStorage)
        // The opening `**` is hidden markup, not ink: the caret reveals nothing on paper.
        let marker = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let markerFont = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(marker == .clear || (markerFont?.pointSize ?? 16) < 2)
    }

    @Test
    func aLongNotePrintsFullyStyled() throws {
        let filler = String(repeating: "Plain paragraph text that fills the note.\n\n", count: 2_000)
        let source = "# First\n\n" + filler + "# Last\n"
        #expect((source as NSString).length > NativeTextViewCoordinator.viewportFirstRebuildThreshold)
        let view = printView(source)
        let first = try #require(pointSize(of: "First", in: view))
        let last = try #require(pointSize(of: "Last", in: view))
        #expect(last == first, "the heading past the deferred threshold is styled like the first")
        #expect(last > 16)
    }

    @Test
    func aWideTablePrintsScaledToThePage() throws {
        let columns = (1...14).map { "Column \($0) header" }
        let source = "| " + columns.joined(separator: " | ") + " |\n|"
            + String(repeating: " --- |", count: columns.count) + "\n| "
            + columns.map { _ in "value" }.joined(separator: " | ") + " |\n"
        let view = printView(source)
        let storage = try #require(view.textStorage)
        var scrollable = false
        var widest: CGFloat = 0
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, _, _ in
            if attributes[.scrollableBlockSourceID] != nil { scrollable = true }
            if attributes[.renderedBlockImage] != nil, let bounds = attributes[.latexBounds] as? NSValue {
                widest = max(widest, bounds.rectValue.width)
            }
        }
        #expect(!scrollable, "paper has no horizontal scroll overlay")
        #expect(widest > 0 && widest <= pageWidth + 0.5)
    }
}
