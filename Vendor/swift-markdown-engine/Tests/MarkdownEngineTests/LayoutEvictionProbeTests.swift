//
//  LayoutEvictionProbeTests.swift
//  MarkdownEngineTests
//
//  What a one-character edit does to the laid-out fragments ABOVE the
//  viewport on a long note. On a plain note at magnification 1 TextKit 2
//  keeps every fragment; the same edit under magnification (and on a real
//  490 KB note at magnification 1) throws all but a few dozen back to
//  estimates at the next viewport pass, which is why the editor never forces
//  whole-note layout past `NativeTextView.estimatedLayoutChainThreshold`.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@Suite("Layout eviction probe")
@MainActor
struct LayoutEvictionProbeTests {
    typealias H = TableOverlayEndToEndTests

    private static let paragraphCount = 3000
    private static let document = (1...paragraphCount)
        .map { $0 % 100 == 50
            ? "Paragraph \($0) math\n\n$$V_{\($0)} = \\sum_{t=1}^{\\infty} \\frac{E_t}{(1+r)^t}$$"
            : "Paragraph \($0) of a long note with `code`, a [link](https://x.y/\($0)) and *emphasis* to style, long enough to wrap onto a second line at eight hundred points wide." }
        .joined(separator: "\n\n")

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

    /// A long fixture opens viewport-first; its deferred chunks restyle (and so
    /// invalidate) the rest of the note for a few seconds after mount. The
    /// probes measure a quiet note, so wait for the queue to drain.
    private func drainDeferredRestyle(_ tv: NativeTextView) async {
        guard let coordinator = tv.delegate as? NativeTextViewCoordinator else { return }
        for _ in 0..<400 where !coordinator.deferredRestyleRanges.isEmpty {
            await settle(1)
        }
    }

    private func mount() async -> (NSWindow, NativeTextView)? {
        _ = NSApplication.shared
        let host = H.Host(text: Self.document)
        let hosting = NSHostingView(rootView: H.EditorHarnessView(host: host, configuration: .default))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        guard let tv = findEditor(in: hosting) else { return nil }
        return (window, tv)
    }

    /// Document-space top of the paragraph at `loc` (laid out if needed).
    private func fragmentY(_ tv: NativeTextView, _ loc: Int) -> CGFloat {
        guard let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager,
              let location = tcm.location(tcm.documentRange.location, offsetBy: loc) else { return .nan }
        tlm.ensureLayout(for: NSTextRange(location: location))
        return tlm.textLayoutFragment(for: location)?.layoutFragmentFrame.minY ?? .nan
    }

    /// (laid-out, total) fragments from the document start up to `loc`, without forcing layout.
    private func census(_ tv: NativeTextView, upTo loc: Int) -> (Int, Int) {
        guard let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager,
              let end = tcm.location(tcm.documentRange.location, offsetBy: loc) else { return (0, 0) }
        var laidOut = 0, total = 0
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) { fragment in
            if fragment.rangeInElement.location.compare(end) != .orderedAscending { return false }
            total += 1
            if fragment.state == .layoutAvailable { laidOut += 1 }
            return true
        }
        return (laidOut, total)
    }

    /// A note styled in one pass at mount kept every fragment through a
    /// keystroke; a note that opened viewport-first (its remainder restyled by
    /// deferred chunks) has those fragments purged at the keystroke's viewport
    /// pass instead — TextKit keeps the measured heights either way, so the
    /// document height and the block's position hold.
    @Test("at magnification 1 a keystroke inside a formula keeps the measured heights above the viewport")
    func plainNoteKeepsItsLayout() async throws {
        let (window, tv) = try #require(await mount())
        defer { window.orderOut(nil) }
        let ns = tv.string as NSString
        let block = ns.range(of: "$$V_{1550}").location
        tv.scrollRangeToVisible(NSRange(location: block, length: 0))
        await settle(4)
        await drainDeferredRestyle(tv)
        let tlm = try #require(tv.textLayoutManager)
        // Pinned, as the engine's own full layouts are: the far reveal leaves
        // the chain above estimated, and replacing those estimates unpinned
        // would move the block off screen before the keystroke.
        tv.preservingViewportAnchor { tlm.ensureLayout(for: tlm.documentRange) }
        await settle(2)
        let before = census(tv, upTo: block)
        #expect(before.0 == before.1 && before.1 > 1000, "the full layout laid out the note above the viewport: \(before)")
        let heightBefore = tlm.usageBoundsForTextContainer.height
        let blockYBefore = fragmentY(tv, block)

        tv.setSelectedRange(NSRange(location: block + 2, length: 0))
        await settle(2)
        tv.insertText("x", replacementRange: NSRange(location: block + 2, length: 0))
        tlm.textViewportLayoutController.layoutViewport()
        await settle(2)
        let after = census(tv, upTo: block)
        print("EVICTION plain: \(before) → \(after) docH \(heightBefore) → \(tlm.usageBoundsForTextContainer.height)")
        #expect(abs(tlm.usageBoundsForTextContainer.height - heightBefore) < 64,
                "the keystroke changed the document height by \(tlm.usageBoundsForTextContainer.height - heightBefore)pt")
        #expect(abs(fragmentY(tv, block) - blockYBefore) < 64,
                "the block moved \(fragmentY(tv, block) - blockYBefore)pt in document space")
    }

    @Test("under magnification the same keystroke throws the note above the viewport back to estimates")
    func magnifiedNoteIsPurged() async throws {
        let (window, tv) = try #require(await mount())
        defer { window.orderOut(nil) }
        let ns = tv.string as NSString
        let block = ns.range(of: "$$V_{1550}").location
        tv.scrollRangeToVisible(NSRange(location: block, length: 0))
        await settle(4)
        await drainDeferredRestyle(tv)
        tv.enclosingScrollView?.magnification = 1.25
        await settle(24)   // past the zoom refit
        let tlm = try #require(tv.textLayoutManager)
        tv.preservingViewportAnchor { tlm.ensureLayout(for: tlm.documentRange) }   // see above
        await settle(2)
        let before = census(tv, upTo: block)
        let heightBefore = tlm.usageBoundsForTextContainer.height
        tv.setSelectedRange(NSRange(location: block + 2, length: 0))
        await settle(2)
        tv.insertText("x", replacementRange: NSRange(location: block + 2, length: 0))
        tlm.textViewportLayoutController.layoutViewport()
        let after = census(tv, upTo: block)
        print("EVICTION magnified: \(before) → \(after) docH \(heightBefore) → \(tlm.usageBoundsForTextContainer.height)")
        // The measured heights survive the purge: the document height holds.
        #expect(abs(tlm.usageBoundsForTextContainer.height - heightBefore) < 64,
                "the purge changed the document height by \(tlm.usageBoundsForTextContainer.height - heightBefore)pt")
    }
}
