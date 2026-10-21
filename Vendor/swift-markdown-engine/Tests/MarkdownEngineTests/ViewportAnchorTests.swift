//
//  ViewportAnchorTests.swift
//  MarkdownEngineTests
//
//  Field report 2026-07-03: "clicking around causes jumping view" and
//  "⌘U/B/I causes my view to jump around". Root cause: banded-block
//  reveal/collapse (wide table ⇄ raw source, a multi-hundred-point height
//  change) and format-toggle restyles reflowed the document under a FIXED
//  scroll offset — no viewport anchoring existed. The fix pins the caret
//  (when visible; else the first visible character) across such restyles
//  (restylePreservingViewport). These tests assert user-visible content
//  stays put through the exact field sequences.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Viewport anchoring", .serialized)
struct ViewportAnchorTests {
    typealias H = TableOverlayEndToEndTests

    static let pinMarker = "PINPOINT-UNIQUE-LINE"

    static let doc: String = {
        var lines: [String] = ["# Anchor fixture", ""]
        lines += (0..<8).map { "Intro prose line \($0) with steady text." }
        lines.append("")
        lines.append("| 报告 | 一次评审结果说明较长 | 二次评审结果说明较长 | 三次评审结果说明较长 | 四次评审结果说明较长 | 趋势与主要变化原因说明列 |")
        lines.append("| --- | ---: | ---: | ---: | ---: | --- |")
        for row in 0..<5 {
            lines.append("| report\(row).pdf | 9\(row) | 9\(row) | 9\(row) | 9\(row) | 逐页重读 PDF 与 tex 源码后确认质量, 无需调整, 说明文字加长以保证表格超宽 |")
        }
        lines.append("")
        lines += (0..<10).map { "Middle prose line \($0) sits between the table and the pin." }
        lines.append("")
        // A LONG heading that wraps in the 700pt column: revealing its `## `
        // markers changes the used width, so caret-in/out changes its wrap
        // count — the non-banded height-delta class from the field report
        // ("jumping when I click on headers").
        lines.append("## 各报告主要结果汇总与跨报告共性问题的详细比较说明以及后续复核步骤的完整安排记录")
        lines.append("")
        // One long single-line paragraph ABOVE the pin: format markers change
        // its wrap count, so a select-all toggle produces a real height delta
        // above the pin — keeps the bold anchoring test discriminating.
        lines.append("WRAPLINE " + Array(repeating: "long wrapping prose keeps flowing here", count: 12).joined(separator: " "))
        lines.append(pinMarker)
        lines += (0..<40).map { "Tail prose line \($0) keeps the document scrollable." }
        return lines.joined(separator: "\n")
    }()

    private func configuration() -> MarkdownEditorConfiguration {
        var configuration = MarkdownEditorConfiguration.default
        configuration.readingWidth = 700
        configuration.textInsets = TextInsets(horizontal: 24, vertical: 0)
        configuration.safeAreaInsets = SafeAreaInsets(top: 90, leading: 0, trailing: 0, bottom: 0)
        return configuration
    }

    private func settle(_ rounds: Int = 8) async {
        for _ in 0..<rounds {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func findEditor(in view: NSView) -> NativeTextView? {
        if let tv = view as? NativeTextView { return tv }
        for sub in view.subviews {
            if let found = findEditor(in: sub) { return found }
        }
        return nil
    }

    private func mount() async -> (NSWindow, NativeTextView, NativeTextViewCoordinator)? {
        _ = NSApplication.shared
        let host = H.Host(text: Self.doc)
        let hosting = NSHostingView(rootView: H.EditorHarnessView(
            host: host, configuration: configuration()
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        guard let tv = findEditor(in: hosting),
              let coordinator = tv.delegate as? NativeTextViewCoordinator else { return nil }
        return (window, tv, coordinator)
    }

    /// Viewport-relative Y of the pin marker's first character; nil when the
    /// marker is unmeasurable. Content-addressed (not location-addressed) so
    /// marker insertions above it don't skew the reading. Measured purely in
    /// text-view document coordinates (bridge rect + textContainerOrigin vs
    /// visibleRect) — the same single-space math the anchoring helper uses.
    private func documentY(of location: Int, _ tv: NativeTextView, _ coordinator: NativeTextViewCoordinator) -> CGFloat? {
        guard let bridge = coordinator.layoutBridge,
              let container = bridge.firstTextContainer else { return nil }
        let rect = bridge.boundingRect(forCharacterRange: NSRange(location: location, length: 1), in: container)
        guard rect.height >= 0.01 else { return nil }
        return rect.minY + tv.textContainerOrigin.y
    }

    private func pinViewportY(_ tv: NativeTextView, coordinator: NativeTextViewCoordinator) -> CGFloat? {
        let ns = tv.string as NSString
        let range = ns.range(of: Self.pinMarker)
        guard range.location != NSNotFound,
              let docY = documentY(of: range.location, tv, coordinator) else { return nil }
        return docY - tv.visibleRect.minY
    }

    /// Scrolls so the character at `location` sits ~300pt below the viewport
    /// top (delta-form clip scroll — coordinate-space safe in breakout mode).
    private func scrollTo(location: Int, _ tv: NativeTextView, _ coordinator: NativeTextViewCoordinator) {
        guard let docY = documentY(of: location, tv, coordinator),
              let scrollView = tv.enclosingScrollView else { return }
        let delta = (docY - 300) - tv.visibleRect.minY
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + delta))
        scrollView.reflectScrolledClipView(clip)
    }

    private func fireSelectionChange(_ coordinator: NativeTextViewCoordinator, _ tv: NativeTextView) {
        coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: tv)
        )
    }

