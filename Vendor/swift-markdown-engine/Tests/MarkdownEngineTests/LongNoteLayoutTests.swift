//
//  LongNoteLayoutTests.swift
//  MarkdownEngineTests
//
//  A long note is never laid out whole (ADR-0020, D12): TextKit 2 takes about
//  a second per megabyte for it, and the editor froze at every open, resize,
//  zoom, typing pause and Find. Mounting, measuring, zooming, a far scroll and
//  a Find jump each lay out about a screen of it, and the jump lands its target
//  on screen. A short note keeps its exact whole-note layout.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@Suite("Long-note layout", .serialized)
@MainActor
struct LongNoteLayoutTests {
    typealias H = TableOverlayEndToEndTests

    private static func note(paragraphs: Int) -> String {
        (1...paragraphs)
            .map { "Paragraph \($0) with `code`, a [link](https://x.y/\($0)) and *emphasis*, long enough to wrap onto a second line at eight hundred points wide." }
            .joined(separator: "\n\n")
    }

    private func findEditor(in view: NSView) -> NativeTextView? {
        if let tv = view as? NativeTextView { return tv }
        for sub in view.subviews { if let found = findEditor(in: sub) { return found } }
        return nil
    }

    private func mount(_ text: String, configuration: MarkdownEditorConfiguration = .default) -> (NSWindow, NativeTextView)? {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: H.EditorHarnessView(host: H.Host(text: text), configuration: configuration))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        guard let tv = findEditor(in: hosting) else { return nil }
        return (window, tv)
    }

    /// The share of the note's paragraphs from `offset` on that TextKit has
    /// laid out (not estimated).
    private func laidOutShare(_ tv: NativeTextView, from offset: Int = 0) -> Double {
        guard let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager,
              let start = tcm.location(tcm.documentRange.location, offsetBy: offset) else { return 0 }
        var laidOut = 0, total = 0
        tlm.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            total += 1
            if fragment.state == .layoutAvailable { laidOut += 1 }
            return true
        }
        return total == 0 ? 0 : Double(laidOut) / Double(total)
    }

    /// Pumps the run loop until the open's deferred restyle has drained.
    private func settle(_ tv: NativeTextView) {
        let coordinator = tv.delegate as? NativeTextViewCoordinator
        for _ in 0..<2_000 where coordinator?.deferredRestyleRanges.isEmpty == false {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    @Test("mounting a long note lays out about a screen of it")
    func longNoteMountsWithoutAWholeNoteLayout() throws {
        let (window, tv) = try #require(mount(Self.note(paragraphs: 2_000)))
        defer { window.orderOut(nil) }
        #expect(tv.prefersEstimatedLayoutChain)
        let share = laidOutShare(tv)
        #expect(share < 0.2, "the mount laid out \(Int(share * 100))% of the note")
    }

    @Test("an exact height measure on a long note does not lay it out whole")
    func exactMeasureStaysInTheEstimatedChain() throws {
        let (window, tv) = try #require(mount(Self.note(paragraphs: 2_000)))
        defer { window.orderOut(nil) }
        let scrollView = try #require(tv.enclosingScrollView)
        settle(tv)
        tv.recalcOverscroll(for: scrollView)   // a resize or a pause after typing
        let share = laidOutShare(tv)
        #expect(share < 0.2, "the measure laid out \(Int(share * 100))% of the note")
        #expect(tv.baseContentHeight > scrollView.contentView.bounds.height * 10, "the estimated height collapsed")
    }

    @Test("a zoom settle on a long note does not lay it out whole")
    func zoomSettleStaysInTheEstimatedChain() throws {
        let (window, tv) = try #require(mount(Self.note(paragraphs: 2_000)))
        defer { window.orderOut(nil) }
        let scrollView = try #require(tv.enclosingScrollView)
        settle(tv)
        scrollView.magnification = 1.25
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))   // past the settle debounce
        let share = laidOutShare(tv)
        #expect(share < 0.2, "the zoom settle laid out \(Int(share * 100))% of the note")
    }

    @Test("a far scroll on a long note lays out about a screen of it")
    func farScrollLaysOutAScreen() throws {
        let (window, tv) = try #require(mount(Self.note(paragraphs: 2_000)))
        defer { window.orderOut(nil) }
        let scrollView = try #require(tv.enclosingScrollView)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: tv.frame.height * 0.8))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let share = laidOutShare(tv)
        #expect(share < 0.2, "the scroll laid out \(Int(share * 100))% of the note")
    }

    @Test("Find on a long note lands a far match on screen without laying out the note")
    func findRevealsAFarMatchOnALongNote() throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.readingWidth = 640   // the app's page column
        let (window, tv) = try #require(mount(Self.note(paragraphs: 2_000), configuration: configuration))
        defer { window.orderOut(nil) }
        let coordinator = try #require(tv.delegate as? NativeTextViewCoordinator)
        let scrollView = try #require(tv.enclosingScrollView)
        let match = (tv.string as NSString).range(of: "Paragraph 1900 ")
        coordinator.handleFindScrollToRange(Notification(
            name: Notification.Name("test.findScroll"), object: coordinator.documentId,
            userInfo: ["range": match, "currentIndex": 0, "allRanges": [match]]
        ))
        let share = laidOutShare(tv)
        #expect(share < 0.2, "Find laid out \(Int(share * 100))% of the note")

        let tlm = try #require(tv.textLayoutManager)
        tlm.textViewportLayoutController.layoutViewport()
        let location = try #require(tlm.textContentManager?.location(tlm.documentRange.location, offsetBy: match.location))
        let fragment = try #require(tlm.textLayoutFragment(for: location))
        let frame = fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: tv.frame.origin.y)
        let clip = scrollView.contentView.bounds
        #expect(frame.minY >= clip.minY && frame.maxY <= clip.maxY,
                "the match at \(frame.minY) is off screen (\(clip.minY)–\(clip.maxY))")
    }

    /// A long note with every rendered block kind: wide tables, block math, code.
    private static func richNote(sections: Int) -> String {
        (1...sections).map { n in
            """
            ## Section \(n)

            Prose with *emphasis*, `code` and a [link](https://x.y/\(n)) that wraps at the column width.

            | a | b | c | d | e | f | g | h | i | j | k | l |
            | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
            | \(n) | wide | table | cells | that | do | not | fit | the | page | column | here |

            $$x_{\(n)} = \\frac{a}{b}$$

            ```swift
            let value\(n) = \(n)
            ```
            """
        }.joined(separator: "\n\n")
    }

    @Test("a long rich note past the background-parse threshold mounts at once without a whole-note layout")
    func richLongNoteMountsAtOnce() throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.readingWidth = 640
        let start = Date()
        let (window, tv) = try #require(mount(Self.richNote(sections: 2_800), configuration: configuration))
        defer { window.orderOut(nil) }
        let elapsed = Date().timeIntervalSince(start)
        print("RICHMOUNT \(String(format: "%.2f", elapsed))s length=\((tv.string as NSString).length)")
        #expect(elapsed < 10, "mounting took \(elapsed) s")
        #expect(laidOutShare(tv) < 0.2)
    }

    @Test("a short note is still laid out whole at mount")
    func shortNoteKeepsTheExactLayout() throws {
        let (window, tv) = try #require(mount(Self.note(paragraphs: 200)))
        defer { window.orderOut(nil) }
        #expect(!tv.prefersEstimatedLayoutChain)
        #expect(laidOutShare(tv) == 1, "the short note was not laid out at mount")
    }
}
