import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Reading position preserves a source line through reflow", .serialized)
struct ReadingPositionFidelityTests {
    private static let prefix = "Preface e\u{301} 🇯🇵.\r\n\r\n"
    private static let source = prefix
        + (0..<1_000).map { "token-\($0) 日本 cafe\u{301}" }.joined(separator: " ")
        + "\r\n\r\nTrailing paragraph keeps the note editable."

    @MainActor private final class Document {
        var text: String
        let undo = UndoManager()
        init(_ text: String) { self.text = text }
    }

    private struct Mounted {
        let window: NSWindow
        let container: NSView
        let textView: NativeTextView
        let scrollView: ClampedScrollView
        let coordinator: NativeTextViewCoordinator
    }

    private struct LinePin {
        let sourceOffset: Int
        let elementOffset: Int
        let localOffset: Int
        let documentY: CGFloat
        let windowY: CGFloat
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

    private func mount(_ document: Document, magnification: CGFloat) async throws -> Mounted {
        _ = NSApplication.shared
        let wrapper = NativeTextViewWrapper(
            text: Binding(get: { document.text }, set: { document.text = $0 }),
            configuration: .default, fontSize: 16,
            documentId: "line-reflow-\(UUID().uuidString)", isEditable: true,
            undoManager: document.undo,
            magnificationRange: 0.5...4.0, magnification: magnification
        )
        let coordinator = wrapper.makeCoordinator()
        let scrollView = try #require(wrapper.makeNativeView(coordinator: coordinator) as? ClampedScrollView)
        let textView = try #require(scrollView.nativeTextView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = container
        scrollView.frame = container.bounds
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)
        scrollView.tile()
        wrapper.updateNativeView(scrollView, coordinator: coordinator)
        window.orderBack(nil)
        container.layoutSubtreeIfNeeded()
        // Finish restored-zoom geometry before the independently tested resize.
        try? await Task.sleep(nanoseconds: 350_000_000)
        await settle()
        return Mounted(window: window, container: container, textView: textView,
                       scrollView: scrollView, coordinator: coordinator)
    }

    /// Measures the source character's containing line directly through TextKit,
    /// independently of the editor's ReadingPosition capture/restore policy.
    private func line(containing sourceOffset: Int, in textView: NativeTextView) throws -> LinePin {
        let layout = try #require(textView.textLayoutManager)
        let content = try #require(layout.textContentManager)
        let location = try #require(content.location(content.documentRange.location, offsetBy: sourceOffset))
        let fragment = try #require(layout.textLayoutFragment(for: location))
        try #require(fragment.state == .layoutAvailable)
        let line = try #require(fragment.textLineFragment(for: location, isUpstreamAffinity: false))
        let elementRange = try #require(fragment.textElement?.elementRange)
        let elementOffset = content.offset(from: content.documentRange.location, to: elementRange.location)
        let documentY = fragment.layoutFragmentFrame.minY
            + line.typographicBounds.minY + textView.textContainerOrigin.y
        return LinePin(
            sourceOffset: elementOffset + line.characterRange.location,
            elementOffset: elementOffset, localOffset: line.characterRange.location,
            documentY: documentY,
            windowY: textView.convert(NSPoint(x: textView.textContainerOrigin.x, y: documentY), to: nil).y
        )
    }

