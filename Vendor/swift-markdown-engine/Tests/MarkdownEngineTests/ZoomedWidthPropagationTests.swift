import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Zoomed window resize updates prose width", .serialized)
struct ZoomedWidthPropagationTests {
    @MainActor private final class Source {
        var text: String
        let undo = UndoManager()
        init(_ text: String) { self.text = text }
    }

    private func spinMainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    private func settle() async {
        for _ in 0..<8 {
            spinMainRunLoop()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test("a retained editor at 50% zoom adopts the resized viewport's prose width")
    func zoomedResizeUpdatesProseWrapWidth() async throws {
        _ = NSApplication.shared
        let original = (0..<200).map { "Wrapped prose \($0) 日本" }.joined(separator: " ")
        let source = Source(original)
        let configuration = MarkdownEditorConfiguration.default
        let wrapper = NativeTextViewWrapper(
            text: Binding(get: { source.text }, set: { source.text = $0 }),
            configuration: configuration, fontSize: 16,
            documentId: "zoomed-width-\(UUID().uuidString)", isEditable: true,
            undoManager: source.undo, magnificationRange: 0.5...4.0, magnification: 0.5
        )
        let coordinator = wrapper.makeCoordinator()
        let scrollView = try #require(wrapper.makeNativeView(coordinator: coordinator) as? ClampedScrollView)
        let textView = try #require(scrollView.nativeTextView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let mount = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = mount
        scrollView.frame = mount.bounds
        scrollView.autoresizingMask = [.width, .height]
        mount.addSubview(scrollView)
        scrollView.tile()
        wrapper.updateNativeView(scrollView, coordinator: coordinator)
        window.orderBack(nil)
        defer {
            NativeTextViewWrapper.dismantleNSView(scrollView, coordinator: coordinator)
            source.undo.removeAllActions()
            window.orderOut(nil)
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
        await settle()
        try #require(abs(scrollView.magnification - 0.5) < 0.01)
        let textContainer = try #require(textView.textContainer)
        let oldWrapWidth = textContainer.size.width
        try #require(abs(oldWrapWidth - (scrollView.contentView.frame.width - configuration.textInsets.horizontal * 2)) < 1)
        source.undo.beginUndoGrouping()
        textView.insertText(" Edited", replacementRange: NSRange(location: (original as NSString).length, length: 0))
        textView.breakUndoCoalescing()
        source.undo.endUndoGrouping()
        coordinator.commitTextSync(for: textView)
        await settle()

        window.setContentSize(NSSize(width: 500, height: 500))
        mount.layoutSubtreeIfNeeded()
        scrollView.frame = mount.bounds
        scrollView.tile()
        await settle()

        try #require(abs(mount.bounds.width - 500) < 1)
        try #require(abs(scrollView.frame.width - 500) < 1)
        let expectedWrapWidth = scrollView.contentView.frame.width - configuration.textInsets.horizontal * 2
        try #require(expectedWrapWidth < oldWrapWidth - 100)
        #expect(abs(textContainer.size.width - expectedWrapWidth) < 1,
                "zoom pins wrapping against magnification, while a resized window must change the prose width")
        #expect((textView.string as NSString).isEqual(to: original + " Edited"))
        #expect((source.text as NSString).isEqual(to: original + " Edited"))
        source.undo.undo()
        coordinator.commitTextSync(for: textView)
        #expect((textView.string as NSString).isEqual(to: original))
        #expect((source.text as NSString).isEqual(to: original))
        source.undo.redo()
        coordinator.commitTextSync(for: textView)
        #expect((textView.string as NSString).isEqual(to: original + " Edited"))
        #expect((source.text as NSString).isEqual(to: original + " Edited"))
    }
}
