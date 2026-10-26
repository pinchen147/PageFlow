//
//  DeferredRestyleTests.swift
//  MarkdownEngineTests
//
//  A whole-document format (⌘A then ⌘B) styles the screen in the same turn and
//  the rest of the note in idle passes. These tests drive the real editor in a
//  window: the visible paragraph is bold at once, a paragraph far below is not
//  until the run loop has turned, everything is consistent afterwards, and a
//  keystroke landing while passes are pending neither corrupts the text nor
//  leaves a paragraph unstyled.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@Suite("Viewport-first restyle after a whole-document format")
@MainActor
struct DeferredRestyleTests {
    typealias H = TableOverlayEndToEndTests

    private static let paragraphCount = 400
    private static let document = (1...paragraphCount)
        .map { "Paragraph \($0) of a long note with `code`, a [link](https://x.y/\($0)) and *emphasis* to style." }
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

    private func mount() async -> (NSWindow, NativeTextView, NativeTextViewCoordinator)? {
        _ = NSApplication.shared
        let host = H.Host(text: Self.document)
        let hosting = NSHostingView(rootView: H.EditorHarnessView(host: host, configuration: .default))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        guard let tv = findEditor(in: hosting), let coordinator = tv.delegate as? NativeTextViewCoordinator else { return nil }
        return (window, tv, coordinator)
    }

    /// Whether the word "Paragraph" of paragraph `n` carries a bold font.
    private func isBold(paragraph n: Int, in tv: NativeTextView) -> Bool {
        let ns = tv.string as NSString
        let marker = ns.range(of: "Paragraph \(n) ")
        guard marker.location != NSNotFound, let storage = tv.textStorage else { return false }
        let font = storage.attribute(.font, at: marker.location + 2, effectiveRange: nil) as? NSFont
        return font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
    }

