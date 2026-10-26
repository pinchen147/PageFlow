import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Initial native layout", .serialized)
struct NativeInitialLayoutTests {
    @MainActor private final class Source {
        var text: String
        let undo = UndoManager()
        init(_ text: String) { self.text = text }
    }

    enum Fixture: CaseIterable { case longOnly, longThenShort, shortThenLong, shortOnly }

    @Test("Initial warmup is bounded by every paragraph and final styled layout remains exact",
          arguments: [CGFloat(560), CGFloat(820)], Fixture.allCases)
    func initialLayoutUsesStyledSourceAndFinalWidth(width: CGFloat, fixture: Fixture) throws {
        _ = NSApplication.shared
        // One paragraph defeats paragraph-scoped viewport limits. This fixture
        // inspects native layout state rather than imposing a wall-clock budget.
        let longParagraph = "**Heading** " + String(repeating: "wordabcd ", count: 7_300) + "e\u{301} 😀"
        let original: String
        switch fixture {
        case .longOnly: original = longParagraph
        case .longThenShort: original = longParagraph + "\n\nShort final paragraph."
        case .shortThenLong: original = "Short initial paragraph.\n\n" + longParagraph
        case .shortOnly: original = "**Heading** short.\r\n\r\n" + String(repeating: "Short cafe\u{301} 😀 paragraph.\u{2029}", count: 400)
        }
        let source = Source(original)
        source.undo.groupsByEvent = false
        let anchor = 2_000
        let request = ReadingPositionRequest(ReadingPosition(anchorOffset: anchor, offsetInViewport: 12))
        let wrapper = NativeTextViewWrapper(
            text: Binding(get: { source.text }, set: { source.text = $0 }),
            configuration: .default, fontSize: 16, documentId: UUID().uuidString,
            undoManager: source.undo, readingPositionRequest: request)
        let coordinator = wrapper.makeCoordinator()
        let scroll = wrapper.makeNativeView(coordinator: coordinator)
        defer {
            NativeTextViewWrapper.dismantleNSView(scroll, coordinator: coordinator)
            source.undo.removeAllActions()
        }
        let text = try #require(scroll.nativeTextView)
        let layout = try #require(text.textLayoutManager)
        let rawContent = try #require(layout.textContentManager)
        var rawLayoutOffsets: [Int] = []
        // [] explicitly avoids .ensuresLayout and .estimatesSize. Merely inspect
        // existing fragment state; do not force the work the test forbids.
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) { fragment in
            if fragment.state == .layoutAvailable, let range = fragment.textElement?.elementRange {
                rawLayoutOffsets.append(rawContent.offset(from: rawContent.documentRange.location, to: range.location))
            }
            return true
        }
        #expect(!rawLayoutOffsets.isEmpty == (fixture == .shortOnly),
                "Only documents with bounded paragraphs should receive initial viewport warmup")
        if fixture != .shortOnly {
            let longParagraphStart = (original as NSString).range(of: "**Heading**").location
            #expect(!rawLayoutOffsets.contains(longParagraphStart), "The long paragraph must await styled layout")
        }
        #expect(!coordinator.didInitialFormatting)
        #expect(text.string.utf8.elementsEqual(original.utf8))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        scroll.frame = window.contentView!.bounds
        window.contentView = scroll
        scroll.layoutSubtreeIfNeeded()
        wrapper.updateNativeView(scroll, coordinator: coordinator)
        try #require(coordinator.didInitialFormatting)
        #expect(text.string.utf8.elementsEqual(original.utf8))
        let content = try #require(layout.textContentManager)
        let location = try #require(content.location(content.documentRange.location, offsetBy: anchor))
        let fragment = try #require(layout.textLayoutFragment(for: location))
        try #require(fragment.state == .layoutAvailable)
        let line = try #require(fragment.textLineFragment(for: location, isUpstreamAffinity: false))
        if fixture != .shortOnly { #expect(fragment.textLineFragments.count > 1) }
        #expect(text.frame.width > 0 && text.frame.width <= width)
        #expect(line.typographicBounds.width <= (text.textContainer?.size.width ?? 0) + 1)
        let restoredLineY = fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + text.textContainerOrigin.y
        #expect(abs(restoredLineY - text.visibleRect.minY - request.position.offsetInViewport) <= 2)
        let boldLocation = (original as NSString).range(of: "Heading").location
        let bold = try #require(text.textStorage?.attribute(.font, at: boldLocation, effectiveRange: nil) as? NSFont)
        #expect(bold.fontDescriptor.symbolicTraits.contains(.bold), "The first completed layout must include Markdown styling")

        source.undo.beginUndoGrouping()
        text.insertText("!", replacementRange: NSRange(location: (original as NSString).length, length: 0))
        text.breakUndoCoalescing()
        source.undo.endUndoGrouping()
        coordinator.commitTextSync(for: text)
        #expect(source.text.utf8.elementsEqual((original + "!").utf8))
        try #require(source.undo.canUndo)
        source.undo.undo()
        #expect(text.string.utf8.elementsEqual(original.utf8))
        source.undo.redo()
        #expect(text.string.utf8.elementsEqual((original + "!").utf8))
    }
}
