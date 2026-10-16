import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

/// Assistive apps hear a label for each rendered block, not its hidden markup.
@MainActor
@Suite("Rendered block accessibility")
struct RenderedBlockAccessibilityTests {
    private struct StubLatex: LatexRenderer {
        func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? {
            LatexRenderResult(image: NSImage(size: CGSize(width: 20, height: 8)), size: CGSize(width: 20, height: 8), baselineOffset: 2)
        }
    }

    private func editor(_ text: String) -> NativeTextView {
        _ = NSApplication.shared
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: NSFont.systemFont(ofSize: 14).fontName, fontSize: 14,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        var configuration = MarkdownEditorConfiguration.default
        configuration.services = MarkdownEditorServices(latex: StubLatex())
        coordinator.configuration = configuration
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.isEditable = true
        view.delegate = coordinator
        coordinator.textView = view
        view.string = text
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        coordinator.rebuildTextStorageAndStyle(view, from: text)
        _ = coordinator.parsedDocument(for: text)
        return view
    }

    @Test
    func renderedMathIsReadAsALabel() throws {
        let view = editor("Area is $x^2$ here.\n\nend")
        let spoken = try #require(view.accessibilityString(for: NSRange(location: 0, length: 19)))
        #expect(spoken == "Area is math: x^2 here.")
    }

    @Test
    func revealedMathIsReadAsTyped() throws {
        let text = "Area is $x^2$ here."
        let view = editor(text)
        view.setSelectedRange(NSRange(location: 10, length: 0))   // caret inside the formula reveals it
        (view.delegate as? NativeTextViewCoordinator)?.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: view)
        )
        let spoken = view.accessibilityString(for: NSRange(location: 0, length: (text as NSString).length))
        #expect(spoken == text)
    }

    @Test
    func labelsNameTheBlock() {
        let source = "![A chart](chart.png)\n\n| A | B |\n| --- | --- |\n| 1 | 2 |" as NSString
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: source as String)
        let labels = tokens.compactMap { NativeTextView.accessibilityLabel(for: $0, in: source) }
        #expect(labels.contains("image: A chart"))
        #expect(labels.contains("table, 2 rows"))
    }
}
