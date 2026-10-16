//
//  ClickStabilityTests.swift
//  MarkdownEngineTests
//
//  Regression guard for "clicking on stuff makes tables and the rest of the
//  document disappear" — a block reveal/collapse grew the content while a
//  re-entrant restack was dropped, leaving the container frame stale-short so the
//  clip scrolled past it into a blank that stayed blank. Mounts the editor as the
//  app does (magnification enabled, full-width, a wide table + a mermaid block +
//  long prose), clicks around at several zooms, and asserts the content never
//  collapses, never scrolls into the blank, and the container frame stays tall
//  enough to hold the content.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Click stability", .serialized)
struct ClickStabilityTests {

    final class Host { var text: String; init(_ t: String) { text = t } }

    // A mock diagram renderer so the mermaid block collapses to an image like the app.
    final class MockDiagram: BlockDiagramRenderer, @unchecked Sendable {
        func render(source: String, language: String, maxWidth: CGFloat, fontSize: CGFloat,
                    theme: MarkdownEditorTheme) -> DiagramRenderResult? {
            let size = CGSize(width: min(maxWidth, 300), height: 220)
            let img = NSImage(size: size)
            img.lockFocus(); NSColor.gray.setFill(); NSRect(origin: .zero, size: size).fill(); img.unlockFocus()
            return DiagramRenderResult(image: img, size: size)
        }
    }

    struct Harness: View {
        let host: Host
        var magnification: CGFloat   // VALUE prop so rootView reassignment projects it
        var body: some View {
            NativeTextViewWrapper(
                text: Binding(get: { host.text }, set: { host.text = $0 }),
                configuration: {
                    var c = MarkdownEditorConfiguration.default
                    c.services.diagram = MockDiagram()
                    c.textInsets = TextInsets(horizontal: 24, vertical: 0)
                    c.safeAreaInsets = SafeAreaInsets(top: 90, leading: 0, trailing: 0, bottom: 0)
                    return c
                }(),
                fontSize: 16, documentId: "repro", isEditable: true,
                magnificationRange: 0.5...4.0, magnification: magnification
            )
        }
    }

