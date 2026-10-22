import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Native heading folding", .serialized)
struct NativeFoldingTests {
    private final class Source { var text: String; init(_ text: String) { self.text = text } }
    @MainActor
    private final class Editor {
        let source: Source
        let controller: MarkdownEditorController
        let coordinator: NativeTextViewCoordinator
        let scroll: NSScrollView
        let view: NativeTextView
        let window: NSWindow
        let undo: UndoManager
        var wrapper: NativeTextViewWrapper
        init(_ text: String, controller: MarkdownEditorController? = nil, usesController: Bool = true) throws {
            _ = NSApplication.shared
            source = Source(text)
            self.controller = controller ?? MarkdownEditorController()
            undo = UndoManager()
            let source = source
            var config = MarkdownEditorConfiguration.default
            config.inputSubstitution = .literalMarkdown
            wrapper = NativeTextViewWrapper(text: Binding(get: { source.text }, set: { source.text = $0 }),
                configuration: config, fontSize: 16, documentId: "fold-test", isEditable: true,
                editorController: usesController ? self.controller : nil, undoManager: undo)
            coordinator = wrapper.makeCoordinator()
            scroll = wrapper.makeNativeView(coordinator: coordinator)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            scroll.frame = window.contentView!.bounds
            window.contentView = scroll
            scroll.layoutSubtreeIfNeeded()
            wrapper.updateNativeView(scroll, coordinator: coordinator)
            view = try #require(scroll.nativeTextView)
            window.makeFirstResponder(view)
        }
        func finish() {
            NativeTextViewWrapper.dismantleNSView(scroll, coordinator: coordinator)
            window.close()
        }
        func fold(at offset: Int = 0) throws {
            view.setSelectedRange(NSRange(location: offset, length: 0))
            try #require(controller.performFoldingCommand(.toggleFold))
        }
    }

    @Test("omitted paragraphs take zero height and toggles leave source and Undo untouched")
    func omissionAndSummaryGeometry() throws {
        let body = String(repeating: "Hidden paragraph\n", count: 1000)
        let text = "# First\n" + body + "# Last\nEnd\n"
        let editor = try Editor(text)
        defer { editor.finish() }
        let next = 8 + body.utf16.count
        let originalY = try #require(editor.view.lineFrame(at: next)?.minY)
        try editor.fold()
        let foldedY = try #require(editor.view.lineFrame(at: next)?.minY)
        #expect(originalY - foldedY > 15_000)
        #expect(Array(editor.view.string.utf16) == Array(text.utf16))
        #expect(editor.source.text == text)
        #expect(!editor.undo.canUndo)
        editor.wrapper.configuration.showsHiddenContentRow = false
        editor.wrapper.updateNativeView(editor.scroll, coordinator: editor.coordinator)
        let withoutRow = try #require(editor.view.lineFrame(at: next)?.minY)
        #expect(abs(foldedY - withoutRow - 28) < 0.5)
        #expect(editor.controller.isCurrentSectionFolded)
        #expect(!editor.undo.canUndo)
        try #require(editor.controller.performFoldingCommand(.expandAll))
        let reopenedY = try #require(editor.view.lineFrame(at: next)?.minY)
        #expect(abs(reopenedY - originalY) < 0.5)
    }

