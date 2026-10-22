import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

/// Edits that must reach exactly the intended source: span-edit admission,
/// the host's save flush during an input-method composition, and formatting
/// shortcuts with several editors in one window.
@MainActor
@Suite("Source commit safety")
struct SourceCommitSafetyTests {
    private final class Host {
        var text: String
        init(_ text: String) { self.text = text }
    }

    private struct Harness: View {
        let host: Host
        let undo: UndoManager
        var body: some View {
            NativeTextViewWrapper(
                text: Binding(get: { host.text }, set: { host.text = $0 }),
                configuration: .default,
                fontSize: 16,
                documentId: "commit-safety",
                isEditable: true,
                undoManager: undo
            )
        }
    }

    private func settle() async {
        for _ in 0..<6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
        }
    }

    private func editor(in view: NSView) -> NativeTextView? {
        if let editor = view as? NativeTextView { return editor }
        return view.subviews.lazy.compactMap(editor(in:)).first
    }

    private func mount(_ text: String, undo: UndoManager) async throws -> (NSWindow, NativeTextView, NativeTextViewCoordinator, Host) {
        _ = NSApplication.shared
        let host = Host(text)
        let hosting = NSHostingView(rootView: Harness(host: host, undo: undo))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        let view = try #require(editor(in: hosting))
        let coordinator = try #require(view.delegate as? NativeTextViewCoordinator)
        return (window, view, coordinator, host)
    }

    @Test("select-all bold on an embed-first note adds no text and undoes to the original")
    func embedFirstSpanEditIsLiteralAndUndoable() async throws {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let original = "![[cover.png]]\n\nHello world\n\nSecond line"
        let (window, view, coordinator, _) = try await mount(original, undo: undo)
        defer { window.orderOut(nil) }
        view.setSelectedRange(NSRange(location: 20, length: 0))
        await settle()

        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        undo.beginUndoGrouping()
        coordinator.didMarkdownBold(nil)
        undo.endUndoGrouping()
        await settle()

        #expect(!view.string.hasSuffix("\n"), "admission must not run the embed auto-wrap")
        #expect(view.string.contains("**"))
        #expect(undo.canUndo)
        undo.undo()
        await settle()
        #expect(view.string == original)
    }

    @Test("a list command is one undo step and publishes the source at once")
    func formatCommandIsOneUndoStep() async throws {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let original = "one\ntwo"
        let (window, view, coordinator, host) = try await mount(original, undo: undo)
        defer { window.orderOut(nil) }
        view.setSelectedRange(NSRange(location: 0, length: (original as NSString).length))

        coordinator.apply(.bulletedList)

        #expect(view.string == "- one\n- two")
        #expect(host.text == "- one\n- two")
        undo.undo()
        await settle()
        #expect(view.string == original)
    }

    @Test("a save flush mid-composition publishes the committed text and keeps the composition open")
    func flushDuringCompositionPublishesCommittedSource() async throws {
        let undo = UndoManager()
        let (window, view, coordinator, host) = try await mount("Start\n", undo: undo)
        defer { window.orderOut(nil) }
        let end = (view.string as NSString).length
        view.setSelectedRange(NSRange(location: end, length: 0))
        view.insertText("Hello", replacementRange: NSRange(location: end, length: 0))
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())

        let flushed = coordinator.commitPendingTextNow()

        #expect(flushed == "Start\nHello")
        #expect(host.text == "Start\nHello")
        #expect(view.hasMarkedText(), "the input method keeps its composition")
    }

    @Test("⌘B formats only the focused editor when two share a window")
    func formattingShortcutRequiresFocus() async throws {
        _ = NSApplication.shared
        let firstHost = Host("left words here")
        let secondHost = Host("right words here")
        let first = NSHostingView(rootView: Harness(host: firstHost, undo: UndoManager()))
        let second = NSHostingView(rootView: Harness(host: secondHost, undo: UndoManager()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        first.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        second.frame = NSRect(x: 400, y: 0, width: 400, height: 400)
        container.addSubview(first)
        container.addSubview(second)
        window.contentView = container
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        await settle()
        let left = try #require(editor(in: first))
        let right = try #require(editor(in: second))
        left.setSelectedRange(NSRange(location: 0, length: 4))
        right.setSelectedRange(NSRange(location: 0, length: 5))
        window.makeFirstResponder(right)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "b",
            charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11
        ))

        #expect(!left.performKeyEquivalent(with: event))
        #expect(left.string == "left words here")
        #expect(right.performKeyEquivalent(with: event))
        #expect(right.string == "**right** words here")
    }
}
