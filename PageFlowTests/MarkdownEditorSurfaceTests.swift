import AppKit
import SwiftUI
import MarkdownEngine
import Testing
@testable import PageFlow

@MainActor
@Suite("Markdown native surface lifetime", .serialized)
struct MarkdownEditorSurfaceTests {
    private func editor(for content: MarkdownContent, pageLook: Bool = false) -> MarkdownEditorView {
        MarkdownEditorView(
            text: Binding(get: { [weak content] in content?.documentManager.text ?? "" },
                          set: { [weak content] in content?.documentManager.text = $0 }),
            documentId: content.documentId,
            editorController: content.editorController,
            bus: content.bus,
            isFocused: true,
            pageLook: pageLook,
            undoManager: content.undoManager
        )
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for child in view.subviews {
            if let textView = textView(in: child) { return textView }
        }
        return nil
    }

    private func settle(_ view: NSView, until condition: () -> Bool) async throws {
        let deadline = Date(timeIntervalSinceNow: 2)
        repeat {
            view.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        } while Date() < deadline
        try #require(condition(), "Native editor did not settle")
    }

    @Test("Page look keeps one background colour: the editor paints no sheet or canvas of its own")
    func pageLookPaintsNoSheet() async throws {
        let content = MarkdownContent(documentId: UUID().uuidString)
        content.documentManager.text = "# Title\n\nBody"
        let surface = RetainedMarkdownEditorSurface(editor: editor(for: content, pageLook: true))
        content.retainedEditorSurface = surface
        let host = window()
        defer { content.cleanup(); host.close() }
        let container = MarkdownEditorSurfaceContainer(frame: host.contentView!.bounds)
        host.contentView = container
        surface.attach(to: container, editor: editor(for: content, pageLook: true))
        try await settle(container) { textView(in: container)?.string == content.documentManager.text }
        let native = try #require(textView(in: container))
        let scroll = try #require(native.enclosingScrollView)
        #expect(!native.drawsBackground, "the reading column paints a sheet over the tab background")
        #expect(!scroll.drawsBackground, "the scroll view paints a canvas around the reading column")
        #expect((native.layer?.borderWidth ?? 0) == 0, "the reading column has a sheet edge")
    }

    @Test("Go to Line reveals live native source with each document line ending", arguments: ["\n", "\r\n", "\r"])
    func goToLineUsesLiveSource(ending: String) async throws {
        let content = MarkdownContent(documentId: UUID().uuidString)
        let original = (0..<120).map { "Line \($0) 😀" }.joined(separator: ending)
            + ending + "# Target 日本語" + ending + "tail"
        content.documentManager.text = original
        let surface = RetainedMarkdownEditorSurface(editor: editor(for: content))
        content.retainedEditorSurface = surface
        let host = window()
        defer { content.cleanup(); host.close() }
        let container = MarkdownEditorSurfaceContainer(frame: host.contentView!.bounds)
        host.contentView = container
        surface.attach(to: container, editor: editor(for: content))
        try await settle(container) { textView(in: container)?.string == original }
        let native = try #require(textView(in: container))
        let layout = try #require(native.textLayoutManager)
        let text = try #require(layout.textContentManager)
        let scroll = try #require(native.enclosingScrollView)
        content.undoManager.beginUndoGrouping()
        native.insertText("新しい行" + ending, replacementRange: NSRange(location: 0, length: 0))
        native.breakUndoCoalescing()
        content.undoManager.endUndoGrouping()
        #expect(content.documentManager.text == original, "Exercise a keystroke before its durable binding publication")
        let live = native.string
        let target = (live as NSString).range(of: "# Target 日本語").location
        let dirty = content.documentManager.isDirty
        let canUndo = content.undoManager.canUndo
        let canRedo = content.undoManager.canRedo
        #expect(content.lineCount == 123)
        content.scrollToLine(121)
        #expect(native.selectedRange() == NSRange(location: target, length: 0))
        let location = try #require(text.location(text.documentRange.location, offsetBy: target))
        let fragment = try #require(layout.textLayoutFragment(for: location))
        let targetFrame = native.convert(fragment.layoutFragmentFrame.offsetBy(
            dx: native.textContainerOrigin.x, dy: native.textContainerOrigin.y), to: scroll.documentView)
        #expect(targetFrame.intersects(scroll.documentVisibleRect), "The actual target paragraph must be visible")
        #expect((native.string as NSString).isEqual(to: live))
        #expect(content.documentManager.isDirty == dirty)
        #expect(content.undoManager.canUndo == canUndo && content.undoManager.canRedo == canRedo)
        content.undoManager.undo()
        #expect((native.string as NSString).isEqual(to: original))
        #expect(!content.undoManager.canUndo)
        content.undoManager.redo()
        #expect((native.string as NSString).isEqual(to: live))
    }