    @Test("the screen is styled in the edit's turn, the rest after the run loop turns")
    func viewportFirstThenTheRest() async throws {
        let (window, tv, coordinator) = try #require(await mount())
        defer { window.orderOut(nil) }
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        coordinator.didMarkdownBold(nil)

        // Same turn: the top of the note (on screen) is bold; the far end is queued.
        #expect(isBold(paragraph: 1, in: tv))
        #expect(!coordinator.deferredRestyleRanges.isEmpty, "the off-screen remainder is queued")
        #expect(!isBold(paragraph: Self.paragraphCount, in: tv), "the far end waits for an idle pass")

        await settle(20)
        #expect(coordinator.deferredRestyleRanges.isEmpty, "every queued chunk was styled")
        for n in [1, 50, 200, Self.paragraphCount] { #expect(isBold(paragraph: n, in: tv), "paragraph \(n)") }
        #expect(tv.string.hasPrefix("**Paragraph 1 "))
    }

    @Test("a keystroke while passes are pending keeps the text and the styling right")
    func typingDuringPendingPasses() async throws {
        let (window, tv, coordinator) = try #require(await mount())
        defer { window.orderOut(nil) }
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        coordinator.didMarkdownBold(nil)
        #expect(!coordinator.deferredRestyleRanges.isEmpty)

        // Type at the very top: everything queued shifts by one character.
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.insertText("Z", replacementRange: NSRange(location: 0, length: 0))
        await settle(20)

        #expect(coordinator.deferredRestyleRanges.isEmpty)
        #expect(tv.string.hasPrefix("Z**Paragraph 1 "))
        for n in [2, 200, Self.paragraphCount] { #expect(isBold(paragraph: n, in: tv), "paragraph \(n)") }
    }

    @Test("a second ⌘A ⌘B toggles the whole note back off, viewport-first as well")
    func toggleOffIsViewportFirstToo() async throws {
        let (window, tv, coordinator) = try #require(await mount())
        defer { window.orderOut(nil) }
        for _ in 0..<2 {
            tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
            coordinator.didMarkdownBold(nil)
            await settle(20)
        }
        #expect(tv.string == Self.document)
        for n in [1, 200, Self.paragraphCount] { #expect(!isBold(paragraph: n, in: tv), "paragraph \(n)") }
    }

    /// Window y of the paragraph holding `location`, nil until laid out.
    private func screenY(of location: Int, in textView: NSTextView) -> CGFloat? {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager,
              let textLocation = tcm.location(tcm.documentRange.location, offsetBy: location),
              let fragment = tlm.textLayoutFragment(for: textLocation), fragment.state == .layoutAvailable else { return nil }
        let frame = fragment.layoutFragmentFrame.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        return textView.convert(frame, to: nil).origin.y
    }

    @Test("the top visible line stays put through the edit and every idle pass, at the top and mid-note")
    func topLineIsStillThroughAllPasses() async throws {
        let (window, tv, coordinator) = try #require(await mount())
        defer { window.orderOut(nil) }
        for target in [1, 180] {
            let ns = tv.string as NSString
            tv.scrollRangeToVisible(NSRange(location: ns.range(of: "Paragraph \(target) ").location, length: 0))
            await settle()
            guard let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager,
                  let viewport = tlm.textViewportLayoutController.viewportRange else { continue }
            // The first paragraph whose top is inside the viewport is the probe; it is
            // identified by its number because the edit moves every character offset.
            let top = tcm.offset(from: tcm.documentRange.location, to: viewport.location)
            // The viewport can start on the blank line between paragraphs; walk to
            // the first numbered one.
            var probeRange = ns.paragraphRange(for: NSRange(location: top, length: 0))
            while !ns.substring(with: probeRange).contains("Paragraph "), NSMaxRange(probeRange) < ns.length {
                probeRange = ns.paragraphRange(for: NSRange(location: NSMaxRange(probeRange), length: 0))
            }
            let words = ns.substring(with: probeRange).split(separator: " ")
            let probeNumber = try #require(words.count > 1 ? Int(words[1].filter(\.isNumber)) : nil)
            let before = try #require(screenY(of: probeRange.location, in: tv))

            tv.setSelectedRange(NSRange(location: 0, length: ns.length))
            coordinator.didMarkdownBold(nil)
            // The reader's line, not the scroll origin, is the invariant: on a
            // long note the chain above is estimated, and the pins move the
            // origin as passes replace those estimates (ADR-0020).
            for _ in 0..<12 {
                await settle(2)
                let probeNow = (tv.string as NSString).range(of: "Paragraph \(probeNumber) ").location
                if let now = screenY(of: probeNow, in: tv) {
                    #expect(abs(now - before) < 0.5, "the top line moved \(now - before)pt while passes ran (target \(target))")
                }
            }
            #expect(coordinator.deferredRestyleRanges.isEmpty)
            let probeNow = (tv.string as NSString).range(of: "Paragraph \(probeNumber) ").location
            let after = try #require(screenY(of: probeNow, in: tv))
            #expect(abs(after - before) < 0.5, "the top line moved \(after - before)pt (target \(target))")

            // Toggle back off for the next target.
            tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
            coordinator.didMarkdownBold(nil)
            await settle(20)
        }
    }

    @Test("splitting styles everything through the viewport now and queues only what is below")
    func splitGeometry() {
        let text = (1...100).map { "p\($0)" }.joined(separator: "\n") as NSString   // ~400 chars
        let (_, _, coordinator) = (0, 0, NativeTextViewCoordinator(
            text: .constant(""), fontName: "Helvetica", fontSize: 14,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil))
        let span = NSRange(location: 0, length: text.length)
        let split = coordinator.splitViewportFirst(span: span, viewport: NSRange(location: 200, length: 20), in: text)
        // The margin (6 000) dwarfs this text: everything is "now", nothing is queued.
        #expect(split.now == span)
        #expect(split.later.isEmpty)

        let long = String(repeating: "paragraph of some length\n", count: 2_000) as NSString   // 50 000 chars
        let wide = NSRange(location: 0, length: long.length)
        let mid = coordinator.splitViewportFirst(span: wide, viewport: NSRange(location: 25_000, length: 1_000), in: long)
        #expect(mid.now.location == 0, "everything above the viewport is styled now")
        #expect(NSMaxRange(mid.now) >= 26_000 + NativeTextViewCoordinator.deferredRestyleMargin)
        #expect(mid.later.count == 1)
        #expect(mid.later[0].location == NSMaxRange(mid.now), "only the range below the viewport is queued")
        #expect(mid.later[0].length + mid.now.length == long.length)
    }

    @Test("queued ranges follow an edit: shifted after it, stretched over it, untouched before it")
    func queuedRangesFollowEdits() {
        let coordinator = NativeTextViewCoordinator(
            text: .constant(""), fontName: "Helvetica", fontSize: 14,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil)
        coordinator.deferredRestyleRanges = [NSRange(location: 0, length: 100), NSRange(location: 300, length: 100), NSRange(location: 600, length: 100)]
        // Insert 5 characters at 320 (inside the middle range).
        coordinator.shiftDeferredRestyle(edited: NSRange(location: 320, length: 5), delta: 5)
        #expect(coordinator.deferredRestyleRanges == [NSRange(location: 0, length: 100), NSRange(location: 300, length: 105), NSRange(location: 605, length: 100)])
        // Delete 10 characters that were at 150..<160 (between ranges).
        coordinator.shiftDeferredRestyle(edited: NSRange(location: 150, length: 0), delta: -10)
        #expect(coordinator.deferredRestyleRanges == [NSRange(location: 0, length: 100), NSRange(location: 290, length: 105), NSRange(location: 595, length: 100)])
    }

    @Test("an edit through the text view shifts queued passes by its real length")
    func textViewEditShiftsQueuedRanges() async throws {
        let (window, tv, coordinator) = try #require(await mount())
        defer { window.orderOut(nil) }
        let length = (tv.string as NSString).length
        let tail = NSRange(location: length - 200, length: 200)
        coordinator.deferredRestyleRanges = [tail]
        let inserted = "Inserted words. "
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.insertText(inserted, replacementRange: NSRange(location: 0, length: 0))
        let delta = (inserted as NSString).length
        #expect(coordinator.deferredRestyleRanges == [NSRange(location: tail.location + delta, length: tail.length)])
    }
}