    static let doc: String = {
        var l: [String] = ["# Title", ""]
        l += (0..<25).map { "Intro prose line \($0) with steady filler text to occupy vertical space." }
        l.append("")
        l.append("| Col A | Col B | Col C | Col D | Col E | Col F | Col G | Col H |")
        l.append("| --- | --- | --- | --- | --- | --- | --- | --- |")
        l += (0..<4).map { r in "| a\(r) longcell | b\(r) longcell | c\(r) | d\(r) | e\(r) | f\(r) | g\(r) | h\(r) |" }
        l.append("")
        l += (0..<8).map { "Middle prose line \($0) between the table and the diagram." }
        l.append("")
        l.append("```mermaid"); l.append("graph TD"); l.append("  A[Start] --> B[End]"); l.append("```")
        l.append("")
        l += (0..<40).map { "Tail prose line \($0) keeps the document tall and scrollable." }
        return l.joined(separator: "\n")
    }()

    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    private func settle(_ n: Int = 8) async {
        for _ in 0..<n { spin(); await Task.yield(); try? await Task.sleep(nanoseconds: 10_000_000) }
    }
    private func findEditor(in v: NSView) -> NativeTextView? {
        if let tv = v as? NativeTextView { return tv }
        for s in v.subviews { if let f = findEditor(in: s) { return f } }
        return nil
    }
    private func fire(_ coord: NativeTextViewCoordinator, _ tv: NativeTextView) {
        coord.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: tv))
    }

    private func documentY(of loc: Int, _ tv: NativeTextView) -> CGFloat? {
        guard let bridge = tv.layoutBridge, let container = bridge.firstTextContainer else { return nil }
        let r = bridge.boundingRect(forCharacterRange: NSRange(location: loc, length: 1), in: container)
        guard r.height >= 0.01 else { return nil }
        return r.minY + tv.textContainerOrigin.y
    }
    private func scrollTo(_ loc: Int, _ tv: NativeTextView) {
        guard let docY = documentY(of: loc, tv), let sv = tv.enclosingScrollView else { return }
        let clip = sv.contentView
        clip.scroll(to: NSPoint(x: 0, y: docY - 200))
        sv.reflectScrolledClipView(clip)
        (sv as? ClampedScrollView)?.clampToInsets()
    }

    @Test(arguments: [1.0, 0.6, 0.5, 2.0])
    func clickStress(mag: CGFloat) async throws {
        _ = NSApplication.shared
        let host = Host(Self.doc)
        let hosting = NSHostingView(rootView: Harness(host: host, magnification: mag))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 820),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        defer { window.orderOut(nil) }

        let tv = try #require(findEditor(in: hosting))
        let coord = try #require(tv.delegate as? NativeTextViewCoordinator)
        let scroll = try #require(tv.enclosingScrollView)
        let ns = tv.string as NSString
        let baselineHeight = tv.scrollableContentHeight
        print("REPRO[mag=\(mag)] baseline contentHeight=\(baselineHeight) docLen=\(ns.length) viewMag=\(scroll.magnification)")

        // Scroll into the middle so a click that reveals/collapses an off-screen
        // block makes the anchor actively scroll (the disappear condition).
        scrollTo(ns.range(of: "Middle prose line 3").location, tv)
        await settle(3)

        // Click targets: into the table, a mid prose line, into the mermaid source,
        // an empty line, the tail, back to the top table.
        let targets: [(String, Int)] = [
            ("into-table", ns.range(of: "a0 longcell").location),
            ("mid-prose", ns.range(of: "Middle prose line 3").location),
            ("into-mermaid", ns.range(of: "graph TD").location + 2),
            ("tail", ns.range(of: "Tail prose line 20").location),
            ("intro", ns.range(of: "Intro prose line 10").location),
            ("into-table-2", ns.range(of: "b1 longcell").location),
            ("empty-after-table", ns.range(of: "Middle prose line 0").location - 1),
            ("tail-far", ns.range(of: "Tail prose line 38").location),
        ]

        for (label, loc) in targets where loc != NSNotFound && loc < ns.length {
            tv.setSelectedRange(NSRange(location: max(0, loc), length: 0))
            fire(coord, tv)
            await settle(4)

            let h = tv.scrollableContentHeight
            let containerH = (scroll.documentView as? NativeTextViewContainer)?.frame.height ?? 0
            let offsetY = scroll.contentView.bounds.origin.y
            let maxValid = max(0, h - scroll.contentView.bounds.height) + 4
            let minValid = -scroll.contentInsets.top - 4
            // Is at least SOME real laid-out content in the viewport?
            var laidOutInView = false
            if let bridge = tv.layoutBridge, let container = bridge.firstTextContainer {
                let vis = tv.visibleRect
                var probe = vis.minY
                var frac: CGFloat = 0
                while probe < vis.maxY {
                    let idx = bridge.characterIndex(for: CGPoint(x: vis.midX, y: probe), in: container,
                                                    fractionOfDistanceBetweenInsertionPoints: &frac)
                    if idx != NSNotFound {
                        let r = bridge.boundingRect(forCharacterRange: NSRange(location: idx, length: 1), in: container)
                        if r.height > 0.01 { laidOutInView = true; break }
                    }
                    probe += 20
                }
            }
            print("REPRO \(label): height=\(h) offsetY=\(offsetY) validY=[\(minValid),\(maxValid)] laidOutInView=\(laidOutInView) mag=\(scroll.magnification)")

            #expect(h > baselineHeight * 0.5, "\(label): content height collapsed (\(h) vs baseline \(baselineHeight))")
            #expect(offsetY >= minValid && offsetY <= maxValid, "\(label): scrolled into the blank (offsetY=\(offsetY), valid=[\(minValid),\(maxValid)])")
            #expect(laidOutInView, "\(label): NOTHING laid out in the visible rect — the document disappeared")
            // The bug: the container (document view) frame lagged the content
            // (8855 vs 11371) after a reveal, so the clip could scroll past it into
            // the blank. The container must stay tall enough to hold the content.
            #expect(containerH + 120 >= h, "\(label): container frame (\(containerH)) is stale-short vs content (\(h)) — clip can scroll into the blank")
        }
    }
}