    @Test("the first destructive replacement reveals hidden source and a fresh action edits once")
    func destructiveAdmission() throws {
        let text = "# First\nsecret\n# Last\nvisible\n"
        let editor = try Editor(text)
        defer { editor.finish() }
        try editor.fold()
        let all = NSRange(location: 0, length: text.utf16.count)
        editor.view.setSelectedRange(all)
        #expect(!editor.undo.canUndo)
        editor.view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: all)
        #expect(editor.view.string == text)
        #expect(!editor.view.hasMarkedText())
        #expect(!editor.undo.canUndo)
        try editor.fold()
        editor.view.setSelectedRange(all)
        #expect(!editor.controller.replaceCharacters(in: [all], with: "replacement", expectedSource: text))
        #expect(editor.view.string == text)
        #expect(!editor.undo.canUndo)
        #expect(editor.controller.replaceCharacters(in: [all], with: "replacement", expectedSource: text))
        #expect(editor.view.string == "replacement")
        try #require(editor.undo.canUndo)
        editor.undo.undo()
        #expect(editor.view.string == text)
    }

    @Test("ordinary character arrows skip a folded body while Copy retains its source")
    func navigationAndCopy() throws {
        let text = "# First\nsecret\n# Last\nvisible\n"
        let editor = try Editor(text)
        defer { editor.finish() }
        try editor.fold()
        editor.view.setSelectedRange(NSRange(location: 7, length: 0))
        editor.view.moveForward(nil)
        #expect(editor.view.selectedRange() == NSRange(location: 15, length: 0))
        editor.view.moveBackward(nil)
        #expect(editor.view.selectedRange() == NSRange(location: 7, length: 0))
        let board = NSPasteboard(name: .init("fold-copy-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        editor.view.setSelectedRange(NSRange(location: 0, length: text.utf16.count))
        #expect(editor.view.writeSelection(to: board, types: editor.view.writablePasteboardTypes))
        #expect(board.string(forType: .string) == text)
    }

    @Test("fold commands refuse provisional input rather than committing or queueing it")
    func compositionGate() throws {
        let editor = try Editor("# First\nbody\n# Last\nend\n")
        defer { editor.finish() }
        editor.view.setSelectedRange(NSRange(location: 3, length: 0))
        editor.view.setMarkedText("\u{89c2}", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.view.hasMarkedText())
        #expect(!editor.controller.canPerformFoldingCommand(.toggleFold))
        #expect(!editor.controller.performFoldingCommand(.toggleFold))
        #expect(editor.view.hasMarkedText())
        editor.view.unmarkText()
        #expect(!editor.controller.isCurrentSectionFolded)
    }

    @Test("Cut reveals before touching the clipboard and held Delete needs a fresh press")
    func cutAndKeyRepeatAdmission() throws {
        let text = "# First\nsecret\n# Last\nvisible\n"
        let editor = try Editor(text)
        defer { editor.finish() }
        try editor.fold()
        let all = NSRange(location: 0, length: text.utf16.count)
        editor.view.setSelectedRange(all)
        let clipboardRevision = NSPasteboard.general.changeCount
        editor.view.cut(nil)
        #expect(NSPasteboard.general.changeCount == clipboardRevision)
        #expect(editor.view.string == text)
        #expect(!editor.undo.canUndo)
        try editor.fold()
        editor.view.setSelectedRange(all)
        func delete(repeatKey: Bool) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: editor.window.windowNumber, context: nil, characters: "\u{7f}",
                charactersIgnoringModifiers: "\u{7f}", isARepeat: repeatKey, keyCode: 51))
        }
        editor.view.keyDown(with: try delete(repeatKey: false))
        #expect(editor.view.string == text)
        editor.view.keyDown(with: try delete(repeatKey: true))
        #expect(editor.view.string == text)
        editor.view.keyDown(with: try delete(repeatKey: false))
        #expect(editor.view.string.isEmpty)
        #expect(editor.undo.canUndo)
    }

    @Test("Find reveals containing ancestors and keeps unrelated sections closed")
    func nestedFindReveal() throws {
        let text = "# Parent\nintro\n## Child\nneedle\n# Other\nkeep\n"
        let editor = try Editor(text)
        defer { editor.finish() }
        try #require(editor.controller.performFoldingCommand(.collapseAll))
        let target = (text as NSString).range(of: "needle")
        let other = (text as NSString).range(of: "# Other").location
        editor.coordinator.handleFindScrollToRange(Notification(name: .init("test.findScroll"), object: "fold-test",
            userInfo: ["range": target, "currentIndex": 0, "allRanges": [target]]))
        #expect(editor.view.selectedRange() == target)
        #expect(editor.coordinator.foldSession.collapsedHeadings == [other])
        #expect(editor.view.lineFrame(at: target.location) != nil)
        #expect(!editor.undo.canUndo)
    }

    @Test("session folds survive native-view disposal but a fresh document controller starts open")
    func sessionRemount() throws {
        let text = "# First\nbody\n# Last\nend\n"
        let controller = MarkdownEditorController()
        let initial = try Editor(text, controller: controller)
        try initial.fold()
        initial.finish()
        let remounted = try Editor(text, controller: controller)
        defer { remounted.finish() }
        remounted.view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(remounted.controller.isCurrentSectionFolded)
        #expect(remounted.coordinator.foldLayout.hiddenRange(containing: 8) != nil)
        let reopened = try Editor(text)
        defer { reopened.finish() }
        #expect(!reopened.controller.isCurrentSectionFolded)
        #expect(reopened.coordinator.foldLayout.hiddenRanges.isEmpty)
    }

    @Test("plain typing maps a later closed section without reopening it")
    func typingMapsClosedSections() throws {
        let text = "# First\nbody\n# Last\nend\n"
        let editor = try Editor(text)
        defer { editor.finish() }
        let last = (text as NSString).range(of: "# Last").location
        try editor.fold(at: last)
        editor.view.setSelectedRange(NSRange(location: 11, length: 0))
        editor.view.insertText("typed", replacementRange: editor.view.selectedRange())
        #expect(editor.view.string == "# First\nbodtypedy\n# Last\nend\n")
        #expect(editor.coordinator.foldSession.collapsedHeadings == [last + 5])
        #expect(editor.coordinator.foldLayout.hiddenRange(containing: last + 12) != nil)
    }

    @Test("Toggle from a table immediately before another heading folds the table's section")
    func tableCommandKeepsItsSection() throws {
        let editor = try Editor("# First\n| A |\n| --- |\n| value |\n# Last\nend\n")
        defer { editor.finish() }
        let token = try #require(editor.coordinator.cachedParsedDocument?.tokens.first { $0.kind == .table })
        editor.view.setSelectedRange(NSRange(location: token.range.location, length: 0))
        try #require(editor.coordinator.tableEditingSession.begin(range: token.range, row: 1, column: 0, selecting: .end))
        try #require(editor.controller.performFoldingCommand(.toggleFold))
        #expect(editor.coordinator.foldSession.collapsedHeadings == [0])
        #expect(editor.view.selectedRange().location == 7)
        #expect(!editor.coordinator.tableEditingSession.isActive)
    }

    @Test("committing marked input preserves an unrelated folded section")
    func compositionPreservesUnrelatedFolds() throws {
        let text = "# First\nbody\n# Last\nend\n"
        let editor = try Editor(text)
        defer { editor.finish() }
        let last = (text as NSString).range(of: "# Last").location
        try editor.fold(at: last)
        editor.view.setSelectedRange(NSRange(location: 11, length: 0))
        editor.view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.view.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.view.string == "# First\nbod你y\n# Last\nend\n")
        #expect(editor.coordinator.foldSession.collapsedHeadings == [last + 1])
    }

    @Test("accessibility exposes disclosure state and omits the folded body from spoken text")
    func accessibleDisclosure() throws {
        let text = "# First\nsecret\n# Last\nvisible\n"
        let editor = try Editor(text)
        defer { editor.finish() }
        try editor.fold()
        editor.coordinator.foldControls?.refresh()
        let spoken = try #require(editor.view.accessibilityString(for: NSRange(location: 0, length: text.utf16.count)))
        #expect(!spoken.contains("secret"))
        #expect(spoken.contains("1 block hidden"))
        let disclosure = try #require(editor.view.accessibilityChildren()?.compactMap { $0 as? NSButton }
            .first { $0.accessibilityRole() == .disclosureTriangle && $0.accessibilityLabel()?.contains("First") == true })
        #expect((disclosure.accessibilityValue() as? NSNumber)?.boolValue == false)
        #expect(disclosure.accessibilityPerformPress())
        #expect(editor.coordinator.foldLayout.hiddenRanges.isEmpty)
        #expect(editor.view.string == text)
        #expect(!editor.undo.canUndo)
    }

    @Test("native Undo maps unrelated folds before repairing selection")
    func nativeUndoKeepsFoldReceiptsCurrent() throws {
        let text = "# First\nbody\n# Last\nend\n"
        let editor = try Editor(text)
        defer { editor.finish() }
        editor.undo.groupsByEvent = false
        editor.undo.beginUndoGrouping()
        editor.view.setSelectedRange(NSRange(location: 11, length: 0))
        editor.view.insertText("typed", replacementRange: editor.view.selectedRange())
        editor.view.breakUndoCoalescing()
        editor.undo.endUndoGrouping()
        let changedLast = (editor.view.string as NSString).range(of: "# Last").location
        try editor.fold(at: changedLast)
        editor.undo.undo()
        #expect(editor.view.string == text)
        #expect(editor.coordinator.foldSession.collapsedHeadings == [13])
        editor.undo.redo()
        #expect(editor.coordinator.foldSession.collapsedHeadings == [18])
    }

    @Test("typing at a body boundary remains inside that folded section")
    func insertionAtBodyStartStaysHidden() throws {
        let editor = try Editor("# First\nbody\n# Last\nend\n")
        defer { editor.finish() }
        editor.view.setSelectedRange(NSRange(location: 8, length: 0))
        editor.view.insertText("prefix", replacementRange: editor.view.selectedRange())
        try #require(editor.controller.performFoldingCommand(.toggleFold))
        #expect(editor.view.lineFrame(at: 8) == nil)
        #expect(editor.view.string == "# First\nprefixbody\n# Last\nend\n")
    }

    @Test("successive marked updates before a folded section retain input and fold state")
    func markedUpdatesDoNotUseStaleFoldOffsets() throws {
        let editor = try Editor("# A\nx\n# B\ny\n")
        defer { editor.finish() }
        try editor.fold(at: 6)
        editor.view.setSelectedRange(NSRange(location: 4, length: 0))
        editor.view.setMarkedText("abcdefghij", selectedRange: NSRange(location: 10, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.view.setMarkedText("abcdefghijk", selectedRange: NSRange(location: 11, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.view.string == "# A\nabcdefghijkx\n# B\ny\n")
        #expect(editor.view.hasMarkedText())
        #expect(editor.coordinator.foldSession.collapsedHeadings == [6])
        editor.view.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.view.string == "# A\n你x\n# B\ny\n")
        #expect(editor.coordinator.foldSession.collapsedHeadings == [7])
    }

    @Test("controller-free document switches do not inherit equal-source folds")
    func localSessionIsDocumentScoped() throws {
        let editor = try Editor("# A\nx\n# B\ny\n", usesController: false)
        defer { editor.finish() }
        try #require(editor.coordinator.performFolding(.toggleFold, heading: 0))
        #expect(!editor.coordinator.foldLayout.hiddenRanges.isEmpty)
        editor.wrapper.documentId = "another-document"
        editor.wrapper.updateNativeView(editor.scroll, coordinator: editor.coordinator)
        #expect(editor.coordinator.foldLayout.hiddenRanges.isEmpty)
        #expect(editor.view.string == "# A\nx\n# B\ny\n")
    }


    @Test("a complete-line prefix retains both omission and summary spacing")
    func prefixKeepsSummaryGeometry() throws {
        let editor = try Editor("# First\nbody\n# Last\nend\n")
        defer { editor.finish() }
        try editor.fold()
        editor.view.setSelectedRange(NSRange(location: 0, length: 0))
        editor.view.insertText("\n", replacementRange: editor.view.selectedRange())
        #expect(editor.coordinator.foldSession.collapsedHeadings == [1])
        #expect(editor.view.lineFrame(at: 9) == nil)
        let withRow = try #require(editor.view.lineFrame(at: 14)?.minY)
        editor.wrapper.configuration.showsHiddenContentRow = false
        editor.wrapper.updateNativeView(editor.scroll, coordinator: editor.coordinator)
        let withoutRow = try #require(editor.view.lineFrame(at: 14)?.minY)
        #expect(abs(withRow - withoutRow - 28) < 0.5)
    }

    @Test("editing an ordered-list marker refreshes the canonical hidden-block count")
    func summaryTracksListMarkerEdit() async throws {
        let text = "# A\n12. one\n13. two\n14. three\n# B\nx\n"
        let editor = try Editor(text)
        defer { editor.finish() }
        let target = (text as NSString).range(of: "13. two").location + 1
        editor.view.setSelectedRange(NSRange(location: target, length: 0))
        editor.view.insertText("a", replacementRange: editor.view.selectedRange())
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while editor.coordinator.foldIndexNeedsReconciliation && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(editor.coordinator.foldSession.index.regions.first?.hiddenBlockCount == 3)
        #expect(editor.view.string.contains("1a3. two"))
    }

    @available(macOS 15.0, *)
    @Test("Writing Tools refuses hidden edits first and maps successive accepted replacements")
    func writingToolsMapsAcceptedReplacements() throws {
        let text = "# A\nx\n# B\ny\n"
        let editor = try Editor(text)
        defer { editor.finish() }
        try editor.fold(at: 6)
        let all = NSRange(location: 0, length: text.utf16.count)
        editor.view.setSelectedRange(all)
        editor.coordinator.textViewWritingToolsWillBegin(editor.view)
        editor.view.insertText("blocked", replacementRange: all)
        #expect(editor.view.string == text)
        #expect(!editor.undo.canUndo)
        editor.coordinator.textViewWritingToolsDidEnd(editor.view)

        try editor.fold(at: 6)
        editor.view.setSelectedRange(NSRange(location: 4, length: 0))
        editor.coordinator.textViewWritingToolsWillBegin(editor.view)
        editor.view.insertText("abcdefghij", replacementRange: NSRange(location: 4, length: 0))
        editor.view.insertText("replacement", replacementRange: NSRange(location: 4, length: 10))
        #expect(editor.view.string == "# A\nreplacementx\n# B\ny\n")
        #expect(editor.coordinator.foldSession.collapsedHeadings == [17])
        editor.coordinator.textViewWritingToolsDidEnd(editor.view)
        #expect(editor.coordinator.foldSession.collapsedHeadings == [17])
        #expect(editor.coordinator.foldSession.index.regions.first?.hiddenBlockCount == 1)
        #expect(editor.coordinator.foldSourceGeneration == editor.coordinator.nativeSourceGeneration)
    }


    @Test("fold buttons keep the pointing hand through native cursor callbacks")
    func foldButtonCursor() throws {
        let editor = try Editor("# First\nsecret\n# Last\nvisible\n")
        defer { editor.finish() }
        try editor.fold()
        editor.coordinator.foldControls?.refresh()
        let buttons = try #require(editor.view.accessibilityChildren()?.compactMap { $0 as? NSButton }
            .filter { $0.accessibilityLabel()?.contains("First") == true })
        #expect(buttons.count == 2)
        for button in buttons {
            let point = editor.view.convert(NSPoint(x: button.frame.midX, y: button.frame.midY), to: nil)
            let event = try #require(NSEvent.enterExitEvent(with: .cursorUpdate, location: point,
                modifierFlags: [], timestamp: 0, windowNumber: editor.window.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            NSCursor.arrow.set()
            button.cursorUpdate(with: event)
            #expect(NSCursor.current == NSCursor.pointingHand)
            NSCursor.arrow.set()
            editor.view.cursorUpdate(with: event)
            #expect(NSCursor.current == NSCursor.pointingHand)
        }
    }

}