    @Test("Find replacement uses pending native source and skips inserted query text")
    func replacementUsesLiveSource() async throws {
        let content = MarkdownContent(documentId: UUID().uuidString)
        content.documentManager.text = "needle e\u{301}\r\n😀 needle [[name|id]]"
        let surface = RetainedMarkdownEditorSurface(editor: editor(for: content))
        content.retainedEditorSurface = surface
        let hostWindow = window()
        defer { content.cleanup(); hostWindow.close() }
        let container = MarkdownEditorSurfaceContainer(frame: hostWindow.contentView!.bounds)
        hostWindow.contentView = container
        surface.attach(to: container, editor: editor(for: content))
        try await settle(container) { textView(in: container)?.string == content.documentManager.text }
        let native = try #require(textView(in: container))
        let original = native.string
        content.undoManager.beginUndoGrouping()
        native.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        native.breakUndoCoalescing()
        content.undoManager.endUndoGrouping()
        #expect(content.documentManager.text == original, "Exercise the unpublished native keystroke")
        let driver = content.searchManager
        driver.setQuery("needle")
        driver.runSearch()
        native.insertText("Y", replacementRange: NSRange(location: 0, length: 0))
        driver.setReplacement("needle needle")
        try #require(driver.replaceCurrent())
        #expect((native.string as NSString).isEqual(to: "YXneedle needle e\u{301}\r\n😀 needle [[name|id]]"))
        #expect(driver.resultCount == 3)
        #expect(driver.currentMatch == 3, "Advance past both inserted copies")
        driver.setReplacement("")
        try #require(driver.replaceCurrent())
        #expect((native.string as NSString).isEqual(to: "YXneedle needle e\u{301}\r\n😀  [[name|id]]"))
        #expect(driver.resultCount == 2)
        #expect(driver.currentMatch == 1)
        content.reconcileLiveText()
        #expect((content.documentManager.text as NSString).isEqual(to: native.string))
        driver.setQuery("")
        #expect(!driver.replaceCurrent())
        #expect(driver.replaceAll() == 0)
        driver.setQuery("late-hit")
        driver.runSearch()
        #expect(driver.resultCount == 0)
        native.insertText(" late-hit", replacementRange: NSRange(location: native.string.utf16.count, length: 0))
        driver.setReplacement("arrived")
        try #require(driver.replaceCurrent())
        #expect(native.string.hasSuffix(" arrived"))
    }

