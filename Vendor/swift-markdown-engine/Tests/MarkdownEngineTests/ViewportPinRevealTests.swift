//
//  ViewportPinRevealTests.swift
//  MarkdownEngineTests
//
//  Field report 2026-09-13: editing an equation jumped the view. A rendered
//  block keeps 16 pt of spacing before its image and none before its source,
//  so the caret's line measured 16 pt higher after the reveal and the viewport
//  pin scrolled the whole page by that much — on every click into a formula,
//  and it never came back. These tests drive the real editor: a line above
//  the block must stay exactly where it is while the caret enters the block,
//  types inside it, and leaves again.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@Suite("Viewport pin across a block reveal")
@MainActor
struct ViewportPinRevealTests {
    typealias H = TableOverlayEndToEndTests

    /// Any formula becomes a 220×48 image, so the test needs no math engine.
    private struct FixedSizeLatex: LatexRenderer {
        func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? {
            let size = CGSize(width: 220, height: 48)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.systemBlue.setFill()
                rect.fill()
                return true
            }
            return LatexRenderResult(image: image, size: size, baselineOffset: 12)
        }
    }

    private static let document: String = {
        let prose = (1...40).map { "Paragraph \($0) of the note, long enough to matter." }
        return (prose[0..<20] + ["$$E = mc^2 + \\frac{a}{b}$$"] + prose[20...]).joined(separator: "\n\n")
    }()

    private func settle(_ rounds: Int = 6) async {
        for _ in 0..<rounds {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func findEditor(in view: NSView) -> NativeTextView? {
        if let tv = view as? NativeTextView { return tv }
        for sub in view.subviews { if let found = findEditor(in: sub) { return found } }
        return nil
    }

    private func mount() async -> (NSWindow, NativeTextView)? {
        _ = NSApplication.shared
        var configuration = MarkdownEditorConfiguration.default
        configuration.services.latex = FixedSizeLatex()
        let host = H.Host(text: Self.document)
        let hosting = NSHostingView(rootView: H.EditorHarnessView(host: host, configuration: configuration))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        guard let tv = findEditor(in: hosting) else { return nil }
        return (window, tv)
    }

    /// Window y of the paragraph holding `location`; nil until it is laid out.
    private func screenY(of location: Int, in textView: NSTextView) -> CGFloat? {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager,
              let textLocation = tcm.location(tcm.documentRange.location, offsetBy: location),
              let fragment = tlm.textLayoutFragment(for: textLocation),
              fragment.state == .layoutAvailable else { return nil }
        let frame = fragment.layoutFragmentFrame.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        return textView.convert(frame, to: nil).origin.y
    }

    /// Scrolls so the block sits mid-viewport and returns the start of the block
    /// and of the paragraph two above it (the probe).
    private func centreBlock(in textView: NativeTextView) async -> (block: Int, probe: Int)? {
        let ns = textView.string as NSString
        let block = ns.range(of: "$$E").location
        let probe = ns.range(of: "Paragraph 18 ").location
        guard let scrollView = textView.enclosingScrollView else { return nil }
        textView.scrollRangeToVisible(NSRange(location: block, length: 0))
        await settle()
        guard let y = screenY(of: block, in: textView) else { return nil }
        let current = textView.convert(NSPoint(x: 0, y: y), from: nil).y
        let target = textView.visibleRect.midY
        let origin = scrollView.contentView.bounds.origin
        scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: max(0, origin.y + (current - target))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        await settle()
        return (block, probe)
    }

    @Test("entering, editing and leaving a rendered block never moves the lines above it")
    func revealKeepsTheLinesAboveStill() async throws {
        let (window, tv) = try #require(await mount())
        defer { window.orderOut(nil) }
        let (block, probe) = try #require(await centreBlock(in: tv))
        let start = try #require(screenY(of: probe, in: tv))
        let storage = try #require(tv.textStorage)
        let paragraph = (tv.string as NSString).paragraphRange(for: NSRange(location: block, length: 0))
        func isRendered() -> Bool {
            var found = false
            storage.enumerateAttribute(.renderedBlockImage, in: paragraph, options: []) { value, _, stop in
                if value != nil { found = true; stop.pointee = true }
            }
            return found
        }
        // The block is rendered before the caret enters it.
        #expect(isRendered())

        tv.setSelectedRange(NSRange(location: block + 2, length: 0))
        await settle()
        #expect(!isRendered(), "caret inside reveals the source")
        #expect(abs(try #require(screenY(of: probe, in: tv)) - start) < 0.5, "enter moved the line above")

        for _ in 0..<3 {
            tv.insertText("x", replacementRange: tv.selectedRange())
            await settle(2)
            #expect(abs(try #require(screenY(of: probe, in: tv)) - start) < 0.5, "typing moved the line above")
        }

        tv.setSelectedRange(NSRange(location: probe, length: 0))
        await settle()
        #expect(isRendered(), "caret outside renders again")
        #expect(abs(try #require(screenY(of: probe, in: tv)) - start) < 0.5, "leaving moved the line above")
    }
}
