import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Native Markdown copy", .serialized)
struct NativeCopyTests {
    enum Construct: String, CaseIterable {
        case code, inlineMath, blockMath, table, image, wiki, diagram

        var source: String {
            switch self {
            case .code: return "```swift\n\tlet café = \"e\u{301}\"  \n\n```"
            case .inlineMath: return "$x_1 + y$"
            case .blockMath: return "$$\nx_1 + y\n$$"
            case .table: return "| A | B |\n| --- | --- |\n| e\\|x | $a$ |"
            case .image: return "![café|160](assets/pic%20name.png)"
            case .wiki: return "[[cafe\u{301}|opaque-id]]"
            case .diagram: return "```mermaid\ngraph TD\nA --> B\n```"
            }
        }
    }

    private struct FormulaRenderer: LatexRenderer {
        func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? {
            let size = CGSize(width: 70, height: 24)
            return LatexRenderResult(image: NSImage(size: size), size: size, baselineOffset: 2)
        }
    }

    private struct DiagramRenderer: BlockDiagramRenderer {
        func render(source: String, language: String, maxWidth: CGFloat,
                    fontSize: CGFloat, theme: MarkdownEditorTheme) -> DiagramRenderResult? {
            let size = CGSize(width: 120, height: 80)
            return DiagramRenderResult(image: NSImage(size: size), size: size)
        }
    }

    private struct ImageProvider: EmbeddedImageProvider {
        func image(for reference: EmbeddedImageRequest) -> NSImage? {
            NSImage(size: CGSize(width: 160, height: 100))
        }
        func fingerprint() -> AnyHashable { 0 }
    }

    private struct WikiResolver: WikiLinkResolver {
        func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? {
            WikiLinkResolution(id: "resolved-target", exists: true)
        }
    }

    @MainActor
    private final class Source {
        var text: String
        init(_ text: String) { self.text = text }
    }

    @MainActor
    private final class Editor {
        let initialText: String
        let source: Source
        let undo = UndoManager()
        let window: NSWindow
        let scrollView: NSScrollView
        let textView: NativeTextView
        let coordinator: NativeTextViewCoordinator

        init(_ text: String) throws {
            _ = NSApplication.shared
            initialText = text
            let source = Source(text)
            self.source = source
            var configuration = MarkdownEditorConfiguration.default
            configuration.inputSubstitution = .literalMarkdown
            configuration.services = MarkdownEditorServices(
                wikiLinks: WikiResolver(), images: ImageProvider(),
                latex: FormulaRenderer(), diagram: DiagramRenderer()
            )
            var wrapper = NativeTextViewWrapper(
                text: Binding(get: { source.text }, set: { source.text = $0 }),
                configuration: configuration, fontSize: 16,
                documentId: "copy-" + UUID().uuidString,
                isEditable: true, undoManager: undo
            )
            coordinator = wrapper.makeCoordinator()
            scrollView = wrapper.makeNativeView(coordinator: coordinator)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            scrollView.frame = window.contentView!.bounds
            window.contentView = scrollView
            scrollView.layoutSubtreeIfNeeded()
            wrapper.updateNativeView(scrollView, coordinator: coordinator)
            textView = try #require(scrollView.nativeTextView)
            window.makeFirstResponder(textView)

            // Keep real native Undo alive while copying the rendered document.
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            textView.insertText("Edited ", replacementRange: NSRange(location: 0, length: 0))
            textView.breakUndoCoalescing()
            undo.endUndoGrouping()
            coordinator.commitTextSync(for: textView)
            try #require(undo.canUndo)

            // Read-only selection preserves the collapsed forms under test.
            wrapper.isEditable = false
            wrapper.updateNativeView(scrollView, coordinator: coordinator)
        }

        func close() {
            NativeTextViewWrapper.dismantleNSView(scrollView, coordinator: coordinator)
            undo.removeAllActions()
            window.close()
        }
    }

    private func requireCollapsed(_ construct: Construct, in editor: Editor, range: NSRange) throws {
        let storage = try #require(editor.textView.textStorage)
        var probe = range.location
        switch construct {
        case .code:
            let ink = try #require(storage.attribute(.foregroundColor, at: probe, effectiveRange: nil) as? NSColor)
            try #require(ink.alphaComponent == 0, "the source fence must stay hidden")
        case .wiki:
            let id = storage.attribute(.wikiLinkID, at: range.location + 2, effectiveRange: nil) as? String
            try #require(id == "opaque-id")
        default:
            var anchor: Int?
            storage.enumerateAttribute(.renderedBlockImage, in: range) { value, run, stop in
                if value is NSImage {
                    anchor = run.location
                    stop.pointee = true
                }
            }
            probe = try #require(anchor, "\(construct.rawValue) must have a rendered image")
            let ink = try #require(storage.attribute(.foregroundColor, at: probe, effectiveRange: nil) as? NSColor)
            try #require(ink.alphaComponent == 0, "the rendered anchor must hide its source glyph")
        }
        let font = try #require(storage.attribute(.font, at: probe, effectiveRange: nil) as? NSFont)
        try #require(font.pointSize < 1, "\(construct.rawValue) must still have collapsed source")
    }