    @Test("resizing keeps an interior wrapped source line at the same window position and preserves Undo",
          arguments: [CGFloat(1), CGFloat(0.5)])
    func widthChangeKeepsTheVisibleSourceLine(magnification: CGFloat) async throws {
        let document = Document(Self.source)
        let m = try await mount(document, magnification: magnification)
        defer {
            NativeTextViewWrapper.dismantleNSView(m.scrollView, coordinator: m.coordinator)
            document.undo.removeAllActions()
            m.window.orderOut(nil)
        }
        try #require(abs(m.scrollView.magnification - magnification) < 0.01)
        document.undo.beginUndoGrouping()
        m.textView.insertText(" Edited", replacementRange: NSRange(location: (Self.source as NSString).length, length: 0))
        m.textView.breakUndoCoalescing()
        document.undo.endUndoGrouping()
        m.coordinator.commitTextSync(for: m.textView)
        let edited = Self.source + " Edited"
        try #require((document.text as NSString).isEqual(to: edited))
        try #require(document.undo.canUndo)
        m.textView.setSelectedRange(NSRange(location: 0, length: 0))
        await settle()

        let targetOffset = (edited as NSString).range(of: "token-600 ").location
        try #require(targetOffset != NSNotFound)
        let initialLine = try line(containing: targetOffset, in: m.textView)
        try #require(initialLine.elementOffset == (Self.prefix as NSString).length,
                     "line ranges must be converted from the long paragraph's local UTF-16 coordinates")
        try #require(initialLine.localOffset > 0, "the anchor must be inside the wrapped paragraph")
        m.scrollView.contentView.scroll(to: NSPoint(x: m.scrollView.contentView.bounds.origin.x,
                                                   y: initialLine.documentY))
        m.scrollView.reflectScrolledClipView(m.scrollView.contentView)
        await settle()
        let pinOffset = initialLine.sourceOffset
        let before = try line(containing: pinOffset, in: m.textView)
        try #require(abs(before.documentY - m.textView.visibleRect.minY) < 1,
                     "the measured source line must start at the viewport's top")
        let previousWrapWidth = try #require(m.textView.textContainer?.size.width)
        try #require(m.coordinator.lastReadingPosition != nil)
        let captured = try #require(m.textView.readingPosition())
        let encoded = try JSONEncoder().encode(captured)
        let decoded = try JSONDecoder().decode(ReadingPosition.self, from: encoded)
        let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(fields.keys) == ["anchorOffset", "offsetInViewport", "magnification"])

        m.window.setContentSize(NSSize(width: 500, height: 500))
        m.container.layoutSubtreeIfNeeded()
        m.scrollView.frame = m.container.bounds
        m.scrollView.tile()
        await settle(12)

        try #require(abs(m.container.bounds.width - 500) < 1, "the window must resize its content mount")
        try #require(abs(m.scrollView.frame.width - 500) < 1, "the retained host must resize its native surface")
        let currentWrapWidth = try #require(m.textView.textContainer?.size.width)
        try #require(currentWrapWidth < previousWrapWidth - 100, "the width change must actually reflow the paragraph")
        let after = try line(containing: pinOffset, in: m.textView)
        #expect(abs(after.windowY - before.windowY) < 1,
                "the same source character's line moved \(after.windowY - before.windowY)pt during reflow")
        #expect(m.textView.restore(decoded))
        await settle(3)
        let restored = try line(containing: pinOffset, in: m.textView)
        #expect(abs(restored.windowY - before.windowY) < 1,
                "a serialized reading position must preserve the same visible source line")
        #expect((m.textView.string as NSString).isEqual(to: edited))
        #expect((document.text as NSString).isEqual(to: edited))
        document.undo.undo()
        m.coordinator.commitTextSync(for: m.textView)
        #expect((m.textView.string as NSString).isEqual(to: Self.source))
        #expect((document.text as NSString).isEqual(to: Self.source))
        #expect(document.undo.canRedo)
        document.undo.redo()
        m.coordinator.commitTextSync(for: m.textView)
        #expect((m.textView.string as NSString).isEqual(to: edited))
        #expect((document.text as NSString).isEqual(to: edited))
    }

    @Test("the existing Codable paragraph anchor still restores its first source line")
    func legacyParagraphPositionRestores() async throws {
        let document = Document(Self.source)
        let m = try await mount(document, magnification: 1)
        defer {
            NativeTextViewWrapper.dismantleNSView(m.scrollView, coordinator: m.coordinator)
            document.undo.removeAllActions()
            m.window.orderOut(nil)
        }
        let paragraphOffset = (Self.prefix as NSString).length
        let legacyJSON = Data("{\"anchorOffset\":\(paragraphOffset),\"offsetInViewport\":-1200,\"magnification\":1}".utf8)
        let legacy = try JSONDecoder().decode(ReadingPosition.self, from: legacyJSON)
        #expect(legacy == ReadingPosition(anchorOffset: paragraphOffset, offsetInViewport: -1200))
        let firstLine = try line(containing: paragraphOffset, in: m.textView)
        #expect(m.textView.restore(legacy))
        await settle(3)
        #expect(abs(m.textView.visibleRect.minY - (firstLine.documentY + 1200)) < 1)
        #expect((m.textView.string as NSString).isEqual(to: Self.source))
        #expect((document.text as NSString).isEqual(to: Self.source))
    }
}
