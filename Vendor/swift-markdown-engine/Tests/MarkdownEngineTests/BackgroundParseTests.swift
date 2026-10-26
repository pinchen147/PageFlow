//
//  BackgroundParseTests.swift
//  MarkdownEngineTests
//
//  A note past `backgroundParseThreshold` paints its text at mount without
//  parsing it, and gains its Markdown styling when the background parse lands.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@Suite("Background parse", .serialized)
@MainActor
struct BackgroundParseTests {
    typealias H = TableOverlayEndToEndTests

    private static let note: String = {
        let paragraph = "Plain prose with *emphasis* and `code` continues here for a while and wraps at the column."
        var parts = ["# First heading"]
        while parts.reduce(0, { $0 + $1.utf16.count + 2 }) < NativeTextViewCoordinator.backgroundParseThreshold + 50_000 {
            parts.append(paragraph)
        }
        parts.append("## Last heading")
        return parts.joined(separator: "\n\n")
    }()

    private func findEditor(in view: NSView) -> NativeTextView? {
        if let tv = view as? NativeTextView { return tv }
        for sub in view.subviews { if let found = findEditor(in: sub) { return found } }
        return nil
    }

    private func headingFontSize(_ tv: NativeTextView) -> CGFloat {
        (tv.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
    }

    @Test("a very long note paints its text at once and is styled when the parse lands")
    func longNotePaintsThenStyles() async throws {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: H.EditorHarnessView(host: H.Host(text: Self.note), configuration: .default))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        let tv = try #require(findEditor(in: hosting))
        let coordinator = try #require(tv.delegate as? NativeTextViewCoordinator)
        #expect(tv.string == Self.note, "the text did not paint at mount")
        #expect(coordinator.cachedParsedDocument == nil, "the mount parsed the note in place")
        let baseSize = headingFontSize(tv)

        for _ in 0..<500 where coordinator.cachedParsedDocument == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(coordinator.cachedParsedDocument != nil, "the background parse never landed")
        #expect(headingFontSize(tv) > baseSize, "the heading was not styled after the parse")
    }

    private func lastHeadingFontSize(_ tv: NativeTextView) -> CGFloat {
        let at = (tv.string as NSString).length - 3
        return (tv.textStorage?.attribute(.font, at: at, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
    }

    /// A click or a keystroke before the parse lands parses on main and styles
    /// only the caret's paragraphs; the landing still owes the rest its style.
    @Test("an early click or keystroke does not leave the rest of the note unstyled",
          arguments: ["click", "type"])
    func earlyInteractionStillStylesTheNote(_ interaction: String) async throws {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: H.EditorHarnessView(host: H.Host(text: Self.note), configuration: .default))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        let tv = try #require(findEditor(in: hosting))
        let coordinator = try #require(tv.delegate as? NativeTextViewCoordinator)
        try #require(coordinator.cachedParsedDocument == nil, "the mount parsed the note in place")
        let baseSize = lastHeadingFontSize(tv)

        if interaction == "click" {
            tv.setSelectedRange(NSRange(location: 5, length: 0))
        } else {
            tv.setSelectedRange(NSRange(location: 3, length: 0))
            tv.insertText("x", replacementRange: NSRange(location: 3, length: 0))
        }

        for _ in 0..<800 where lastHeadingFontSize(tv) <= baseSize {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(lastHeadingFontSize(tv) > baseSize, "the heading at the end of the note was never styled")
    }

    @Test("a note below the threshold is styled in place at mount")
    func shortNoteStylesInPlace() throws {
        _ = NSApplication.shared
        let text = "# First heading\n\nA short note."
        let hosting = NSHostingView(rootView: H.EditorHarnessView(host: H.Host(text: text), configuration: .default))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        let tv = try #require(findEditor(in: hosting))
        let coordinator = try #require(tv.delegate as? NativeTextViewCoordinator)
        #expect(coordinator.cachedParsedDocument != nil)
    }
}
