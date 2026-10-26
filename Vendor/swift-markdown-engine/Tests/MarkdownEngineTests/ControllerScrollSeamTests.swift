//
//  ControllerScrollSeamTests.swift
//  MarkdownEngineTests
//
//  Fork seam: `MarkdownEditorController.currentScrollOffset` / `scroll(toOffset:)`
//  back the host's navigation history (Go Back/Forward) and cross-launch
//  reading-position persistence — the offset read must be the SAME value the
//  scroll write sets, or history restores drift.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Controller scroll seam")
struct ControllerScrollSeamTests {

    private final class State { var text: String; init(_ t: String) { text = t } }

    private func makeMountedEditor(text: String) -> (MarkdownEditorController, NSScrollView) {
        _ = NSApplication.shared
        let state = State(text)
        let controller = MarkdownEditorController()
        let wrapper = NativeTextViewWrapper(
            text: Binding(get: { state.text }, set: { state.text = $0 }),
            fontSize: 16,
            documentId: "scroll-seam",
            editorController: controller
        )
        let hosting = NSHostingView(rootView: wrapper)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let scrollView = hosting.subviews.compactMap { $0 as? NSScrollView }.first
            ?? hosting.firstScrollViewInSubtree()!
        return (controller, scrollView)
    }

    @Test func scrollWriteIsReadBackExactly() throws {
        let longDoc = (1...200).map { "line \($0)" }.joined(separator: "\n")
        let (controller, scrollView) = makeMountedEditor(text: longDoc)
        defer { scrollView.window?.orderOut(nil) }

        #expect(controller.currentScrollOffset != nil, "controller must be bound after mount")

        controller.scroll(toOffset: 300)
        #expect(controller.currentScrollOffset == 300)

        controller.scroll(toOffset: 0)
        #expect(controller.currentScrollOffset == 0)
    }

    @Test func scrollClampsToContent() throws {
        let shortDoc = "one\ntwo"
        let (controller, scrollView) = makeMountedEditor(text: shortDoc)
        defer { scrollView.window?.orderOut(nil) }

        controller.scroll(toOffset: 10_000)
        let offset = try #require(controller.currentScrollOffset)
        #expect(offset < 10_000, "offset must clamp to the actual content height")
    }
}

private extension NSView {
    func firstScrollViewInSubtree() -> NSScrollView? {
        if let sv = self as? NSScrollView { return sv }
        for sub in subviews {
            if let found = sub.firstScrollViewInSubtree() { return found }
        }
        return nil
    }
}