    @Test("half-point native scroll changes cannot accumulate across pinned transactions")
    func halfPointScrollCorrection() async throws {
        let (window, tv, coordinator) = try #require(await mount())
        defer { window.orderOut(nil) }
        let pin = (tv.string as NSString).range(of: Self.pinMarker)
        tv.setSelectedRange(NSRange(location: pin.location, length: 0))
        fireSelectionChange(coordinator, tv)
        await settle(2)
        scrollTo(location: pin.location, tv, coordinator)
        await settle(2)
        let scroll = try #require(tv.enclosingScrollView)
        let baseline = try #require(pinViewportY(tv, coordinator: coordinator))
        for shift: CGFloat in [0.5, 0.5, -0.5, -0.5] {
            tv.preservingViewportAnchor {
                let before = scroll.contentView.bounds.origin
                scroll.contentView.scroll(to: NSPoint(x: before.x, y: before.y + shift))
                scroll.reflectScrolledClipView(scroll.contentView)
                #expect(abs(scroll.contentView.bounds.origin.y - before.y - shift) < 0.01,
                        "the native clip must actually move inside the transaction")
            }
            let actual = try #require(pinViewportY(tv, coordinator: coordinator))
            #expect(abs(actual - baseline) < 0.01,
                    "each transaction must restore the readable line, including exactly half a point")
        }
    }

    @Test("the first-visible-character probe agrees with AppKit on wrapped continuation lines")
    func bridgeCharacterIndexMatchesAppKitOnWrappedLines() async throws {
        let (window, tv, coordinator) = try #require(await mount())
        defer { window.orderOut(nil) }
        let bridge = try #require(coordinator.layoutBridge)
        let container = try #require(bridge.firstTextContainer)

        // Probe a point on the SECOND visual line of the long wrapped
        // paragraph — the double-add bug overshot by a full line prefix here.
        // The paragraph must be IN the laid-out viewport first: the probe's
        // contract (like the helper's) is visible content only —
        // textLayoutFragment(for:) walks laid-out fragments.
        let ns = tv.string as NSString
        let wrapStart = ns.range(of: "WRAPLINE").location
        #expect(wrapStart != NSNotFound)
        scrollTo(location: wrapStart, tv, coordinator)
        await settle(2)
        let paraRect = bridge.boundingRect(
            forCharacterRange: ns.paragraphRange(for: NSRange(location: wrapStart, length: 0)),
            in: container
        )
        #expect(paraRect.height > 30, "fixture paragraph must wrap: height=\(paraRect.height)")
        let containerPoint = CGPoint(x: paraRect.minX + 4, y: paraRect.minY + paraRect.height * 0.6)
        var fraction: CGFloat = 0
        let bridgeIndex = bridge.characterIndex(
            for: containerPoint, in: container,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        let viewPoint = CGPoint(
            x: containerPoint.x + tv.textContainerOrigin.x,
            y: containerPoint.y + tv.textContainerOrigin.y
        )
        let appKitIndex = tv.characterIndexForInsertion(at: viewPoint)
        #expect(bridgeIndex != NSNotFound)
        #expect(abs(bridgeIndex - appKitIndex) <= 1,
                "bridge=\(bridgeIndex) vs AppKit=\(appKitIndex) — continuation-line offset must not double-add")
    }

    @Test("collapsing a revealed table above the caret does not move the visible content")
    func clickOutOfTableKeepsViewportStable() async throws {
        let (window, tv, coordinator) = try #require(await mount())
        defer { window.orderOut(nil) }
        let ns = tv.string as NSString

        // Reveal: caret into the table source (the click-into-table state).
        let tableStart = ns.range(of: "| 报告").location
        #expect(tableStart != NSNotFound)
        tv.setSelectedRange(NSRange(location: tableStart + 2, length: 0))
        fireSelectionChange(coordinator, tv)
        await settle()

        // Scroll so the pin (prose below the table) is visible.
        let pinRange = ns.range(of: Self.pinMarker)
        scrollTo(location: pinRange.location, tv, coordinator)
        await settle(2)
        let before = try #require(pinViewportY(tv, coordinator: coordinator))

        // Click OUT: caret onto the pin line — the table above COLLAPSES
        // (hundreds of points removed above the caret). Pre-fix the content
        // leapt up by that delta; the pin must stay put now.
        tv.setSelectedRange(NSRange(location: pinRange.location, length: 0))
        fireSelectionChange(coordinator, tv)
        let after = try #require(pinViewportY(tv, coordinator: coordinator))
        #expect(abs(after - before) < 8,
                "collapse above the caret moved the view by \(after - before)pt")

        await settle()
        // Post-settle drift: the long WRAPLINE fixture paragraph's estimated wrap
        // count used to be revised by the first layout pass AFTER the pinned
        // interaction (~55pt, once documented as "not addressable at the
        // interaction layer"). The restyle settle now ends on a second
        // layoutViewport(), so the pin's afterY reads the DRAWN geometry and that
        // estimate revision lands INSIDE the pin's before/after window and is
        // corrected — settled drift is now 0pt, matching the sync guarantee.
        // (Pre-fix catastrophic class was 100–2000pt.)
        let settled = try #require(pinViewportY(tv, coordinator: coordinator))
        #expect(abs(settled - before) < 8,
                "view drifted after settling: \(settled - before)pt")
    }

    /// Viewport-relative Y of an arbitrary character (same math as the pin probe).
    private func viewportY(of location: Int, _ tv: NativeTextView, _ coordinator: NativeTextViewCoordinator) -> CGFloat? {
        guard let docY = documentY(of: location, tv, coordinator) else { return nil }
        return docY - tv.visibleRect.minY
    }

    @Test("clicking a heading, then an empty line, keeps the clicked content in place")
    func clickHeadingThenEmptyLineKeepsViewportStable() async throws {
        let (window, tv, coordinator) = try #require(await mount())
        defer { window.orderOut(nil) }
        let ns = tv.string as NSString

        // Put the pin (and the long heading above it) on screen.
        let pinRange = ns.range(of: Self.pinMarker)
        scrollTo(location: pinRange.location, tv, coordinator)
        await settle(2)

        // Click INTO the heading: marker reveal changes its wrap count — a
        // height delta with NO banded token in the delta (the case the old
        // banded-only anchor gate skipped). The contract: the CLICKED line
        // stays under the cursor (content below it may legitimately shift).
        let headingLoc = ns.range(of: "## 各报告主要结果汇总与").location
        #expect(headingLoc != NSNotFound)
        let headingBefore = try #require(viewportY(of: headingLoc, tv, coordinator))
        tv.setSelectedRange(NSRange(location: headingLoc + 4, length: 0))
        fireSelectionChange(coordinator, tv)
        let headingAfter = try #require(viewportY(of: headingLoc, tv, coordinator))
        print("ANCHOR heading-reveal drift at clicked line: \(headingAfter - headingBefore)pt")
        #expect(abs(headingAfter - headingBefore) < 8,
                "clicking a heading moved the clicked line by \(headingAfter - headingBefore)pt")

        // Click the EMPTY LINE below the heading: the heading collapses back —
        // the newly clicked point must stay put through that reflow too.
        let emptyLineSearch = ns.range(of: "\n\nWRAPLINE")
        try #require(emptyLineSearch.location != NSNotFound)
        let emptyLoc = emptyLineSearch.location + 1
        let clickedBefore = try #require(viewportY(of: emptyLoc, tv, coordinator))
        tv.setSelectedRange(NSRange(location: emptyLoc, length: 0))
        fireSelectionChange(coordinator, tv)
        let clickedAfter = try #require(viewportY(of: emptyLoc, tv, coordinator))
        print("ANCHOR heading-collapse drift at clicked line: \(clickedAfter - clickedBefore)pt")
        #expect(abs(clickedAfter - clickedBefore) < 8,
                "clicking an empty line moved the clicked area by \(clickedAfter - clickedBefore)pt")
    }

    @Test("select-all bold toggle keeps the visible content in place")
    func selectAllBoldKeepsViewportStable() async throws {
        let (window, tv, coordinator) = try #require(await mount())
        defer { window.orderOut(nil) }

        // Scroll the pin into view mid-document.
        let ns = tv.string as NSString
        let pinRange = ns.range(of: Self.pinMarker)
        scrollTo(location: pinRange.location, tv, coordinator)
        await settle(2)
        let before = try #require(pinViewportY(tv, coordinator: coordinator))

        for _ in 0..<2 {   // toggle on, toggle off
            tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
            coordinator.didMarkdownBold(nil)
            await settle(4)
        }

        // Tolerance: a full-document toggle changes wrap counts THROUGHOUT the
        // viewport; a single-point pin can keep only one point stationary
        // (with ⌘A the caret is at location 0, so the viewport TOP is pinned
        // — content below it shifts by its own wrap deltas), and TextKit 2
        // estimate revisions land during the settle. ~2 wrapped lines on this
        // deliberately marker-dense fixture (WRAPLINE + long heading + table).
        // Unpinned, this exact fixture moved 111pt (and 86pt+ before the
        // restyle anchor); the interactive click paths assert < 8pt.
        let after = try #require(pinViewportY(tv, coordinator: coordinator))
        #expect(abs(after - before) <= 64,
                "select-all bold round-trip moved the view by \(after - before)pt")
    }
}
