//
//  HostUndoRoutingTests.swift
//  MarkdownEngineTests
//
//  Fork knob: a host-supplied per-document UndoManager must be what the text
//  view registers edits into (via the coordinator's `undoManager(for:)`), so
//  the host's Edit menu and the editor operate ONE stack — and per-document
//  histories survive document switches on a reused editor.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Host undo routing")
struct HostUndoRoutingTests {

    private final class State { var text: String; init(_ t: String) { text = t } }

    private func makeEditor(text: String) -> (NativeTextViewCoordinator, NativeTextView) {
        _ = NSApplication.shared
        let state = State(text)
        let coordinator = NativeTextViewCoordinator(
            text: Binding(get: { state.text }, set: { state.text = $0 }),
            fontName: NSFont.systemFont(ofSize: 16).fontName,
            fontSize: 16,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        textView.string = text
        textView.isEditable = true
        textView.allowsUndo = true
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        return (coordinator, textView)
    }

    @Test func delegateReturnsHostManagerWhenSupplied() {
        let (coordinator, textView) = makeEditor(text: "hello")
        let host = UndoManager()
        coordinator.hostUndoManager = host
        #expect(coordinator.undoManager(for: textView) === host)
        coordinator.hostUndoManager = nil
        #expect(coordinator.undoManager(for: textView) == nil, "no window in this harness → nil fallback")
    }

    @Test func textViewRegistersEditsIntoHostManager() {
        let (coordinator, textView) = makeEditor(text: "hello")
        let host = UndoManager()
        host.groupsByEvent = false   // deterministic grouping in a headless test
        coordinator.hostUndoManager = host
        #expect(!host.canUndo)

        host.beginUndoGrouping()
        textView.insertText(" world", replacementRange: NSRange(location: 5, length: 0))
        host.endUndoGrouping()

        #expect(textView.string.hasPrefix("hello world"))
        #expect(host.canUndo, "the edit must land in the HOST manager")

        host.undo()
        #expect(textView.string.hasPrefix("hello") && !textView.string.contains("world"))
    }
}
