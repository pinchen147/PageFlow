import AppKit
import SwiftUI
import MarkdownEngine
import Testing
@testable import PageFlow

@MainActor
@Suite(.serialized)
struct PlaceholderDismissalTests {
    /// Real registered windows and close notifications, kept off screen so the
    /// test host cannot terminate when its last visible window closes.
    @MainActor
    private final class Window: NSWindow {
        var closes = 0
        override func makeKeyAndOrderFront(_ sender: Any?) {}
        override func orderFrontRegardless() {}
        override func close() { closes += 1; super.close() }
    }

    private func window(for owner: TabManager) -> Window {
        let window = Window(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        WindowRegistry.shared.register(owner, window: window)
        return window
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }

    @Test(arguments: [false, true])
    func duplicateOpenPreservesUntitledMarkdownAndNativeUndo(edited: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("duplicate-target-\(UUID()).md")
        let targetBytes = Data("# Existing document\n".utf8)
        try targetBytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let target = TabManager()
        await target.openDocument(url: url, isSecurityScoped: false)?.value
        let targetSession = try #require(target.activeSession)
        let targetWindow = window(for: target)
        let source = TabManager()
        source.newMarkdownDocument()
        let session = try #require(source.activeSession)
        let content = try #require(session.content.markdown)
        let sourceWindow = window(for: source)
        defer {
            WindowRegistry.shared.unregister(source)
            WindowRegistry.shared.unregister(target)
            content.cleanup()
            sourceWindow.close()
            targetWindow.close()
        }
        let seed = content.documentManager.text
        let editor = MarkdownEditorView(
            text: Binding(get: { [weak content] in content?.documentManager.text ?? "" },
                          set: { [weak content] in content?.documentManager.text = $0 }),
            documentId: content.documentId, editorController: content.editorController,
            bus: content.bus, isFocused: false, pageLook: false, undoManager: content.undoManager)
        let surface = RetainedMarkdownEditorSurface(editor: editor)
        content.retainedEditorSurface = surface
        let container = MarkdownEditorSurfaceContainer(frame: sourceWindow.contentView!.bounds)
        sourceWindow.contentView = container
        surface.attach(to: container, editor: editor)
        let native = try #require(textView(in: container))
        try #require(native.string == seed)
        try #require(!content.documentManager.isDirty)
        let suffix = "native unsaved e\u{301} 😀"
        if edited {
            content.undoManager.beginUndoGrouping()
            native.insertText(suffix, replacementRange: NSRange(location: (seed as NSString).length, length: 0))
            native.breakUndoCoalescing()
            content.undoManager.endUndoGrouping()
            try #require(native.string == seed + suffix)
            try #require(content.documentManager.text == seed,
                         "Exercise duplicate routing before deferred source publication")
            try #require(content.undoManager.canUndo)
        }

        await source.openDocument(url: url, isSecurityScoped: false)?.value
        await drainMainQueue()

        #expect(sourceWindow.closes == 0)
        #expect(WindowRegistry.shared.window(for: source) === sourceWindow)
        #expect(source.activeSession === session)
        #expect(!content.documentManager.isClosed)
        #expect(content.retainedEditorSurface === surface)
        #expect(native.string == seed + (edited ? suffix : ""))
        #expect(target.activeSession === targetSession)
        #expect(try Data(contentsOf: url) == targetBytes)
        if edited {
            // Do not invoke Undo on a destroyed editor after a failed precondition.
            try #require(content.undoManager.canUndo, "Duplicate open discarded the native undo history")
            content.undoManager.undo()
            #expect(native.string == seed)
            content.undoManager.redo()
            #expect(native.string == seed + suffix)
        }
    }

    @Test
    func deferredPlaceholderCloseDoesNotDiscardANewMarkdownDocument() async throws {
        let owner = TabManager()
        let window = window(for: owner)
        defer { WindowRegistry.shared.unregister(owner); window.close() }
        try #require(owner.hasOnlyPlaceholderTab)
        try #require(owner.dismissPlaceholderWindowIfNeeded())
        owner.newMarkdownDocument()
        let session = try #require(owner.activeSession)
        let content = try #require(session.content.markdown)
        content.documentManager.text = "draft created before queued dismissal"
        await drainMainQueue()
        #expect(window.closes == 0)
        #expect(WindowRegistry.shared.window(for: owner) === window)
        #expect(owner.activeSession === session)
        #expect(content.documentManager.text == "draft created before queued dismissal")
        #expect(!content.documentManager.isClosed)
    }

    @Test
    func deferredPlaceholderCloseCannotCloseAnOldWindowAfterReregistration() async throws {
        let owner = TabManager()
        let original = window(for: owner)
        defer { original.close() }
        try #require(owner.dismissPlaceholderWindowIfNeeded())
        let successor = window(for: owner)
        defer { WindowRegistry.shared.unregister(owner); successor.close() }
        await drainMainQueue()
        #expect(original.closes == 0)
        #expect(successor.closes == 0)
        #expect(WindowRegistry.shared.window(for: owner) === successor)
        #expect(owner.hasOnlyPlaceholderTab)
    }

    @Test
    func unchangedPDFPlaceholderStillCloses() async throws {
        let owner = TabManager()
        let window = window(for: owner)
        defer { WindowRegistry.shared.unregister(owner) }
        try #require(owner.hasOnlyPlaceholderTab)
        try #require(owner.dismissPlaceholderWindowIfNeeded())
        await drainMainQueue()
        #expect(window.closes == 1)
        #expect(WindowRegistry.shared.window(for: owner) == nil)
        #expect(owner.tabs.isEmpty)
    }
}
