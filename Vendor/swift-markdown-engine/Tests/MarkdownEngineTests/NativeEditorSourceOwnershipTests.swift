import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Native editor transactions", .serialized)
struct NativeEditorSourceOwnershipTests {
    @MainActor private final class Document {
        let id: String
        var text: String
        var clickedLinks: [String] = []
        let controller = MarkdownEditorController()
        let undo = UndoManager()

        init(_ text: String, id: String = "A") {
            self.text = text
            self.id = id
        }
    }

    private final class Model: ObservableObject {
        @Published var document: Document
        var usesHostUndo = false
        @Published var fontSize: CGFloat = 16
        @Published var isEditable = true
        @Published var configuration = MarkdownEditorConfiguration.default
        @Published var onCodeBlockSelectionChange: (([CodeBlockSelection]) -> Void)?

        init(_ document: Document) { self.document = document }
    }

    private struct Editor: View {
        @ObservedObject var model: Model

        var body: some View {
            let document = model.document
            NativeTextViewWrapper(
                text: Binding(get: { document.text }, set: { document.text = $0 }),
                configuration: model.configuration,
                fontSize: model.fontSize,
                documentId: document.id,
                isEditable: model.isEditable,
                onLinkClick: { document.clickedLinks.append($0) },
                onCodeBlockSelectionChange: model.onCodeBlockSelectionChange,
                editorController: document.controller,
                undoManager: model.usesHostUndo ? document.undo : nil
            )
        }
    }

    @MainActor private final class MountedEditor {
        let model: Model
        let host: NSHostingView<Editor>
        let window: NSWindow
        let textView: NativeTextView
        let coordinator: NativeTextViewCoordinator

        init(_ source: String, usesHostUndo: Bool = false) throws {
            _ = NSApplication.shared
            model = Model(Document(source))
            model.usesHostUndo = usesHostUndo
            host = NSHostingView(rootView: Editor(model: model))
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 650, height: 500),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            Self.settle(host)
            textView = try #require(Self.findEditor(host))
            coordinator = try #require(textView.delegate as? NativeTextViewCoordinator)
            window.makeFirstResponder(textView)
        }

        func update() { Self.settle(host) }

        func close() {
            coordinator.textSyncGeneration &+= 1
            coordinator.removeViewObservers()
            window.close()
        }

