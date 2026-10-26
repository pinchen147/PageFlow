import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Native selection lifetime", .serialized)
struct NativeSelectionLifetimeTests {
    @MainActor
    private final class State {
        var wikiActive = false
        var rectangles: [CGRect] = []
        var selections: [InlineSelectionState?] = []
        var selectionNotificationObjects: [String?] = []
    }

    @MainActor
    private final class Editor {
        let state = State()
        let coordinator: NativeTextViewCoordinator
        let scrollView: NSScrollView
        let textView: NativeTextView
        private let observer: NSObjectProtocol

        init() throws {
            let state = state
            let name = Notification.Name("SelectionLifetime-" + UUID().uuidString)
            var configuration = MarkdownEditorConfiguration.default
            configuration.services.bus = MarkdownEditorBus(selectionBoldDidChange: name, scopeByObject: true)
            let wrapper = NativeTextViewWrapper(
                text: .constant("[[note|id]] plain"),
                isWikiLinkActive: Binding(get: { state.wikiActive }, set: { state.wikiActive = $0 }),
                configuration: configuration,
                documentId: "selection-document",
                onCaretRectChange: { state.rectangles.append($0) },
                onInlineSelectionChange: { state.selections.append($0) }
            )
            coordinator = wrapper.makeCoordinator()
            scrollView = wrapper.makeNativeView(coordinator: coordinator)
            scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            wrapper.updateNativeView(scrollView, coordinator: coordinator)
            textView = try #require(scrollView.nativeTextView)
            observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { notification in
                MainActor.assumeIsolated { state.selectionNotificationObjects.append(notification.object as? String) }
            }
        }

        func prepare() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            // A programmatic selection has no keyboard event; removing the link
            // attribute exercises the preview path rather than mouse navigation.
            textView.delegate = nil
            textView.setSelectedRange(NSRange(location: 3, length: 0))
            textView.textStorage?.removeAttribute(.link, range: NSRange(location: 0, length: textView.string.utf16.count))
            textView.delegate = coordinator
            state.rectangles.removeAll()
            state.selections.removeAll()
            state.selectionNotificationObjects.removeAll()
            state.wikiActive = false
        }

        func notifySelection() {
            coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification,
                                                               object: textView))
        }

        func close() {
            NotificationCenter.default.removeObserver(observer)
            NativeTextViewWrapper.dismantleNSView(scrollView, coordinator: coordinator)
        }
    }

    private func drainCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test("current-document selection retains synchronous scoped state and queued previews")
    func currentSelectionPublishes() async throws {
        let editor = try Editor()
        defer { editor.close() }
        await editor.prepare()
        editor.notifySelection()
        #expect(editor.state.selectionNotificationObjects == ["selection-document"])
        #expect(editor.state.rectangles.isEmpty)
        await drainCallbacks()
        #expect(editor.state.rectangles.count == 1)
        #expect(editor.state.selections.count == 1)
        #expect(editor.state.selections.compactMap { $0 }.first?.kind == .wikiLink)
        #expect(editor.state.wikiActive)
    }

    @Test("queued selection previews cannot publish into another document")
    func changedDocumentDiscardsPreview() async throws {
        let editor = try Editor()
        defer { editor.close() }
        await editor.prepare()
        editor.notifySelection()
        editor.coordinator.cancelDocumentWork()
        await drainCallbacks()
        #expect(editor.state.rectangles.isEmpty)
        #expect(editor.state.selections.isEmpty)
        #expect(!editor.state.wikiActive)
    }

    @Test("transient marked-input selection changes defer all publication", arguments: [false, true])
    func transientCompositionDefersSelection(committing: Bool) async throws {
        let editor = try Editor()
        defer { editor.close() }
        await editor.prepare()
        editor.textView.isSettingMarkedText = !committing
        editor.textView.isCommittingMarkedText = committing
        defer {
            editor.textView.isSettingMarkedText = false
            editor.textView.isCommittingMarkedText = false
        }
        #expect(!editor.textView.hasMarkedText())
        editor.notifySelection()
        editor.coordinator.updateSelectionStates(editor.textView)
        await drainCallbacks()
        #expect(editor.coordinator.pendingCompositionRefresh)
        #expect(editor.state.selectionNotificationObjects.isEmpty)
        #expect(editor.state.rectangles.isEmpty)
        #expect(editor.state.selections.isEmpty)
        #expect(!editor.state.wikiActive)
    }

    @Test("composition starting before a queued preview suppresses that preview")
    func queuedPreviewChecksCurrentComposition() async throws {
        let editor = try Editor()
        defer { editor.close() }
        await editor.prepare()
        editor.notifySelection()
        editor.textView.isSettingMarkedText = true
        defer { editor.textView.isSettingMarkedText = false }
        await drainCallbacks()
        #expect(editor.state.rectangles.isEmpty)
        #expect(editor.state.selections.isEmpty)
        #expect(!editor.state.wikiActive)
    }
}
