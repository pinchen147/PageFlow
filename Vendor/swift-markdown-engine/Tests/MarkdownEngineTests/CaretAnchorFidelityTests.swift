import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Visible caret anchoring through a table collapse", .serialized)
struct CaretAnchorFidelityTests {
    private static let source: String = {
        let table = ["| Item | Detail | Value |", "| --- | --- | --- |"]
            + (0..<8).map { "| row-\($0) | 日本 cafe\u{301} | \($0) anchor |" }
        let tail = (0..<30).map { "Tail paragraph \($0) keeps the document scrollable." }
        return "# Caret anchor fixture\n\n" + table.joined(separator: "\n")
            + "\n\n" + tail.joined(separator: "\n\n")
    }()

    @MainActor private final class Document {
        var text = CaretAnchorFidelityTests.source
        let undo = UndoManager()
    }

    private struct LineGeometry {
        let documentY: CGFloat
        let windowY: CGFloat
        let height: CGFloat
    }

    private func spinMainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    private func settle(_ rounds: Int = 8) async {
        for _ in 0..<rounds {
            spinMainRunLoop()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Measures the actual source line without using the editor's pin selection or layout bridge.
    private func line(at offset: Int, in view: NativeTextView) throws -> LineGeometry {
        let layout = try #require(view.textLayoutManager)
        let content = try #require(layout.textContentManager)
        let location = try #require(content.location(content.documentRange.location, offsetBy: offset))
        let fragment = try #require(layout.textLayoutFragment(for: location))
        try #require(fragment.state == .layoutAvailable)
        let line = try #require(fragment.textLineFragment(for: location, isUpstreamAffinity: false))
        let documentY = fragment.layoutFragmentFrame.minY + line.typographicBounds.minY
            + view.textContainerOrigin.y
        return LineGeometry(
            documentY: documentY,
            windowY: view.convert(NSPoint(x: view.textContainerOrigin.x, y: documentY), to: nil).y,
            height: line.typographicBounds.height
        )
    }

    private func tableHasImage(_ range: NSRange, in storage: NSTextStorage) -> Bool {
        var hasImage = false
        storage.enumerateAttribute(.renderedBlockImage, in: range) { value, _, stop in
            if value is NSImage {
                hasImage = true
                stop.pointee = true
            }
        }
        return hasImage
    }

    /// Deliver the native selection callback explicitly, as the table-cycle harness does.
    /// Re-delivery is idempotent when AppKit already notified the delegate.
    private func moveCaret(_ view: NativeTextView, to offset: Int, coordinator: NativeTextViewCoordinator) {
        view.setSelectedRange(NSRange(location: offset, length: 0))
        coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: view)
        )
    }