        private static func settle(_ host: NSView) {
            let deadline = Date(timeIntervalSinceNow: 0.08)
            while Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
                host.layoutSubtreeIfNeeded()
            }
        }

        private static func findEditor(_ view: NSView) -> NativeTextView? {
            if let editor = view as? NativeTextView { return editor }
            for child in view.subviews {
                if let editor = findEditor(child) { return editor }
            }
            return nil
        }
    }

    private func drainCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test("atomic native replacement preserves literal source and is one undo step")
    func literalReplacementUndoAndRedo() throws {
        let source = "😀 e\u{301} needle\r\n[[name|opaque]] needle tail"
        let editor = try MountedEditor(source, usesHostUndo: true)
        defer { editor.close() }
        let controller = editor.model.document.controller
        let undo = editor.model.document.undo
        undo.groupsByEvent = false
        let first = (source as NSString).range(of: "needle")
        let second = (source as NSString).range(of: "needle", options: .backwards)
        let replacement = "needle\r\n日本語 🧭"
        let expected = "😀 e\u{301} needle\r\n日本語 🧭\r\n[[name|opaque]] needle\r\n日本語 🧭 tail"
        editor.textView.setSelectedRange(first)

        try #require(controller.replaceCharacters(
            in: [first, second], with: replacement, expectedSource: source, actionName: "Replace All"
        ))
        #expect((editor.textView.string as NSString).isEqual(to: expected))
        #expect((controller.commitPendingText()! as NSString).isEqual(to: expected))
        #expect((editor.model.document.text as NSString).isEqual(to: expected))
        #expect(undo.undoActionName == "Replace All")
        undo.undo()
        #expect((editor.textView.string as NSString).isEqual(to: source))
        #expect(editor.textView.selectedRange() == first)
        #expect(!undo.canUndo, "All matches must belong to one operation")
        undo.redo()
        #expect((editor.textView.string as NSString).isEqual(to: expected))
    }

    @Test("editing an explicit empty table cell preserves source and per-document Undo")
    func emptyTableCellReplacementUndoAndRedo() throws {
        let source = "😀 e\u{301} before\r\n\r\n A | B | C\r\n--- | :---: | ---:\r\n left | \t | tail\\|\r\n\r\nafter"
        let expected = "😀 e\u{301} before\r\n\r\n A | B | C\r\n--- | :---: | ---:\r\n left | \t 日本語 🧭| tail\\|\r\n\r\nafter"
        let editor = try MountedEditor(source, usesHostUndo: true)
        defer { editor.close() }
        let controller = editor.model.document.controller
        let undo = editor.model.document.undo
        undo.groupsByEvent = false
        let ns = source as NSString
        let line = ns.lineRange(for: ns.range(of: "left"))
        let ranges = MarkdownTableScanner.cellContentRanges(inLine: line, of: ns)
        try #require(ranges.count == 3)
        let emptyCell = ranges[1]
        try #require(emptyCell.length == 0)
        try #require(controller.replaceCharacters(
            in: [emptyCell], with: "日本語 🧭", expectedSource: source, actionName: "Edit Table Cell"
        ))
        #expect(Array(editor.textView.string.utf16) == Array(expected.utf16))
        #expect(Array(try #require(controller.commitPendingText()).utf16) == Array(expected.utf16))
        #expect(Array(editor.model.document.text.utf16) == Array(expected.utf16))
        #expect(undo.undoActionName == "Edit Table Cell")
        undo.undo()
        #expect(Array(editor.textView.string.utf16) == Array(source.utf16))
        #expect(!undo.canUndo)
        undo.redo()
        #expect(Array(editor.textView.string.utf16) == Array(expected.utf16))
    }

    @Test("replacement growth keeps the same visible source beyond the old document length", arguments: [false, true], [false, true])
    func replacementGrowthPreservesViewport(settled: Bool, interior: Bool) throws {
        let prefix = interior ? String(repeating: "unchanged prefix paragraph\n", count: 12) : ""
        let source = prefix + "needle\n" + (0..<220).map { "original-line-\($0) stable reading content" }.joined(separator: "\n")
        let editor = try MountedEditor(source, usesHostUndo: true)
        defer { editor.close() }
        let tv = editor.textView
        let target = (source as NSString).range(of: "original-line-180")
        tv.setSelectedRange(NSRange(location: target.location, length: 0))
        tv.scrollRangeToVisible(target)
        if settled {
            tv.textLayoutManager?.textViewportLayoutController.layoutViewport()
            editor.update()
        }
        let before = try #require(tv.readingPosition())
        let replacement = (0..<500).map { "inserted-line-\($0)" }.joined(separator: "\n")
        let delta = replacement.utf16.count - 6
        try #require(before.anchorOffset + delta >= source.utf16.count)
        try #require(editor.model.document.controller.replaceCharacters(
            in: [(source as NSString).range(of: "needle")], with: replacement, expectedSource: source
        ))
        let after = try #require(tv.readingPosition())
        #expect(after.anchorOffset == before.anchorOffset + delta)
        #expect(abs(after.offsetInViewport - before.offsetInViewport) < 2)
        editor.update()
        let settledAfter = try #require(tv.readingPosition())
        #expect(settledAfter.anchorOffset == before.anchorOffset + delta)
        #expect(abs(settledAfter.offsetInViewport - before.offsetInViewport) < 2)
        editor.model.document.undo.undo()
        #expect((tv.string as NSString).isEqual(to: source))
        let restored = try #require(tv.readingPosition())
        #expect(restored.anchorOffset == before.anchorOffset)
        #expect(abs(restored.offsetInViewport - before.offsetInViewport) < 2)
        editor.update()
        let settledRestored = try #require(tv.readingPosition())
        #expect(settledRestored.anchorOffset == before.anchorOffset)
        #expect(abs(settledRestored.offsetInViewport - before.offsetInViewport) < 2)
        editor.model.document.undo.redo()
        let redone = try #require(tv.readingPosition())
        #expect(redone.anchorOffset == before.anchorOffset + delta)
        #expect(abs(redone.offsetInViewport - before.offsetInViewport) < 2)
        editor.update()
        let settledRedone = try #require(tv.readingPosition())
        #expect(settledRedone.anchorOffset == before.anchorOffset + delta)
        #expect(abs(settledRedone.offsetInViewport - before.offsetInViewport) < 2)
    }

    @Test("Undo of deletion before the visible paragraph follows surviving source", arguments: [1, 2])
    func replacementDeletionBoundaryPreservesViewport(deletions: Int) throws {
        let prefix = (0..<180).map { "prefix-line-\($0) stable content\n" }.joined()
        let removed = String(repeating: "needle\n", count: deletions)
        let target = "visible-target paragraph\n"
        let source = prefix + removed + target + (0..<60).map { "tail-line-\($0) stable content\n" }.joined()
        let editor = try MountedEditor(source, usesHostUndo: true)
        defer { editor.close() }
        let tv = editor.textView
        let targetOffset = prefix.utf16.count + removed.utf16.count
        tv.setSelectedRange(NSRange(location: targetOffset, length: 0))
        try #require(tv.restore(ReadingPosition(anchorOffset: targetOffset, offsetInViewport: 0)))
        tv.textLayoutManager?.textViewportLayoutController.layoutViewport()
        editor.update()
        let before = try #require(tv.readingPosition())
        try #require(before.anchorOffset == targetOffset)
        let ranges = (0..<deletions).map { NSRange(location: prefix.utf16.count + $0 * 7, length: 7) }
        try #require(editor.model.document.controller.replaceCharacters(in: ranges, with: "", expectedSource: source))
        let after = try #require(tv.readingPosition())
        #expect(after.anchorOffset == prefix.utf16.count)
        #expect(abs(after.offsetInViewport - before.offsetInViewport) < 2)
        editor.update()
        let settledAfter = try #require(tv.readingPosition())
        #expect(settledAfter.anchorOffset == prefix.utf16.count)
        #expect(abs(settledAfter.offsetInViewport - before.offsetInViewport) < 2)
        editor.model.document.undo.undo()
        #expect((tv.string as NSString).isEqual(to: source))
        let restored = try #require(tv.readingPosition())
        #expect(restored.anchorOffset == targetOffset)
        #expect(abs(restored.offsetInViewport - before.offsetInViewport) < 2)
        editor.update()
        let settledRestored = try #require(tv.readingPosition())
        #expect(settledRestored.anchorOffset == targetOffset)
        #expect(abs(settledRestored.offsetInViewport - before.offsetInViewport) < 2)
        editor.model.document.undo.redo()
        let redone = try #require(tv.readingPosition())
        #expect(redone.anchorOffset == prefix.utf16.count)
        #expect(abs(redone.offsetInViewport - before.offsetInViewport) < 2)
        editor.update()
        let settledRedone = try #require(tv.readingPosition())
        #expect(settledRedone.anchorOffset == prefix.utf16.count)
        #expect(abs(settledRedone.offsetInViewport - before.offsetInViewport) < 2)
    }

    @Test("replacement rejects unsafe or stale native edits without changing history")
    func replacementAdmission() throws {
        let source = "é 😀 needle"
        let editor = try MountedEditor(source, usesHostUndo: true)
        defer { editor.close() }
        let controller = editor.model.document.controller
        let match = (source as NSString).range(of: "needle")
        let selection = NSRange(location: 0, length: 1)
        editor.textView.setSelectedRange(selection)
        let invalidRanges: [[NSRange]] = [
            [], [NSRange(location: NSNotFound, length: 1)],
            [NSRange(location: Int.max - 1, length: 10)],
            [NSRange(location: 0, length: Int.max)],
            [NSRange(location: 3, length: 1)], // Low half of the emoji surrogate pair.
            [match, match], [match, NSRange(location: 0, length: 1)]
        ]
        for ranges in invalidRanges {
            #expect(!controller.replaceCharacters(in: ranges, with: "x", expectedSource: source))
        }
        #expect(!controller.replaceCharacters(
            in: [match], with: "x", expectedSource: "e\u{301} 😀 needle"
        ), "Canonical equivalence must not admit stale UTF-16 offsets")
        editor.textView.isEditable = false
        #expect(!controller.replaceCharacters(in: [match], with: "x", expectedSource: source))
        editor.textView.isEditable = true
        editor.coordinator.isWritingToolsActive = true
        #expect(!controller.replaceCharacters(in: [match], with: "x", expectedSource: source))
        editor.coordinator.isWritingToolsActive = false
        editor.textView.isSettingMarkedText = true
        #expect(!controller.replaceCharacters(in: [match], with: "x", expectedSource: source))
        editor.textView.isSettingMarkedText = false
        editor.textView.isCommittingMarkedText = true
        #expect(!controller.replaceCharacters(in: [match], with: "x", expectedSource: source))
        editor.textView.isCommittingMarkedText = false
        #expect((editor.textView.string as NSString).isEqual(to: source))
        #expect(editor.textView.selectedRange() == selection)
        #expect(!editor.model.document.undo.canUndo)
        #expect(!MarkdownEditorController().replaceCharacters(in: [match], with: "x", expectedSource: source))
    }

    @Test("native replacement deletes literally without list or math input helpers")
    func replacementIsLiteralAndCanDelete() throws {
        let editor = try MountedEditor("- needle\r\nneedle", usesHostUndo: true)
        defer { editor.close() }
        let controller = editor.model.document.controller
        editor.model.document.undo.groupsByEvent = false
        try #require(controller.replaceCharacters(
            in: [NSRange(location: 2, length: 6)], with: "$$", expectedSource: editor.textView.string
        ))
        #expect(editor.textView.string == "- $$\r\nneedle")
        try #require(controller.replaceCharacters(
            in: [NSRange(location: 6, length: 6)], with: "", expectedSource: editor.textView.string
        ))
        #expect(editor.textView.string == "- $$\r\n")
        editor.model.document.undo.undo()
        #expect(editor.textView.string == "- $$\r\nneedle")
        editor.model.document.undo.undo()
        #expect(editor.textView.string == "- needle\r\nneedle")
    }

    @Test("native storage and publication retain exact wiki-looking source")
    func rawSourceSurvivesUnrelatedNativeEdit() throws {
        let source = "😀 [[name|id]] `[[literal|suffix]]` \\[[escaped|id]] [[name|second]]"
        let editor = try MountedEditor(source)
        defer { editor.close() }
        #expect((editor.textView.string as NSString).isEqual(to: source))
        #expect(editor.model.document.controller.currentStorageText == source)
        #expect(editor.model.document.controller.currentDisplayText == source)

        editor.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        editor.coordinator.commitTextSync(for: editor.textView)

        #expect((editor.textView.string as NSString).isEqual(to: "x" + source))
        #expect((editor.model.document.text as NSString).isEqual(to: "x" + source))
    }

    @Test("font changes preserve pending native text, selection and undo")
    func fontChangePreservesPendingEdit() throws {
        let editor = try MountedEditor("hello")
        defer { editor.close() }
        editor.textView.insertText("X", replacementRange: NSRange(location: 5, length: 0))
        editor.textView.breakUndoCoalescing()
        let selection = editor.textView.selectedRanges
        let affinity = editor.textView.selectionAffinity
        #expect(editor.model.document.text == "hello")

        editor.model.fontSize = 21
        editor.update()

        try #require(editor.textView.string == "helloX")
        #expect(editor.textView.selectedRanges == selection)
        #expect(editor.textView.selectionAffinity == affinity)
        let font = editor.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == 21)
        editor.textView.undoManager?.undo()
        #expect(editor.textView.string == "hello")
        editor.textView.undoManager?.redo()
        #expect(editor.textView.string == "helloX")
    }

    @Test("authoritative source replacement retires old undo and redo ranges", arguments: [false, true])
    func sourceReplacementRetiresStaleHistory(seedRedo: Bool) throws {
        let editor = try MountedEditor("0123456789")
        defer { editor.close() }
        editor.textView.insertText("XYZ", replacementRange: NSRange(location: 10, length: 0))
        editor.textView.breakUndoCoalescing()
        let undoManager = try #require(editor.textView.undoManager)
        try #require(undoManager.canUndo)
        if seedRedo {
            undoManager.undo()
            try #require(undoManager.canRedo)
        }
        editor.model.document.text = "a"
        editor.model.objectWillChange.send()
        editor.update()

        try #require(editor.textView.string == "a")
        try #require(!undoManager.canUndo)
        try #require(!undoManager.canRedo)
        editor.textView.insertText("b", replacementRange: NSRange(location: 1, length: 0))
        editor.textView.breakUndoCoalescing()
        try #require(undoManager.canUndo)
        undoManager.undo()
        #expect(editor.textView.string == "a")
        undoManager.redo()
        #expect(editor.textView.string == "ab")
    }

    @Test("equal-source document switches route outgoing edits and new callbacks separately")
    func equalSourceSwitchChangesOwnership() async throws {
        let editor = try MountedEditor("hello")
        defer { editor.close() }
        let outgoing = editor.model.document
        editor.textView.insertText("X", replacementRange: NSRange(location: 5, length: 0))
        let incoming = Document("hello", id: "B")

        editor.model.document = incoming
        editor.update()
        editor.coordinator.commitTextSync(for: editor.textView)
        _ = editor.coordinator.textView(editor.textView, clickedOnLink: "target", at: 0)
        editor.update()
        await drainCallbacks()

        #expect(outgoing.text == "helloX")
        #expect(incoming.text == "hello")
        #expect(editor.textView.string == "hello")
        #expect(editor.coordinator.documentId == "B")
        #expect(editor.textView.undoManager?.canUndo == false)
        #expect(outgoing.clickedLinks.isEmpty)
        #expect(incoming.clickedLinks == ["target"])
    }

    @Test("equal-source updates refresh bindings and callbacks for the current document")
    func sameDocumentRefreshesTargets() async throws {
        let editor = try MountedEditor("hello")
        defer { editor.close() }
        let oldTarget = editor.model.document
        let newTarget = Document("hello")
        editor.model.document = newTarget
        editor.update()
        editor.textView.insertText("X", replacementRange: NSRange(location: 5, length: 0))
        editor.coordinator.commitTextSync(for: editor.textView)
        _ = editor.coordinator.textView(editor.textView, clickedOnLink: "target", at: 0)
        editor.update()
        await drainCallbacks()

        #expect(oldTarget.text == "hello")
        #expect(newTarget.text == "helloX")
        #expect(oldTarget.clickedLinks.isEmpty)
        #expect(newTarget.clickedLinks == ["target"])
    }

    @Test("incoming canonically equivalent text replaces literal UTF-16 source")
    func incomingSourceUsesLiteralEquality() throws {
        let editor = try MountedEditor("*é*")
        defer { editor.close() }
        let decomposed = "*e\u{301}*"
        editor.model.document.text = decomposed
        editor.model.objectWillChange.send()
        editor.update()

        #expect((editor.textView.string as NSString).isEqual(to: decomposed))
        let token = editor.coordinator.parsedDocument(for: editor.textView.string).tokens.first { $0.kind == .italic }
        #expect(token?.contentRange == NSRange(location: 1, length: 2))
    }


    @Test("separate host histories survive switching away and back")
    func hostUndoHistoriesRemainWithTheirDocuments() async throws {
        let editor = try MountedEditor("alpha", usesHostUndo: true)
        defer { editor.close() }
        let first = editor.model.document
        first.undo.beginUndoGrouping()
        editor.textView.insertText("X", replacementRange: NSRange(location: 5, length: 0))
        editor.textView.breakUndoCoalescing()
        first.undo.endUndoGrouping()
        let second = Document("beta", id: "B")
        editor.model.document = second
        editor.update()
        await drainCallbacks()

        #expect(first.text == "alphaX")
        #expect(first.controller.currentStorageText == nil)
        #expect(second.controller.currentStorageText == "beta")
        #expect(first.undo.canUndo)
        #expect(!second.undo.canUndo)
        second.undo.beginUndoGrouping()
        editor.textView.insertText("Y", replacementRange: NSRange(location: 4, length: 0))
        editor.textView.breakUndoCoalescing()
        second.undo.endUndoGrouping()
        editor.model.document = first
        editor.update()
        await drainCallbacks()

        try #require(editor.textView.string == "alphaX")
        #expect(second.text == "betaY")
        #expect(second.controller.currentStorageText == nil)
        #expect(first.controller.currentStorageText == "alphaX")
        first.undo.undo()
        #expect(editor.textView.string == "alpha")
        first.undo.redo()
        #expect(editor.textView.string == "alphaX")
        editor.model.document = second
        editor.update()
        await drainCallbacks()
        try #require(editor.textView.string == "betaY")
        second.undo.undo()
        #expect(editor.textView.string == "beta")
        second.undo.redo()
        #expect(editor.textView.string == "betaY")
    }
    @Test("inline replacements use raw source lengths for storage and caret")
    func inlineReplacementKeepsSuffixAndUTF16Caret() throws {
        let editor = try MountedEditor("😀 [[old]] tail")
        defer { editor.close() }
        let range = NSRange(location: 3, length: 7)
        let fragment = "[[新しい😀|stable-id]]"
        editor.coordinator.applyInlineReplacement(InlineReplacementRequest(
            documentId: "A",
            selection: WikiLinkSelection(displayRange: range, storageRange: range, placeholder: "old"),
            storageFragment: fragment,
            isImageEmbedMode: false
        ), to: editor.textView)
        editor.coordinator.commitTextSync(for: editor.textView)

        #expect(editor.textView.string == "😀 " + fragment + " tail")
        #expect(editor.model.document.text == "😀 " + fragment + " tail")
        #expect(editor.textView.selectedRange() == NSRange(location: 3 + fragment.utf16.count, length: 0))
    }

    @Test("configuration restyles live text without replacing source or spell preferences")
    func configurationPropagatesDuringPendingEdit() throws {
        let editor = try MountedEditor("hello")
        defer { editor.close() }
        editor.textView.insertText("X", replacementRange: NSRange(location: 5, length: 0))
        editor.textView.isContinuousSpellCheckingEnabled = false
        editor.coordinator.didToggleSpellCheckingPolicy(textView: editor.textView)
        editor.model.configuration.theme.bodyText = .systemPurple
        editor.model.configuration.overscroll.maxPoints = 99
        editor.model.configuration.readingWidth = 400
        editor.update()

        #expect(editor.textView.string == "helloX")
        let color = editor.textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == .systemPurple)
        #expect(editor.textView.maxOverscrollPoints == 99)
        #expect(editor.textView.textContainer?.widthTracksTextView == false)
        #expect(editor.textView.textContainer?.size.width == 400)
        #expect(editor.textView.isContinuousSpellCheckingEnabled == false)
    }

    @Test("marked input defers publication and custom restyling until commit")
    func markedInputDefersEditorTransactions() throws {
        let editor = try MountedEditor("hello")
        defer { editor.close() }
        editor.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 5, length: 0))
        #expect(editor.textView.hasMarkedText())
        let before = try #require(editor.textView.textStorage).copy() as! NSAttributedString
        editor.coordinator.restyleParagraphs([NSRange(location: 0, length: 6)], in: editor.textView)
        editor.coordinator.commitTextSync(for: editor.textView)

        #expect(editor.model.document.text == "hello")
        #expect(editor.textView.textStorage?.isEqual(to: before) == true)
        editor.textView.insertText("日本", replacementRange: editor.textView.markedRange())
        editor.update()
        editor.coordinator.commitTextSync(for: editor.textView)
        #expect(editor.model.document.text == "hello日本")
        #expect(!editor.textView.hasMarkedText())
    }

    @Test("empty marked-input cancellation restores ordinary presentation")
    func emptyMarkedInputFinishesDeferredRefresh() throws {
        let editor = try MountedEditor("hello")
        defer { editor.close() }
        editor.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 5, length: 0))
        editor.model.fontSize = 22
        editor.update()
        let marked = editor.textView.markedRange()
        editor.textView.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: marked)
        editor.textView.unmarkText()
        editor.coordinator.commitTextSync(for: editor.textView)

        #expect(editor.textView.string == "hello")
        #expect(editor.model.document.text == "hello")
        #expect(!editor.textView.hasMarkedText())
        let font = editor.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == 22)
    }

    @Test("native teardown accepts and publishes marked source to its current target")
    func teardownFlushesAcceptedMarkedSource() throws {
        let editor = try MountedEditor("hello")
        defer { editor.close() }
        editor.textView.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 5, length: 0))
        let scrollView = try #require(editor.textView.enclosingScrollView)
        NativeTextViewWrapper.dismantleNSView(scrollView, coordinator: editor.coordinator)

        #expect(!editor.textView.hasMarkedText())
        #expect(editor.model.document.text == "hello日本")
    }

    @Test("equal-source document switches reset the incoming native selection")
    func equalSourceSwitchResetsSelectionContext() throws {
        let editor = try MountedEditor("plain **bold** tail")
        defer { editor.close() }
        editor.textView.setSelectedRange(NSRange(location: 10, length: 0))
        editor.model.document = Document("plain **bold** tail", id: "B")
        editor.update()

        #expect(editor.textView.selectedRange() == NSRange(location: 0, length: 0))
        let markerFont = editor.textView.textStorage?.attribute(.font, at: 6, effectiveRange: nil) as? NSFont
        #expect(markerFont?.pointSize == editor.model.configuration.markers.hiddenMarkerFontSize)
    }

    @Test("Writing Tools accepts plain results while Markdown presentation stays attributed")
    func writingToolsResultsStayPlainText() throws {
        guard #available(macOS 15.1, *) else { return }
        let source = "**bold** e\u{301} 🇯🇵.\r\n\r\n`literal`"
        let editor = try MountedEditor(source, usesHostUndo: true)
        defer { editor.close() }
        #expect(editor.textView.writingToolsBehavior == .complete)
        #expect(editor.textView.allowedWritingToolsResultOptions == .plainText)
        #expect(editor.textView.isRichText)
        let font = try #require(editor.textView.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        try #require(font.fontDescriptor.symbolicTraits.contains(.bold))

        editor.model.fontSize = 20
        editor.update()

        #expect(editor.textView.allowedWritingToolsResultOptions == .plainText)
        #expect(editor.textView.isRichText)
        let updatedFont = try #require(editor.textView.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        #expect(updatedFont.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(updatedFont.pointSize == 20)
        #expect((editor.textView.string as NSString).isEqual(to: source))
        #expect((editor.model.document.text as NSString).isEqual(to: source))
    }

    @Test("incoming source during Writing Tools remains authoritative after the session")
    func incomingSourceDuringWritingToolsIsRetained() async throws {
        guard #available(macOS 15.0, *) else { return }
        let editor = try MountedEditor("old `[[literal|id]]`")
        defer { editor.close() }
        editor.coordinator.textViewWritingToolsWillBegin(editor.textView)
        let incoming = "new **e\u{301}** [[other|new-id]]"
        editor.model.document.text = incoming
        editor.model.objectWillChange.send()
        editor.update()

        #expect(editor.textView.string == "old `[[literal|id]]`")
        editor.coordinator.textViewWritingToolsDidEnd(editor.textView)
        await drainCallbacks()

        #expect((editor.textView.string as NSString).isEqual(to: incoming))
        #expect((editor.model.document.text as NSString).isEqual(to: incoming))
    }

    @Test("Writing Tools completion cannot replace a newer committed native edit", arguments: [false, true])
    func writingToolsCompletionPreservesNewerNativeSource(editAfterEnd: Bool) async throws {
        guard #available(macOS 15.0, *) else { return }
        let source = "**e\u{301}** 😀 [[literal|id]]\r\ntrailing source"
        let editor = try MountedEditor(source, usesHostUndo: true)
        defer { editor.close() }
        let document = editor.model.document
        editor.coordinator.textViewWritingToolsWillBegin(editor.textView)
        editor.coordinator.textViewWritingToolsDidEnd(editor.textView)

        let expected = editAfterEnd ? "新😀 " + source : source
        if editAfterEnd {
            editor.textView.insertText("新😀 ", replacementRange: NSRange(location: 0, length: 0))
            editor.textView.breakUndoCoalescing()
            let committed = try #require(document.controller.commitPendingText())
            try #require(Array(committed.utf16) == Array(expected.utf16))
            try #require(Array(document.text.utf16) == Array(expected.utf16))
            try #require(document.undo.canUndo)
        }
        try #require(Array(editor.textView.string.utf16) == Array(expected.utf16))

        await drainCallbacks()

        #expect(Array(editor.textView.string.utf16) == Array(expected.utf16))
        #expect(Array(document.text.utf16) == Array(expected.utf16))
        #expect(Array(editor.coordinator.lastSyncedText.utf16) == Array(expected.utf16))
        let current = try #require(document.controller.currentStorageText)
        #expect(Array(current.utf16) == Array(expected.utf16))
        #expect(editor.textView.undoManager === document.undo)
        if editAfterEnd {
            document.undo.undo()
            #expect(Array(editor.textView.string.utf16) == Array(source.utf16))
            document.undo.redo()
            #expect(Array(editor.textView.string.utf16) == Array(expected.utf16))
        }
    }

    @Test("Writing Tools publication yields to a newer host replacement before wrapper update", arguments: [false, true])
    func writingToolsCompletionPreservesNewerHostSource(replaceAfterEnd: Bool) async throws {
        guard #available(macOS 15.0, *) else { return }
        let source = "**e\u{301}** 😀 [[literal|id]]\r\ntrailing source"
        let accepted = "accepted " + source
        let incoming = "external é 🧭\r\n`replacement`"
        let editor = try MountedEditor(source)
        defer { editor.close() }
        let document = editor.model.document
        editor.coordinator.textViewWritingToolsWillBegin(editor.textView)
        editor.textView.insertText("accepted ", replacementRange: NSRange(location: 0, length: 0))
        try #require(Array(editor.textView.string.utf16) == Array(accepted.utf16))
        try #require(Array(document.text.utf16) == Array(source.utf16))
        editor.coordinator.textViewWritingToolsDidEnd(editor.textView)
        if replaceAfterEnd { document.text = incoming }
        let expected = replaceAfterEnd ? incoming : accepted

        await drainCallbacks()

        #expect(Array(document.text.utf16) == Array(expected.utf16))
        #expect(Array(editor.textView.string.utf16) == Array(accepted.utf16))
        editor.model.objectWillChange.send()
        editor.update()
        #expect(Array(editor.textView.string.utf16) == Array(expected.utf16))
        #expect(Array(document.text.utf16) == Array(expected.utf16))
        #expect(Array(editor.coordinator.lastSyncedText.utf16) == Array(expected.utf16))
    }

    @Test("withdrawing an incoming source during composition preserves native committed input")
    func latestIncomingSourceDuringCompositionWins() throws {
        let editor = try MountedEditor("hello")
        defer { editor.close() }
        editor.textView.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 5, length: 0))
        editor.model.document.text = "external"
        editor.model.objectWillChange.send()
        editor.update()
        editor.model.document.text = "hello"
        editor.model.objectWillChange.send()
        editor.update()
        editor.textView.unmarkText()
        editor.coordinator.commitTextSync(for: editor.textView)

        #expect(editor.textView.string == "hello日本")
        #expect(editor.model.document.text == "hello日本")
    }

    @Test("deferred configuration reaches native geometry after an unchanged session", arguments: [false, true])
    func deferredConfigurationAppliesAfterSession(writingTools: Bool) throws {
        guard #available(macOS 15.0, *) else { return }
        let editor = try MountedEditor("hello")
        defer { editor.close() }
        if writingTools {
            editor.coordinator.textViewWritingToolsWillBegin(editor.textView)
        } else {
            editor.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 5, length: 0))
        }
        editor.model.configuration.scrollers = .both
        editor.model.configuration.safeAreaInsets = SafeAreaInsets(top: 15, leading: 7, trailing: 9)
        editor.model.configuration.textInsets = TextInsets(horizontal: 12, vertical: 11)
        editor.update()
        if writingTools {
            editor.coordinator.textViewWritingToolsDidEnd(editor.textView)
        } else {
            editor.textView.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: editor.textView.markedRange())
            editor.textView.unmarkText()
        }
        let scrollView = try #require(editor.textView.enclosingScrollView)
        #expect(editor.textView.string == "hello")
        #expect(scrollView.hasHorizontalScroller)
        #expect(scrollView.contentInsets.top == 15)
        #expect(scrollView.contentInsets.left == 7)
        #expect(scrollView.contentInsets.right == 9)
        #expect(editor.textView.textContainerInset == NSSize(width: 12, height: 11))
    }

    @Test("deferred read-only source replacement applies when the input session ends", arguments: [false, true])
    func deferredReadOnlySourceAppliesAfterSession(writingTools: Bool) throws {
        let editor = try MountedEditor("hello")
        defer { editor.close() }
        if writingTools {
            guard #available(macOS 15.0, *) else { return }
            editor.coordinator.textViewWritingToolsWillBegin(editor.textView)
        } else {
            editor.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 5, length: 0))
        }
        let incoming = "external **replacement**"
        editor.model.document.text = incoming
        editor.model.isEditable = false
        editor.update()

        #expect(editor.textView.isEditable)
        if writingTools {
            #expect(editor.coordinator.isWritingToolsActive)
            if #available(macOS 15.0, *) {
                editor.coordinator.textViewWritingToolsDidEnd(editor.textView)
            }
        } else {
            #expect(editor.textView.hasMarkedText())
            editor.textView.unmarkText()
        }

        #expect(editor.textView.string == incoming)
        #expect(editor.model.document.text == incoming)
        #expect(!editor.textView.isEditable)
        #expect(editor.textView.insertionPointColor == .clear)
    }

    @Test("deferred source replacement retires old code widgets and delayed callbacks")
    func deferredSourceReplacementCancelsOldCodeWidgets() async throws {
        let editor = try MountedEditor("before\n\n```swift\nlet value = 1\n```\n\nend")
        defer { editor.close() }
        var publications: [[CodeBlockSelection]] = []
        editor.model.onCodeBlockSelectionChange = { publications.append($0) }
        editor.update()
        let oldTokens = editor.coordinator.parsedDocument(for: editor.textView.string).tokens
        editor.coordinator.updateCodeBlockSelection(textView: editor.textView, tokens: oldTokens)
        await drainCallbacks()
        #expect(publications.last?.count == 1)
        editor.coordinator.scheduleCodeBlockSelectionUpdate(textView: editor.textView, tokens: oldTokens)
        editor.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        editor.model.document.text = "new source"
        editor.model.objectWillChange.send()
        editor.update()
        editor.textView.unmarkText()
        await drainCallbacks()
        #expect(editor.textView.string == "new source")
        #expect(publications.last?.isEmpty == true)
        let completedPublications = publications.count
        try await Task.sleep(for: .milliseconds(850))
        #expect(publications.count == completedPublications)
    }


    @Test("destroying an inactive table resets every former row to fresh-source styling")
    func destroyedTableClearsFormerExtent() throws {
        let source = "before\n\n| H | Other |\n| --- | --- |\n| b | row |\n| c | row |\n| d | row |\n| e | row |\n\nend"
        let editor = try MountedEditor(source)
        defer { editor.close() }
        let storage = try #require(editor.textView.textStorage)
        let table = try #require(editor.coordinator.parsedDocument(for: source).tokens.first { $0.kind == .table })
        var image: NSImage?
        storage.enumerateAttribute(.renderedBlockImage, in: table.range, options: []) { value, _, _ in
            if let rendered = value as? NSImage { image = rendered }
        }
        _ = try #require(image)
        let separator = (source as NSString).range(of: "---")

        // Prose typing cannot reach a rendered table's hidden source; a host
        // replacement can.
        #expect(editor.coordinator.replaceSourceRanges(
            [NSRange(location: separator.location, length: 1)], with: "x", expectedSource: source, actionName: "Replace"
        ))

        let changed = (source as NSString).replacingCharacters(
            in: NSRange(location: separator.location, length: 1), with: "x"
        )
        try #require(editor.textView.string == changed)
        let fresh = try MountedEditor(changed)
        defer { fresh.close() }
        let rows = (changed as NSString).range(of: "| c | row |\n| d | row |\n| e | row |")
        let expectedStorage = try #require(fresh.textView.textStorage)
        let actual = storage.attributedSubstring(from: rows)
        let expected = expectedStorage.attributedSubstring(from: rows)
        #expect(actual.isEqual(to: expected))
    }

    @Test("scrolling after plain typing refreshes distant code copy ranges and content")
    func plainTypingThenScrollRefreshesCodeButtons() throws {
        let code = "let value = 1\n"
        let source = "plain introduction\n\n```swift\n" + code + "```\n\n"
            + String(repeating: "tail prose\n\n", count: 50)
        let editor = try MountedEditor(source)
        defer { editor.close() }
        var publications: [[CodeBlockSelection]] = []
        editor.model.onCodeBlockSelectionChange = { publications.append($0) }
        editor.update()
        editor.coordinator.updateCodeBlockSelection(
            textView: editor.textView,
            tokens: editor.coordinator.parsedDocument(for: source).tokens
        )
        let initial = try #require(publications.last?.first)
        try #require(initial.code == code)
        try #require(initial.language == "swift")

        editor.textView.insertText("abc", replacementRange: NSRange(location: 0, length: 0))
        try #require(editor.textView.string == "abc" + source)
        publications.removeAll()
        let scrollView = try #require(editor.textView.enclosingScrollView)
        let clip = scrollView.contentView
        let oldOrigin = clip.bounds.origin
        clip.scroll(to: NSPoint(x: oldOrigin.x, y: oldOrigin.y + 30))
        scrollView.reflectScrolledClipView(clip)
        try #require(clip.bounds.origin.y != oldOrigin.y)

        let refreshed = try #require(publications.last?.first)
        #expect(refreshed.code == code)
        #expect(refreshed.language == "swift")
    }
}