    @Test("Replace All stays scoped and undoable after native window reparenting")
    func replacementAfterTransferIsScoped() async throws {
        let content = MarkdownContent(documentId: UUID().uuidString)
        let other = MarkdownContent(documentId: UUID().uuidString)
        let original = "Needle\r\n😀 needle e\u{301} [[name|opaque]]"
        content.documentManager.text = original
        other.documentManager.text = "needle in other tab"
        let surface = RetainedMarkdownEditorSurface(editor: editor(for: content))
        let otherSurface = RetainedMarkdownEditorSurface(editor: editor(for: other))
        content.retainedEditorSurface = surface
        other.retainedEditorSurface = otherSurface
        let source = window(), destination = window(), otherWindow = window()
        defer { content.cleanup(); other.cleanup(); source.close(); destination.close(); otherWindow.close() }
        let sourceContainer = MarkdownEditorSurfaceContainer(frame: source.contentView!.bounds)
        let destinationContainer = MarkdownEditorSurfaceContainer(frame: destination.contentView!.bounds)
        let otherContainer = MarkdownEditorSurfaceContainer(frame: otherWindow.contentView!.bounds)
        source.contentView = sourceContainer
        destination.contentView = destinationContainer
        otherWindow.contentView = otherContainer
        surface.attach(to: sourceContainer, editor: editor(for: content))
        otherSurface.attach(to: otherContainer, editor: editor(for: other))
        try await settle(sourceContainer) { textView(in: sourceContainer)?.string == original }
        try await settle(otherContainer) { textView(in: otherContainer)?.string == "needle in other tab" }
        let native = try #require(textView(in: sourceContainer))
        let storage = try #require(native.textStorage)
        surface.attach(to: destinationContainer, editor: editor(for: content))
        surface.detach(from: sourceContainer)
        try await settle(destinationContainer) { textView(in: destinationContainer) === native }
        let driver = content.searchManager
        driver.setQuery("needle")
        driver.runSearch()
        driver.setReplacement("日本語\r\n🧭")
        #expect(driver.replaceAll() == 2)
        let expected = "日本語\r\n🧭\r\n😀 日本語\r\n🧭 e\u{301} [[name|opaque]]"
        #expect((native.string as NSString).isEqual(to: expected))
        #expect(native.textStorage === storage)
        #expect(driver.resultCount == 0)
        #expect(textView(in: otherContainer)?.string == "needle in other tab")
        #expect(!other.undoManager.canUndo)
        content.undoManager.undo()
        #expect((native.string as NSString).isEqual(to: original))
        #expect(!content.undoManager.canUndo)
        content.undoManager.redo()
        #expect((native.string as NSString).isEqual(to: expected))
        driver.setQuery("name")
        driver.runSearch()
        native.isEditable = false
        driver.setReplacement("changed")
        let rejectedSelection = native.selectedRange()
        let rejectedMatch = driver.currentMatch
        #expect(!driver.replaceCurrent())
        #expect(driver.replaceAll() == 0)
        #expect(native.selectedRange() == rejectedSelection)
        #expect(driver.currentMatch == rejectedMatch)
        #expect(driver.replacementText == "changed")
        #expect(content.undoManager.canUndo)
        #expect((native.string as NSString).isEqual(to: expected))
    }

