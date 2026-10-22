import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

/// Typing helpers (paired brackets, the `->` arrow) follow configuration: a
/// literal-Markdown host gets exactly what was typed, and nothing pairs inside
/// code.
@MainActor
@Suite("Typing helper policy")
struct TypingHelperPolicyTests {
    private final class Host {
        var text: String
        init(_ text: String) { self.text = text }
    }

    private struct Harness: View {
        let host: Host
        let configuration: MarkdownEditorConfiguration
        var body: some View {
            NativeTextViewWrapper(
                text: Binding(get: { host.text }, set: { host.text = $0 }),
                configuration: configuration,
                fontSize: 16,
                documentId: "typing-helpers",
                isEditable: true
            )
        }
    }

    private static var literal: MarkdownEditorConfiguration {
        var configuration = MarkdownEditorConfiguration.default
        configuration.inputSubstitution = .literalMarkdown
        configuration.lists.autoClosePairsEnabled = false
        return configuration
    }

    private func editor(in view: NSView) -> NativeTextView? {
        if let editor = view as? NativeTextView { return editor }
        return view.subviews.lazy.compactMap(editor(in:)).first
    }

    /// Types `keys` at `location` (the end by default) and returns the source.
    private func typing(
        _ keys: [String], into text: String, at location: Int? = nil,
        configuration: MarkdownEditorConfiguration
    ) async throws -> String {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: Harness(host: Host(text), configuration: configuration))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)); await Task.yield() }
        let view = try #require(editor(in: hosting))
        view.setSelectedRange(NSRange(location: location ?? (view.string as NSString).length, length: 0))
        for key in keys { view.insertText(key, replacementRange: view.selectedRange()) }
        return view.string
    }

    @Test("a literal-Markdown host gets exactly the typed characters")
    func literalHostTypesLiterally() async throws {
        #expect(try await typing(["[", "["], into: "", configuration: Self.literal) == "[[")
        #expect(try await typing(["(", "{"], into: "", configuration: Self.literal) == "({")
        #expect(try await typing(["-", ">"], into: "", configuration: Self.literal) == "->")
    }

    @Test("the default configuration keeps the engine's helpers")
    func defaultHostKeepsHelpers() async throws {
        #expect(try await typing(["("], into: "", configuration: .default) == "()")
        #expect(try await typing(["-", ">"], into: "", configuration: .default) == "→")
        #expect(try await typing(["[", "["], into: "", configuration: .default) == "[[]]")
    }

    @Test("brackets never pair inside a code block")
    func noPairsInsideCode() async throws {
        let fence = "```\nx\n```"
        #expect(try await typing(["(", "["], into: fence, at: 5, configuration: .default) == "```\nx([\n```")
    }
}
