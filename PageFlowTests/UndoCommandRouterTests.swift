import AppKit
import SwiftUI
import MarkdownEngine
import Testing
import Observation
@testable import PageFlow

@MainActor
@Suite("Native field Undo command ownership", .serialized)
struct UndoCommandRouterTests {
    @MainActor
    private final class ChangeProbe { var changed = false }

    /// The key window the routers under test see. A test host started in the
    /// background is never allowed to become active, so its windows never
    /// become key for real; each mount names its window and posts the
    /// notification AppKit would.
    @MainActor
    private final class KeyWindow {
        static let shared = KeyWindow()
        weak var window: NSWindow?

        func make(_ window: NSWindow) {
            self.window = window
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        }
    }

    @MainActor
    private struct Fixture {
        let content: MarkdownContent
        let window: NSWindow
        let bar: NSHostingView<SearchBar>
        let native: NSTextView
        let router: UndoCommandRouter

        func field(_ placeholder: String) throws -> NSTextField {
            func fields(in view: NSView) -> [NSTextField] {
                let own = (view as? NSTextField).map { [$0] } ?? []
                return own + view.subviews.flatMap { fields(in: $0) }
            }
            let matching = fields(in: bar).filter {
                $0.isEditable && ($0.placeholderString ?? $0.placeholderAttributedString?.string) == placeholder
            }
            try #require(matching.count == 1, "Expected exactly one native \(placeholder) field")
            return matching[0]
        }

        func focus(_ placeholder: String) async throws -> NSTextView {
            let field = try field(placeholder)
            try #require(window.makeFirstResponder(field))
            try await settle {
                guard let editor = field.currentEditor() as? NSTextView else { return false }
                return KeyWindow.shared.window === window && editor.isFieldEditor && window.firstResponder === editor
            }
            let editor = try #require(field.currentEditor() as? NSTextView)
            try #require(field.cell?.allowsUndo == true && editor.allowsUndo, "Native field Undo must be enabled by the control")
            try #require(editor.undoManager != nil && editor.undoManager !== content.undoManager)
            return editor
        }

        func settle(_ condition: () -> Bool) async throws {
            let deadline = Date(timeIntervalSinceNow: 2)
            repeat {
                window.contentView?.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            } while Date() < deadline
            try #require(condition(), "Native field did not settle")
        }

        var availability: UndoAvailability {
            router.availability(fallback: content.undoAvailability)
        }

        func watchAvailability() -> ChangeProbe {
            let probe = ChangeProbe()
            withObservationTracking { _ = availability } onChange: {
                Task { @MainActor in probe.changed = true }
            }
            return probe
        }

        func close() {
            window.makeFirstResponder(nil)
            content.cleanup()
            window.close()
        }
    }