    @Test("clicking the blank after a visible table pins the caret while the table folds")
    func followingBlankStaysUnderTheCaret() async throws {
        _ = NSApplication.shared
        let document = Document()
        var configuration = MarkdownEditorConfiguration.default
        configuration.readingWidth = 720
        let wrapper = NativeTextViewWrapper(
            text: Binding(get: { document.text }, set: { document.text = $0 }),
            configuration: configuration, fontSize: 16,
            documentId: "caret-table-\(UUID().uuidString)", isEditable: true,
            undoManager: document.undo
        )
        let coordinator = wrapper.makeCoordinator()
        let scroll = try #require(wrapper.makeNativeView(coordinator: coordinator) as? ClampedScrollView)
        let view = try #require(scroll.nativeTextView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scroll.frame = try #require(window.contentView).bounds
        window.contentView = scroll
        scroll.tile()
        wrapper.updateNativeView(scroll, coordinator: coordinator)
        window.orderBack(nil)
        window.makeFirstResponder(view)
        await settle()
        defer {
            NativeTextViewWrapper.dismantleNSView(scroll, coordinator: coordinator)
            document.undo.removeAllActions()
            window.close()
        }

        document.undo.groupsByEvent = false
        document.undo.beginUndoGrouping()
        view.insertText(" Edited", replacementRange: NSRange(location: (Self.source as NSString).length, length: 0))
        view.breakUndoCoalescing()
        document.undo.endUndoGrouping()
        coordinator.commitTextSync(for: view)
        let edited = Self.source + " Edited"
        try #require((document.text as NSString).isEqual(to: edited))
        try #require(document.undo.canUndo)
        let ns = edited as NSString
        let cell = ns.range(of: "row-3").location
        let gap = ns.range(of: "\n\nTail paragraph 0")
        try #require(cell != NSNotFound && gap.location != NSNotFound)
        let blank = gap.location + 1
        let table = try #require(coordinator.parsedDocument(for: edited).tokens.enumerated().first { $0.element.kind == .table })
        let storage = try #require(view.textStorage)
        // Edit Table Source: a plain caret in the table edits a cell instead.
        coordinator.tableEditingSession.revealSource(of: table.element.range)
        moveCaret(view, to: cell, coordinator: coordinator)
        await settle()
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle()
        try #require(coordinator.activeTokenIndices.contains(table.offset))
        try #require(!tableHasImage(table.element.range, in: storage), "the selected table must expose raw source")

        let headingBefore = try line(at: 0, in: view)
        let blankBefore = try line(at: blank, in: view)
        for geometry in [headingBefore, blankBefore] {
            try #require(geometry.height > 0)
            try #require(geometry.documentY >= view.visibleRect.minY
                         && geometry.documentY + geometry.height <= view.visibleRect.maxY,
                         "both the heading and clicked blank must actually be visible")
        }
        let originBefore = scroll.contentView.bounds.origin.y
        moveCaret(view, to: blank, coordinator: coordinator)
        try #require(!coordinator.activeTokenIndices.contains(table.offset))
        try #require(tableHasImage(table.element.range, in: storage), "leaving the table must restore its rendered grid")
        let synchronous = try line(at: blank, in: view)
        #expect(abs(synchronous.windowY - blankBefore.windowY) < 1,
                "the clicked blank moved \(synchronous.windowY - blankBefore.windowY)pt synchronously")
        await settle()
        let blankAfter = try line(at: blank, in: view)
        let headingAfter = try line(at: 0, in: view)
        try #require(abs(blankAfter.documentY - blankBefore.documentY) > 1,
                     "the rendered grid must change geometry above the clicked blank")
        #expect(abs(blankAfter.windowY - blankBefore.windowY) < 1,
                "the clicked blank moved \(blankAfter.windowY - blankBefore.windowY)pt after settling")
        print("CARET-TABLE headingWindowDelta=\(headingAfter.windowY - headingBefore.windowY) "
              + "headingDocumentDelta=\(headingAfter.documentY - headingBefore.documentY) "
              + "signedOriginDelta=\(scroll.contentView.bounds.origin.y - originBefore) "
              + "blankDocumentDelta=\(blankAfter.documentY - blankBefore.documentY)")

        let settledOrigin = scroll.contentView.bounds.origin.y
        moveCaret(view, to: blank, coordinator: coordinator)
        await settle(3)
        let noOp = try line(at: blank, in: view)
        #expect(abs(noOp.windowY - blankAfter.windowY) < 1)
        #expect(abs(scroll.contentView.bounds.origin.y - settledOrigin) < 1)
        #expect(tableHasImage(table.element.range, in: storage))
        #expect((view.string as NSString).isEqual(to: edited))
        #expect((document.text as NSString).isEqual(to: edited))
        #expect(document.undo.canUndo)
        document.undo.undo()
        coordinator.commitTextSync(for: view)
        #expect((view.string as NSString).isEqual(to: Self.source))
        #expect((document.text as NSString).isEqual(to: Self.source))
        try #require(document.undo.canRedo)
        document.undo.redo()
        coordinator.commitTextSync(for: view)
        #expect((view.string as NSString).isEqual(to: edited))
        #expect((document.text as NSString).isEqual(to: edited))
    }
}
