//
//  WideTableRealignSelfCheckTests.swift
//  MarkdownEngineTests
//
//  Field forensics 2026-07-03 (dumps #1–#3): overlays parked on estimated
//  offscreen geometry floated grids 1000+pt into unrelated prose. Under the
//  viewport-scoped model, frames are only ever DERIVED from in-band, current
//  layout: realign corrects a stale parked frame from the anchor's live rect,
//  hides anything it cannot validate (orphaned/unmeasurable anchors), and the
//  reconcile's total sweep deletes what does not belong. These tests drive
//  that contract through the real mounted editor.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Wide-table realign self-check", .serialized)
struct WideTableRealignSelfCheckTests {
    typealias H = TableOverlayEndToEndTests

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

    private func mount() async -> (NSWindow, NativeTextView)? {
        _ = NSApplication.shared
        let host = H.Host(text: H.doc)
        let hosting = NSHostingView(rootView: H.EditorHarnessView(
            host: host, configuration: configuration()
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        guard let tv = findEditor(in: hosting) else { return nil }
        return (window, tv)
    }

    /// The band invariant, computed the way the Debug audit does: every
    /// VISIBLE overlay must end above the paragraph following its table.
    private func visibleBandViolations(_ tv: NativeTextView) -> [String] {
        guard let storage = tv.textStorage,
              let bridge = tv.layoutBridge,
              let container = bridge.firstTextContainer else { return [] }
        let ns = tv.string as NSString
        var violations: [String] = []
        for (sourceID, overlay) in tv.wideTableOverlays where !overlay.isHidden {
            let loc = overlay.anchorTextLocation
            guard loc >= 0, loc < ns.length,
                  (storage.attribute(.scrollableBlockSourceID, at: loc, effectiveRange: nil) as? Int) == sourceID else { continue }
            let full = (storage.attribute(.scrollableBlockFullRange, at: loc, effectiveRange: nil) as? NSValue)
                .map { AnchorRelativeRange.decode($0, anchorLocation: loc) }
                ?? ns.paragraphRange(for: NSRange(location: loc, length: 0))
            let belowLoc = NSMaxRange(full) + 1
            guard belowLoc < ns.length else { continue }
            let belowPara = ns.paragraphRange(for: NSRange(location: belowLoc, length: 0))
            let rect = bridge.boundingRect(forCharacterRange: belowPara, in: container)
            guard !rect.isEmpty else { continue }
            let belowTop = tv.frame.origin.y + tv.textContainerOrigin.y + rect.minY
            if overlay.frame.maxY > belowTop + 2 {
                violations.append("id=\(sourceID) frame=\(overlay.frame) belowTop=\(belowTop)")
            }
        }
        return violations
    }

    @Test("a stale parked frame is corrected from the anchor's live rect")
    func staleParkedFrameIsCorrected() async throws {
        let (window, tv) = try #require(await mount())
        defer { window.orderOut(nil) }
        let overlay = try #require(tv.wideTableOverlays.values.first)
        #expect(!overlay.isHidden)
        let goodFrame = overlay.frame

        // The reachable failure: a frame parked by an OLD layout (the field's
        // 1400pt drift). Realign must re-derive from the anchor's current
        // in-band rect and correct it — visible, on its band, no hiding.
        overlay.frame = goodFrame.offsetBy(dx: 0, dy: 1400)
        tv.realignWideTableOverlays()

        #expect(!overlay.isHidden)
        #expect(abs(overlay.frame.origin.y - goodFrame.origin.y) < 2,
                "realign must correct the parked frame, got y=\(overlay.frame.origin.y) vs \(goodFrame.origin.y)")
        #expect(visibleBandViolations(tv).isEmpty)
    }

    @Test("an overlay whose sourceID vanished from storage hides on the next realign")
    func orphanedOverlayHidesOnRealign() async throws {
        let (window, tv) = try #require(await mount())
        defer { window.orderOut(nil) }
        let storage = try #require(tv.textStorage)
        let overlay = try #require(tv.wideTableOverlays.values.first)
        #expect(!overlay.isHidden)

        // Simulate the churn/reveal orphaning the field dumps caught: the
        // sourceID attribute disappears (re-hash, reveal, narrow
        // re-classification) while the overlay still floats at its old frame.
        storage.removeAttribute(
            .scrollableBlockSourceID,
            range: NSRange(location: overlay.anchorTextLocation, length: 1)
        )
        tv.realignWideTableOverlays()
        #expect(overlay.isHidden, "a ghost grid must hide on the very next realign tick")

        // The scheduled reconcile then removes it outright.
        await settle()
        #expect(tv.wideTableOverlays[overlay.sourceID] == nil)
    }

    @Test("the draw-glue's deferred apply refuses a stale mid-draw frame")
    func drawGlueApplyTimeValidation() async throws {
        let (window, tv) = try #require(await mount())
        defer { window.orderOut(nil) }
        let overlay = try #require(tv.wideTableOverlays.values.first)
        let goodY = overlay.frame.origin.y

        // A stale fragment re-asserting pre-reflow geometry: an anchor rect
        // thousands of points below the real band. Pre-fix, the deferred
        // apply parked it verbatim (the field's +1318pt park); post-fix the
        // apply-time band check must refuse it and the reconcile must
        // restore the true frame.
        let staleAnchor = CGRect(x: 0, y: goodY + 4000, width: 10, height: 207)
        tv.syncWideTableOverlay(sourceID: overlay.sourceID, anchorRect: staleAnchor, totalHeight: nil)
        await settle()

        let healed = try #require(tv.wideTableOverlays[overlay.sourceID])
        #expect(!healed.isHidden)
        #expect(abs(healed.frame.origin.y - goodY) < 50,
                "stale mid-draw frame must not survive, got y=\(healed.frame.origin.y) vs \(goodY)")
        #expect(visibleBandViolations(tv).isEmpty)
    }

    @Test("select-all format toggles never show an off-band grid")
    func fieldFormatToggleSequenceKeepsInvariant() async throws {
        let (window, tv) = try #require(await mount())
        defer { window.orderOut(nil) }
        let coordinator = try #require(tv.delegate as? NativeTextViewCoordinator)

        // The field sequence: ⌘A, then format toggles over the whole document
        // (tables included). After every runloop turn — mid-reflow included —
        // no VISIBLE overlay may sit across its band limit (hidden is fine;
        // misplaced is the bug).
        for _ in 0..<2 {
            tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
            coordinator.didMarkdownBold(nil)
            for _ in 0..<6 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                let violations = visibleBandViolations(tv)
                #expect(violations.isEmpty, "off-band grid mid-toggle: \(violations)")
                await Task.yield()
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        await settle()
        #expect(visibleBandViolations(tv).isEmpty)
        // The document round-tripped through bold-on + bold-off; a wide-table
        // overlay must still exist and be visible on its band.
        let overlay = try #require(tv.wideTableOverlays.values.first)
        #expect(!overlay.isHidden)
    }
}