    private func mount() async throws -> Fixture {
        _ = NSApplication.shared
        let content = MarkdownContent(documentId: UUID().uuidString)
        content.documentManager.text = "needle document"
        content.searchManager.setShowingReplacement(true)
        let editor = MarkdownEditorView(
            text: Binding(get: { content.documentManager.text }, set: { content.documentManager.text = $0 }),
            documentId: content.documentId, editorController: content.editorController,
            bus: content.bus, isFocused: true, pageLook: false, undoManager: content.undoManager
        )
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 700, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var mounted = false
        defer { if !mounted { content.cleanup(); window.close() } }
        let container = MarkdownEditorSurfaceContainer(frame: NSRect(x: 0, y: 0, width: 700, height: 280))
        let surface = RetainedMarkdownEditorSurface(editor: editor)
        content.retainedEditorSurface = surface
        let bar = NSHostingView(rootView: SearchBar(driver: content.searchManager, isVisible: .constant(true), focusRequest: 1))
        let stack = NSStackView(views: [container, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        window.contentView = stack
        container.heightAnchor.constraint(equalToConstant: 280).isActive = true
        container.widthAnchor.constraint(equalToConstant: 700).isActive = true
        surface.attach(to: container, editor: editor)
        window.orderFront(nil)
        func textView(in view: NSView) -> NSTextView? {
            if let textView = view as? NSTextView { return textView }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        let deadline = Date(timeIntervalSinceNow: 2)
        while textView(in: container)?.string != content.documentManager.text && Date() < deadline {
            stack.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let native = try #require(textView(in: container))
        try #require(native.string == "needle document", "Source must mount before creating document history")
        content.undoManager.beginUndoGrouping()
        native.insertText("edited ", replacementRange: NSRange(location: 0, length: 0))
        native.breakUndoCoalescing()
        content.undoManager.endUndoGrouping()
        content.reconcileLiveText()
        let fixture = Fixture(content: content, window: window, bar: bar, native: native,
                              router: UndoCommandRouter { KeyWindow.shared.window })
        try await fixture.settle { content.undoAvailability.canUndo }
        KeyWindow.shared.make(window)
        _ = try await fixture.focus("Search")
        mounted = true
        return fixture
    }

    @Test("An untouched focused Find field cannot undo the document")
    func emptyFieldBlocksDocumentUndo() async throws {
        let fixture = try await mount()
        defer { fixture.close() }
        _ = try await fixture.focus("Search")
        let source = fixture.native.string
        #expect(fixture.content.undoManager.canUndo)
        #expect(fixture.availability == UndoAvailability())
        fixture.router.undo(fallback: fixture.content.undoManager)
        #expect(fixture.native.string == source)
        #expect(fixture.content.undoManager.canUndo)
        #expect(!fixture.content.undoManager.canRedo)
    }

    @Test("Find and replacement typing Undo stays in its native field", arguments: ["Search", "Replace with"])
    func fieldUndoStaysInField(placeholder: String) async throws {
        let fixture = try await mount()
        defer { fixture.close() }
        let editor = try await fixture.focus(placeholder)
        let source = fixture.native.string
        let dirty = fixture.content.documentManager.isDirty
        editor.insertText("needle-new", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.breakUndoCoalescing()
        try await fixture.settle { fixture.availability.canUndo }
        fixture.router.undo(fallback: fixture.content.undoManager)
        try await fixture.settle { editor.string.isEmpty && fixture.availability.canRedo }
        fixture.router.redo(fallback: fixture.content.undoManager)
        try await fixture.settle { editor.string == "needle-new" }
        #expect(fixture.native.string == source)
        #expect(fixture.content.documentManager.isDirty == dirty)
        #expect(fixture.content.undoManager.canUndo && !fixture.content.undoManager.canRedo)
    }

    /// AppKit posts no text-change notification for an Undo in an inactive
    /// app, so the binding can only be checked when the test host can come
    /// to the front; unattended it is reported as skipped, not passed.
    @Test("Find and replacement Undo republishes the field binding",
          .enabled("needs an active test host") {
              await MainActor.run { NSApp.activate(ignoringOtherApps: true) }
              try await Task.sleep(for: .milliseconds(500))
              return await MainActor.run { NSApp.isActive }
          },
          arguments: ["Search", "Replace with"])
    func fieldUndoPublishesBinding(placeholder: String) async throws {
        let fixture = try await mount()
        defer { fixture.close() }
        // The host is active here (see the trait); SwiftUI publishes a field
        // Undo from the real key window only, so make this one key for real.
        fixture.window.makeKeyAndOrderFront(nil)
        try await fixture.settle { NSApp.keyWindow === fixture.window }
        let editor = try await fixture.focus(placeholder)
        let driver = fixture.content.searchManager
        func binding() -> String { placeholder == "Search" ? driver.query : driver.replacementText }
        editor.insertText("needle-new", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.breakUndoCoalescing()
        try await fixture.settle { binding() == "needle-new" }
        fixture.router.undo(fallback: fixture.content.undoManager)
        try await fixture.settle { binding().isEmpty }
        fixture.router.redo(fallback: fixture.content.undoManager)
        try await fixture.settle { binding() == "needle-new" }
    }

    @Test("Command availability follows the reused field editor and resumes document Undo")
    func focusTransitions() async throws {
        let fixture = try await mount()
        defer { fixture.close() }
        let query = try await fixture.focus("Search")
        // Settle the initial focus callbacks before tracking the next change.
        try await Task.sleep(for: .milliseconds(30))
        let typed = fixture.watchAvailability()
        query.insertText("query", replacementRange: NSRange(location: 0, length: 0))
        query.breakUndoCoalescing()
        try await fixture.settle { typed.changed }
        #expect(fixture.availability.canUndo)
        let replacementFocus = fixture.watchAvailability()
        _ = try await fixture.focus("Replace with")
        try await fixture.settle { replacementFocus.changed }
        #expect(fixture.availability == UndoAvailability())
        let documentFocus = fixture.watchAvailability()
        try #require(fixture.window.makeFirstResponder(fixture.native))
        try await fixture.settle { documentFocus.changed }
        #expect(fixture.availability.canUndo)
        fixture.router.undo(fallback: fixture.content.undoManager)
        #expect(fixture.native.string == "needle document")
        #expect(fixture.content.undoManager.canRedo)
    }

    @Test("Switching key windows retires the old field command owner")
    func keyWindowTransitions() async throws {
        let first = try await mount()
        defer { first.close() }
        let firstField = try await first.focus("Search")
        firstField.insertText("first-query", replacementRange: NSRange(location: 0, length: 0))
        firstField.breakUndoCoalescing()
        try await first.settle { first.availability.canUndo }
        try await Task.sleep(for: .milliseconds(30))
        let keyChange = first.watchAvailability()
        let firstSource = first.native.string
        let second = try await mount()
        defer { second.close() }
        try await second.settle { keyChange.changed }
        #expect(first.availability == UndoAvailability())
        let secondSource = second.native.string
        first.router.undo(fallback: first.content.undoManager)
        #expect(first.content.searchManager.query == "first-query")
        #expect(first.native.string == firstSource)
        #expect(second.native.string == secondSource)
        #expect(first.content.undoManager.canUndo && second.content.undoManager.canUndo)
    }
}
