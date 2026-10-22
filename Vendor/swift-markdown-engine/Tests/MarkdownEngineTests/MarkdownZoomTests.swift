//
//  MarkdownZoomTests.swift
//  MarkdownEngineTests
//
//  The PDF-style visual-zoom fork knobs: `magnificationRange` enables
//  NSScrollView magnification and bounds it; `magnification` projects the
//  host-owned level (⌘±, ⌘0, cross-launch restore) onto the live scroll view.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Markdown visual zoom", .serialized)
struct MarkdownZoomTests {

    final class Host { var text: String; init(_ t: String) { text = t } }

    struct Harness: View {
        let host: Host
        // VALUE prop: rootView reassignment must diff so updateNSView re-runs and
        // projects the new magnification (the reference-only-prop trap).
        var magnification: CGFloat
        var body: some View {
            NativeTextViewWrapper(
                text: Binding(get: { host.text }, set: { host.text = $0 }),
                configuration: .default,
                fontSize: 16,
                documentId: "zoom",
                isEditable: true,
                magnificationRange: 0.5...4.0,
                magnification: magnification
            )
        }
    }

    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    private func settle(_ n: Int = 6) async {
        for _ in 0..<n { spin(); await Task.yield(); try? await Task.sleep(nanoseconds: 10_000_000) }
    }
    private func findScroll(in v: NSView) -> NSScrollView? {
        if let s = v as? NSScrollView { return s }
        for sub in v.subviews { if let s = findScroll(in: sub) { return s } }
        return nil
    }

    @Test("magnificationRange enables scroll magnification; host level projects and clamps")
    func projectsAndClamps() async throws {
        _ = NSApplication.shared
        let host = Host("# Zoom me\n\nSome body text to lay out.\n")
        let hosting = NSHostingView(rootView: Harness(host: host, magnification: 1.0))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        defer { window.orderOut(nil) }

        let scroll = try #require(findScroll(in: hosting))
        #expect(scroll.allowsMagnification)
        #expect(scroll.minMagnification == 0.5)
        #expect(scroll.maxMagnification == 4.0)
        #expect(abs(scroll.magnification - 1.0) < 0.01)

        // Project a new host level (the ⌘+ / restore path).
        hosting.rootView = Harness(host: host, magnification: 2.0)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        #expect(abs(scroll.magnification - 2.0) < 0.01, "host magnification must project onto the scroll view")

        // Out-of-range projection clamps to the bounds.
        hosting.rootView = Harness(host: host, magnification: 99)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        #expect(abs(scroll.magnification - 4.0) < 0.01, "projection must clamp to maxMagnification")
    }
}