    @Test("Save is available immediately after a native edit and persists the trailing keystroke")
    func immediateSaveUsesLiveSource() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("immediate-save-\(UUID().uuidString).md")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = TabManager()
        manager.openDocument(url: url, isSecurityScoped: false)
        let content = try #require(manager.activeMarkdownContent)
        let surface = RetainedMarkdownEditorSurface(editor: editor(for: content))
        content.retainedEditorSurface = surface
        let window = window()
        defer { content.cleanup(); window.close() }
        let container = MarkdownEditorSurfaceContainer(frame: window.contentView!.bounds)
        window.contentView = container
        surface.attach(to: container, editor: editor(for: content))
        try await settle(container) { textView(in: container)?.string == "hello" }
        let native = try #require(textView(in: container))
        native.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        #expect(content.documentManager.text == "hello", "Exercise validation before deferred publication")
        #expect(manager.canSave)
        _ = await manager.saveActiveDocument()
        #expect(try String(contentsOf: url, encoding: .utf8) == "hello!")
        #expect(!content.isDirty)
    }

    @Test("window reparenting retains native storage, selection and working undo")
    func transferKeepsTheNativeUndoTarget() async throws {
        let content = MarkdownContent(documentId: UUID().uuidString)
        content.documentManager.text = "hello"
        let root = editor(for: content)
        let surface = RetainedMarkdownEditorSurface(editor: root)
        content.retainedEditorSurface = surface
        let source = window(), destination = window()
        defer { content.cleanup(); source.close(); destination.close() }
        let sourceContainer = MarkdownEditorSurfaceContainer(frame: source.contentView!.bounds)
        let destinationContainer = MarkdownEditorSurfaceContainer(frame: destination.contentView!.bounds)
        source.contentView = sourceContainer
        destination.contentView = destinationContainer
        surface.attach(to: sourceContainer, editor: root)
        try await settle(sourceContainer) { textView(in: sourceContainer)?.string == "hello" }
        let native = try #require(textView(in: sourceContainer))
        let storage = try #require(native.textStorage)
        content.undoManager.beginUndoGrouping()
        native.insertText("X", replacementRange: NSRange(location: 5, length: 0))
        native.breakUndoCoalescing()
        content.undoManager.endUndoGrouping()
        content.reconcileLiveText()
        let selection = native.selectedRange()

        surface.attach(to: destinationContainer, editor: editor(for: content))
        // SwiftUI can dismantle or update the old mount after the new one attaches.
        surface.detach(from: sourceContainer)
        var stale = root
        stale.isDisplayed = false
        surface.update(stale, in: sourceContainer)
        try await settle(destinationContainer) { destination.firstResponder === native }

        #expect(textView(in: destinationContainer) === native)
        #expect(native.textStorage === storage)
        #expect(native.selectedRange() == selection)
        #expect(!native.isHiddenOrHasHiddenAncestor)
        #expect(content.editorController.currentStorageText == "helloX")
        content.undoManager.undo()
        #expect(native.string == "hello")
        content.undoManager.redo()
        #expect(native.string == "helloX")
    }

    @Test("real SwiftUI host transfers keep native storage and undo through a return")
    func outerHostTransferAndReturn() async throws {
        let source = TabManager(), destination = TabManager()
        source.newMarkdownDocument()
        let tabID = try #require(source.activeTabID)
        let content = try #require(source.activeMarkdownContent)
        content.documentManager.text = "native source"
        let sourceWindow = window(), destinationWindow = window()
        defer { content.cleanup(); sourceWindow.close(); destinationWindow.close() }
        func host(_ manager: TabManager) -> NSHostingView<MarkdownTabView> {
            NSHostingView(rootView: MarkdownTabView(
                tabID: tabID, content: content, isActive: true,
                showingSearch: .constant(false), searchFocusRequest: 0, tabManager: manager
            ))
        }
        let sourceHost = host(source)
        sourceWindow.contentView = sourceHost
        try await settle(sourceHost) { textView(in: sourceHost)?.string == "native source" }
        let native = try #require(textView(in: sourceHost))
        let storage = try #require(native.textStorage)
        content.undoManager.beginUndoGrouping()
        native.insertText("!", replacementRange: NSRange(location: 13, length: 0))
        native.breakUndoCoalescing()
        content.undoManager.endUndoGrouping()
        content.reconcileLiveText()

        try #require(source.moveTab(tabID, to: destination, at: 0, closeIfEmpty: false))
        let destinationHost = host(destination)
        destinationWindow.contentView = destinationHost
        try await settle(destinationHost) { textView(in: destinationHost) === native }
        #expect(native.textStorage === storage)
        #expect(native.string == "native source!")
        // The original SwiftUI mount still exists when the session returns.
        try #require(destination.moveTab(tabID, to: source, at: 0, closeIfEmpty: false))
        sourceHost.rootView = host(source).rootView
        try await settle(sourceHost) { textView(in: sourceHost) === native && sourceWindow.firstResponder === native }
        #expect(native.textStorage === storage)
        #expect(textView(in: destinationHost) == nil)
        content.undoManager.undo()
        #expect(native.string == "native source")
        content.undoManager.redo()
        #expect(native.string == "native source!")
    }

    @Test("session ownership permits a rapid return and rejects stale mounts")
    func sessionOwnerAuthorizesMounts() throws {
        let source = TabManager(), destination = TabManager()
        source.newMarkdownDocument()
        let tabID = try #require(source.activeTabID)
        let content = try #require(source.activeMarkdownContent)
        content.documentManager.text = "ownership"
        defer { content.cleanup() }
        let original = MarkdownEditorSurfaceContainer(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let moved = MarkdownEditorSurfaceContainer(frame: original.frame)
        let sourceMount = MarkdownEditorSurface(content: content, tabManager: source,
                                               tabID: tabID, editor: editor(for: content))
        let destinationMount = MarkdownEditorSurface(content: content, tabManager: destination,
                                                    tabID: tabID, editor: editor(for: content))
        sourceMount.reconcile(in: original)
        let native = try #require(textView(in: original))
        let retained = try #require(content.retainedEditorSurface)
        try #require(source.moveTab(tabID, to: destination, at: 0, closeIfEmpty: false))
        destinationMount.reconcile(in: moved)
        sourceMount.reconcile(in: original)
        retained.detach(from: original)
        #expect(retained.owner === moved)
        #expect(textView(in: moved) === native)
        try #require(destination.moveTab(tabID, to: source, at: 0, closeIfEmpty: false))
        sourceMount.reconcile(in: original)
        destinationMount.reconcile(in: moved)
        retained.detach(from: moved)
        #expect(retained.owner === original)
        #expect(textView(in: original) === native)
    }

    @Test("warm-set eviction detaches the editor and preserves working Undo until close")
    func warmEvictionPreservesUndoUntilClose() async throws {
        let manager = TabManager()
        manager.newMarkdownDocument()
        let firstID = try #require(manager.activeTabID)
        let content = try #require(manager.activeMarkdownContent)
        content.documentManager.text = "hello"
        var surface: RetainedMarkdownEditorSurface? = RetainedMarkdownEditorSurface(editor: editor(for: content))
        content.retainedEditorSurface = surface
        weak var releasedSurface = surface
        let window = window()
        defer { window.close() }
        let container = MarkdownEditorSurfaceContainer(frame: window.contentView!.bounds)
        window.contentView = container
        surface?.attach(to: container, editor: editor(for: content))
        try await settle(container) { textView(in: container)?.string == "hello" }
        let native = try #require(textView(in: container))
        content.undoManager.beginUndoGrouping()
        native.insertText("X", replacementRange: NSRange(location: 5, length: 0))
        native.breakUndoCoalescing()
        content.undoManager.endUndoGrouping()
        surface = nil

        for _ in 0..<TabManager.maxRenderedTabs { manager.newMarkdownDocument() }

        #expect(manager.renderedTabIDs.count == TabManager.maxRenderedTabs)
        #expect(!manager.renderedTabIDs.contains(firstID))
        #expect(content.documentManager.text == "helloX")
        #expect(content.pendingReadingPosition != nil)
        #expect(content.retainedEditorSurface != nil)
        #expect(releasedSurface != nil)
        #expect(container.subviews.isEmpty)
        #expect(content.undoManager.canUndo)

        manager.selectTab(firstID)
        container.reconcile(content: content, editor: editor(for: content))
        try await settle(container) { textView(in: container) === native }
        content.undoManager.undo()
        content.reconcileLiveText()
        #expect(native.string == "hello")
        #expect(content.documentManager.text == "hello")
        content.undoManager.redo()
        content.reconcileLiveText()
        #expect(native.string == "helloX")
        #expect(content.documentManager.text == "helloX")

        content.cleanup()
        #expect(content.retainedEditorSurface == nil)
        #expect(releasedSurface == nil)
        #expect(!content.undoManager.canUndo)
        #expect(!content.undoManager.canRedo)
    }

    @Test("inactive hover merges join the destination warm cap and hide the editor")
    func inactiveTransferJoinsTheWarmSet() async throws {
        let source = TabManager(), destination = TabManager()
        source.newMarkdownDocument()
        let tabID = try #require(source.activeTabID)
        let incoming = try #require(source.activeMarkdownContent)
        incoming.documentManager.text = "incoming"
        let surface = RetainedMarkdownEditorSurface(editor: editor(for: incoming))
        incoming.retainedEditorSurface = surface
        let sourceWindow = window(), destinationWindow = window()
        defer { sourceWindow.close(); destinationWindow.close() }
        let sourceContainer = MarkdownEditorSurfaceContainer(frame: sourceWindow.contentView!.bounds)
        sourceWindow.contentView = sourceContainer
        surface.attach(to: sourceContainer, editor: editor(for: incoming))
        try await settle(sourceContainer) { textView(in: sourceContainer)?.string == "incoming" }
        let native = try #require(textView(in: sourceContainer))
        destination.newMarkdownDocument()
        let oldestID = try #require(destination.activeTabID)
        let oldest = try #require(destination.activeMarkdownContent)
        oldest.retainedEditorSurface = RetainedMarkdownEditorSurface(editor: editor(for: oldest))
        for _ in 1..<TabManager.maxRenderedTabs { destination.newMarkdownDocument() }
        let activeID = destination.activeTabID

        try #require(source.moveTab(tabID, to: destination, at: 0, select: false, closeIfEmpty: false))

        #expect(destination.activeTabID == activeID)
        #expect(destination.renderedTabIDs.first == activeID)
        #expect(destination.renderedTabIDs.contains(tabID))
        #expect(destination.renderedTabIDs.count == TabManager.maxRenderedTabs)
        #expect(!destination.renderedTabIDs.contains(oldestID))
        #expect(oldest.retainedEditorSurface == nil)
        let host = NSHostingView(rootView: MarkdownTabView(
            tabID: tabID, content: incoming, isActive: false, isDisplayed: false,
            showingSearch: .constant(false), searchFocusRequest: 0, tabManager: destination
        ))
        destinationWindow.contentView = host
        try await settle(host) { textView(in: host) === native && native.isHiddenOrHasHiddenAncestor }
        surface.detach(from: sourceContainer)
        #expect(textView(in: host) === native)
        #expect(native.isHiddenOrHasHiddenAncestor)
    }

    @Test("a surviving container remounts after actual warm eviction")
    func survivingContainerRecreatesEvictedEditor() async throws {
        let content = MarkdownContent(documentId: UUID().uuidString)
        content.documentManager.text = "saved source"
        let window = window()
        defer { content.cleanup(); window.close() }
        let container = MarkdownEditorSurfaceContainer(frame: window.contentView!.bounds)
        window.contentView = container
        container.reconcile(content: content, editor: editor(for: content))
        try await settle(container) { textView(in: container)?.string == "saved source" }
        let oldNative = try #require(textView(in: container))
        content.evictEditorSurface()
        container.reconcile(content: content, editor: editor(for: content))
        try await settle(container) { textView(in: container)?.string == "saved source" }
        #expect(textView(in: container) !== oldNative)
        #expect(content.editorController.currentStorageText == "saved source")
    }

    @Test("same-container content replacement binds a fresh document and undo manager")
    func survivingContainerReplacesContent() async throws {
        let outgoing = MarkdownContent(documentId: "old-" + UUID().uuidString)
        let incoming = MarkdownContent(documentId: "new-" + UUID().uuidString)
        outgoing.documentManager.text = "old source"
        incoming.documentManager.text = "new source"
        let window = window()
        defer { incoming.cleanup(); window.close() }
        let container = MarkdownEditorSurfaceContainer(frame: window.contentView!.bounds)
        window.contentView = container
        container.reconcile(content: outgoing, editor: editor(for: outgoing))
        try await settle(container) { textView(in: container)?.string == "old source" }
        let oldNative = try #require(textView(in: container))
        outgoing.cleanup()
        container.reconcile(content: incoming, editor: editor(for: incoming))
        try await settle(container) { textView(in: container)?.string == "new source" }
        let newNative = try #require(textView(in: container))
        #expect(newNative !== oldNative)
        #expect(newNative.undoManager === incoming.undoManager)
        #expect(incoming.editorController.currentStorageText == "new source")
        incoming.undoManager.beginUndoGrouping()
        newNative.insertText("!", replacementRange: NSRange(location: 10, length: 0))
        newNative.breakUndoCoalescing()
        incoming.undoManager.endUndoGrouping()
        incoming.reconcileLiveText()
        #expect(incoming.documentManager.text == "new source!")
        #expect(outgoing.documentManager.text != "new source!")
    }

    @Test("retaining the actual tab editor does not retain its content or window manager")
    func retainedEditorHasNoOwnerCycle() async throws {
        weak var releasedContent: MarkdownContent?
        weak var releasedManager: TabManager?
        do {
            let manager = TabManager()
            manager.newMarkdownDocument()
            let content = try #require(manager.activeMarkdownContent)
            let tabID = try #require(manager.activeTabID)
            releasedContent = content
            releasedManager = manager
            let host = NSHostingView(rootView: MarkdownTabView(
                tabID: tabID, content: content, isActive: true,
                onRequestFocus: { [weak manager] in manager?.selectTab(tabID) },
                showingSearch: .constant(false), searchFocusRequest: 0, tabManager: manager
            ))
            let window = window()
            window.contentView = host
            try await settle(host) { content.retainedEditorSurface != nil && textView(in: host) != nil }
            window.contentView = nil
            window.close()
        }
        let deadline = Date(timeIntervalSinceNow: 2)
        while (releasedContent != nil || releasedManager != nil) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(releasedContent == nil)
        #expect(releasedManager == nil)
    }
}
