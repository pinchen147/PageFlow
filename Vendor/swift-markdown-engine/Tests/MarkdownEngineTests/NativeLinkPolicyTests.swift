import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Native link navigation", .serialized)
struct NativeLinkPolicyTests {
    @MainActor
    private final class Editor {
        let coordinator: NativeTextViewCoordinator
        let scrollView: NSScrollView
        let textView: NativeTextView
        var clicks: [String] = []

        init() throws {
            let wrapper = NativeTextViewWrapper(text: .constant("link"), documentId: "links")
            coordinator = wrapper.makeCoordinator()
            scrollView = wrapper.makeNativeView(coordinator: coordinator)
            scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            wrapper.updateNativeView(scrollView, coordinator: coordinator)
            textView = try #require(scrollView.nativeTextView)
            coordinator.onLinkClick = { [weak self] in self?.clicks.append($0) }
        }

        func click(_ link: Any) -> Bool {
            coordinator.textView(textView, clickedOnLink: link, at: 0)
        }

        func close() {
            NativeTextViewWrapper.dismantleNSView(scrollView, coordinator: coordinator)
        }
    }

    private func drainCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test("URL values use the native fallback only for web and mail schemes", arguments: [
        ("http://example.com", false),
        ("HTTPS://example.com", false),
        ("mailto:reader@example.com", false),
        ("file:///tmp/note.md", true),
        ("javascript:alert(1)", true),
        ("custom:open", true),
        ("relative/note.md", true)
    ])
    func URLFallbackPolicy(value: String, consumed: Bool) async throws {
        for hasWikiMetadata in [false, true] {
            let editor = try Editor()
            defer { editor.close() }
            // Even stale wiki metadata must never turn a URL into an opaque wiki id.
            if hasWikiMetadata {
                editor.textView.textStorage?.addAttribute(.wikiLinkID, value: "wiki-id",
                                                          range: NSRange(location: 0, length: 4))
            }
            let url = try #require(URL(string: value))
            #expect(editor.click(url) == consumed)
            await drainCallbacks()
            #expect(editor.clicks.isEmpty)
        }
    }

    @Test("local links go to the host's hook; other schemes never do", arguments: [
        ("relative/note.md", true),
        ("file:///tmp/note.md", true),
        ("#Heading", true),
        ("javascript:alert(1)", false),
        ("custom:open", false),
        ("https://example.com", false),
    ])
    func localLinksReachTheHost(value: String, reachesHost: Bool) async throws {
        let editor = try Editor()
        defer { editor.close() }
        var opened: [URL] = []
        editor.coordinator.onOpenLocalLink = { opened.append($0) }
        let url = try #require(URL(string: value))
        _ = editor.click(url)
        await drainCallbacks()
        #expect(opened == (reachesHost ? [url] : []))
    }

    @Test("opaque wiki strings navigate once with their original identifier")
    func opaqueWikiIdentifier() async throws {
        let editor = try Editor()
        defer { editor.close() }
        let identifier = "custom:opaque/😀"
        #expect(editor.click(identifier))
        #expect(editor.clicks.isEmpty)
        await drainCallbacks()
        #expect(editor.clicks == [identifier])
    }

    @Test("composition consumes link clicks without navigating")
    func compositionBlocksNavigation() async throws {
        let editor = try Editor()
        defer { editor.close() }
        editor.textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                                     replacementRange: NSRange(location: 0, length: 0))
        try #require(editor.textView.hasMarkedText())
        #expect(editor.click("opaque-id"))
        #expect(editor.click(try #require(URL(string: "https://example.com"))))
        await drainCallbacks()
        #expect(editor.clicks.isEmpty)
    }

    @Test("unknown link objects are consumed without native fallback")
    func unknownObjectsAreConsumed() async throws {
        let editor = try Editor()
        defer { editor.close() }
        #expect(editor.click(NSObject()))
        await drainCallbacks()
        #expect(editor.clicks.isEmpty)
    }

    @Test("invalid link indices preserve opaque identifiers without reading outside storage", arguments: [-1, 4, 100])
    func invalidIndices(index: Int) async throws {
        let editor = try Editor()
        defer { editor.close() }
        #expect(editor.coordinator.textView(editor.textView, clickedOnLink: "opaque-id", at: index))
        await drainCallbacks()
        #expect(editor.clicks == ["opaque-id"])
    }

    @Test("empty storage still accepts an opaque link identifier")
    func emptyStorage() async throws {
        let editor = try Editor()
        defer { editor.close() }
        editor.textView.string = ""
        #expect(editor.click("opaque-id"))
        await drainCallbacks()
        #expect(editor.clicks == ["opaque-id"])
    }

    @Test("queued navigation is discarded when the document lifetime changes")
    func documentSwitchDiscardsQueuedNavigation() async throws {
        let editor = try Editor()
        defer { editor.close() }
        #expect(editor.click("outgoing-id"))
        editor.coordinator.cancelDocumentWork()
        await drainCallbacks()
        #expect(editor.clicks.isEmpty)
    }
}
