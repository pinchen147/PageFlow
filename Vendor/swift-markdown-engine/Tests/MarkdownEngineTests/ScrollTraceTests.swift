//
//  ScrollTraceTests.swift
//  MarkdownEngineTests
//
//  The attribution ledger is the phase-0 oracle for "the view moved and nobody
//  asked": every engine write stamps itself, every user gesture stamps itself,
//  and whatever is left is a jump. These tests pin the attribution rules on a
//  real NSScrollView so the QA harness can trust `snapshot()`.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("ScrollTrace attribution", .serialized)
struct ScrollTraceTests {

    private func makeScrollView() -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 10_000))
        scrollView.documentView = document
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.5
        scrollView.maxMagnification = 4
        ScrollTrace.reset()
        ScrollTrace.observe(scrollView)   // baseline: the first observation only records the origin
        return scrollView
    }

    private func scroll(_ scrollView: NSScrollView, by delta: CGFloat) {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y + delta))
        scrollView.reflectScrolledClipView(clip)
        ScrollTrace.observe(scrollView)
    }

    @Test("an unstamped origin change is unattributed and its magnitude is kept")
    func unstampedMoveIsUnattributed() {
        let scrollView = makeScrollView()
        scroll(scrollView, by: 120)
        let report = ScrollTrace.snapshot()
        #expect(report.unattributedCount == 1)
        #expect(report.attributedCount == 0)
        #expect(report.unattributedMaxDelta == 120)
        #expect(report.recent.last?.mutator == nil)
    }

    @Test("a stamped engine write is attributed to its stamp")
    func stampedMoveIsAttributed() {
        let scrollView = makeScrollView()
        ScrollTrace.stamp("test:restore")
        scroll(scrollView, by: 80)
        let report = ScrollTrace.snapshot()
        #expect(report.attributedCount == 1)
        #expect(report.unattributedCount == 0)
        #expect(report.recent.last?.mutator == "test:restore")
    }

    @Test("a stamp explains only the moves inside its window")
    func staleStampDoesNotAttribute() {
        let scrollView = makeScrollView()
        ScrollTrace.stamp("test:old")
        Thread.sleep(forTimeInterval: ScrollTrace.attributionWindow + 0.03)
        scroll(scrollView, by: 40)
        #expect(ScrollTrace.snapshot().unattributedCount == 1)
    }

    @Test("every move inside a live gesture bracket is the user's, however late")
    func liveGestureBracketAttributesEverything() {
        let scrollView = makeScrollView()
        ScrollTrace.beginLiveGesture("scroll")
        Thread.sleep(forTimeInterval: ScrollTrace.attributionWindow + 0.03)
        scroll(scrollView, by: 40)
        scroll(scrollView, by: 40)
        ScrollTrace.endLiveGesture("scroll")
        let report = ScrollTrace.snapshot()
        #expect(report.attributedCount == 2)
        #expect(report.unattributedCount == 0)
    }

    @Test("a magnification change explains the origin move it causes")
    func magnificationChangeIsAttributed() throws {
        let scrollView = makeScrollView()
        // A scroll view only magnifies while hosted; give it a window so the
        // setter takes effect (the harness scroll views always have one).
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scrollView
        defer { window.orderOut(nil) }
        scrollView.setMagnification(2, centeredAt: .zero)
        try #require(abs(scrollView.magnification - 2) < 0.001)
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y + 30))
        ScrollTrace.observe(scrollView)
        let report = ScrollTrace.snapshot()
        #expect(report.unattributedCount == 0)
        #expect(report.recent.last?.mutator == "magnification")
    }

    @Test("sub-half-point jitter is ignored and reset clears the ledger")
    func jitterIgnoredAndResetClears() {
        let scrollView = makeScrollView()
        scroll(scrollView, by: 0.25)
        #expect(ScrollTrace.snapshot() == ScrollTrace.Report())
        scroll(scrollView, by: 10)
        #expect(ScrollTrace.snapshot().unattributedCount == 1)
        ScrollTrace.reset()
        #expect(ScrollTrace.snapshot() == ScrollTrace.Report())
    }
}