    private func assertNativeCopy(_ editor: Editor, range: NSRange) throws {
        let nativeBefore = Array(editor.textView.string.utf16)
        let modelBefore = Array(editor.source.text.utf16)
        let canUndo = editor.undo.canUndo
        let canRedo = editor.undo.canRedo
        let expected = (editor.textView.string as NSString).substring(with: range)
        let board = NSPasteboard(name: NSPasteboard.Name("PageFlowCopy-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let types = editor.textView.writablePasteboardTypes
        try #require(!types.isEmpty, "Copy must advertise a native plain source type")
        #expect(types.allSatisfy { $0 == .string || $0.rawValue == "NSStringPboardType" },
                "Copy must advertise only plain Markdown source")

        // The AppKit Copy export pipeline accepts a named board, preserving the
        // user's general clipboard while exercising all advertised native types.
        try #require(editor.textView.writeSelection(to: board, types: types))
        let plain = try #require(board.string(forType: .string))
        #expect(Array(plain.utf16) == Array(expected.utf16))
        let richTypes: [NSPasteboard.PasteboardType] = [
            .rtf, .rtfd, .html,
            .init(rawValue: "NeXT Rich Text Format v1.0 pasteboard type"),
            .init(rawValue: "NeXT RTFD pasteboard type"),
        ]
        for type in richTypes {
            #expect(board.data(forType: type) == nil,
                    "Copy must not export collapsed presentation attributes")
        }
        #expect(Array(editor.textView.string.utf16) == nativeBefore)
        #expect(Array(editor.source.text.utf16) == modelBefore)
        #expect(editor.textView.selectedRange() == range)
        #expect(editor.undo.canUndo == canUndo)
        #expect(editor.undo.canRedo == canRedo)
    }

    @Test("native Copy retains source across collapsed constructs", arguments: Construct.allCases)
    func collapsedConstructCopiesSource(_ construct: Construct) throws {
        let editor = try Editor("Introduction\n\n" + construct.source + "\n\nTrailing prose.")
        defer { editor.close() }
        let range = (editor.textView.string as NSString).range(of: construct.source)
        try #require(range.location != NSNotFound)
        editor.textView.setSelectedRange(range)
        try #require(editor.textView.selectedRange() == range)
        try requireCollapsed(construct, in: editor, range: range)
        try assertNativeCopy(editor, range: range)
        try requireCollapsed(construct, in: editor, range: range)
        let edited = Array(editor.textView.string.utf16)
        editor.textView.isEditable = true
        editor.undo.undo()
        editor.coordinator.commitTextSync(for: editor.textView)
        #expect(Array(editor.textView.string.utf16) == Array(editor.initialText.utf16))
        #expect(Array(editor.source.text.utf16) == Array(editor.initialText.utf16))
        editor.undo.redo()
        editor.coordinator.commitTextSync(for: editor.textView)
        #expect(Array(editor.textView.string.utf16) == edited)
        #expect(Array(editor.source.text.utf16) == edited)
    }

    @Test("cross-construct Copy preserves Unicode, line endings, tabs and trailing spaces",
          arguments: ["\n", "\r\n"])
    func crossConstructSelectionCopiesExactUTF16(_ lineEnding: String) throws {
        let snippets = Construct.allCases.map { $0.source.replacingOccurrences(of: "\n", with: lineEnding) }
        let prefix = "😀 before e\u{301} é\t  " + lineEnding + lineEnding
        let suffix = lineEnding + lineEnding + "after\t  e\u{301}😀 remainder"
        let editor = try Editor(prefix + snippets.joined(separator: lineEnding + lineEnding) + suffix)
        defer { editor.close() }
        let source = editor.textView.string as NSString
        let start = source.range(of: "before").location
        let end = NSMaxRange(source.range(of: "after\t  e\u{301}😀"))
        let range = NSRange(location: start, length: end - start)
        editor.textView.setSelectedRange(range)
        try #require(editor.textView.selectedRange() == range)
        for (construct, snippet) in zip(Construct.allCases, snippets) {
            let constructRange = source.range(of: snippet)
            try #require(constructRange.location != NSNotFound)
            try requireCollapsed(construct, in: editor, range: constructRange)
        }
        try assertNativeCopy(editor, range: range)
    }

    @Test("named-board Cut stages preserve exact source through native Undo and Redo",
          arguments: ["\n", "\r\n"])
    func namedBoardCutStagesPreserveNativeUndo(_ lineEnding: String) throws {
        let snippets = Construct.allCases.map { $0.source.replacingOccurrences(of: "\n", with: lineEnding) }
        let selectedSource = "😀 e\u{301}\t  " + lineEnding
            + snippets.joined(separator: lineEnding + lineEnding) + lineEnding + "trailing\t  "
        let editor = try Editor("Before" + lineEnding + selectedSource + lineEnding + "After")
        defer { editor.close() }
        let before = NSString(string: editor.textView.string)
        let range = before.range(of: selectedSource)
        try #require(range.location != NSNotFound)
        let deleted = before.replacingCharacters(in: range, with: "")
        editor.textView.setSelectedRange(range)
        try assertNativeCopy(editor, range: range)

        // Exercise Cut's export and deletion stages without touching the general clipboard.
        editor.textView.isEditable = true
        editor.undo.beginUndoGrouping()
        editor.textView.delete(nil)
        editor.textView.breakUndoCoalescing()
        editor.undo.endUndoGrouping()
        editor.coordinator.commitTextSync(for: editor.textView)
        #expect(Array(editor.textView.string.utf16) == Array(deleted.utf16))
        #expect(Array(editor.source.text.utf16) == Array(deleted.utf16))
        editor.undo.undo()
        editor.coordinator.commitTextSync(for: editor.textView)
        #expect(Array(editor.textView.string.utf16) == Array((before as String).utf16))
        #expect(Array(editor.source.text.utf16) == Array((before as String).utf16))
        editor.undo.redo()
        editor.coordinator.commitTextSync(for: editor.textView)
        #expect(Array(editor.textView.string.utf16) == Array(deleted.utf16))
        #expect(Array(editor.source.text.utf16) == Array(deleted.utf16))
    }
}
