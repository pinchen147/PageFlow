import AppKit
import Testing
@testable import MarkdownEngine

/// A drag the tests drive by hand: a pasteboard, a pointer and a sequence.
@MainActor
final class MockDraggingInfo: NSObject, NSDraggingInfo {
    private static var nextSequence = 9_000

    let draggingPasteboard: NSPasteboard
    var draggingLocation: NSPoint
    weak var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = [.copy, .link, .generic]
    let draggingSequenceNumber: Int
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1

    init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow?) {
        draggingPasteboard = pasteboard
        draggingLocation = location
        draggingDestinationWindow = window
        Self.nextSequence += 1
        draggingSequenceNumber = Self.nextSequence
    }

    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}

/// Files dragged over the note (doc 26 §9): images land between blocks under
/// a monochrome drop line and are imported by the host; documents go to the
/// host as tabs; anything else is refused.
@MainActor
@Suite("File drop import", .serialized)
struct FileDropImportTests {
    final class Host {
        var hovers: [MarkdownFileDragKind?] = []
        var documents: [[URL]] = []
        var drops: [MarkdownImageDrop] = []
        var pending: [([String]) -> Void] = []
        /// Answer at once with one link per file (or one for data).
        var answersAtOnce = true
    }

    private static let source = "A paragraph\n\nB paragraph\n\nC paragraph"

    private func mount(_ source: String = Self.source, configuration: MarkdownEditorConfiguration = .default) async throws
        -> (MountedTableEditor, Host) {
        let editor = try MountedTableEditor(source: source, configuration: configuration)
        let host = Host()
        let main = editor.main
        main.opensDroppedFile = { ["md", "markdown", "pdf"].contains($0.pathExtension) }
        main.onDropDocuments = { urls in host.documents.append(urls); return true }
        main.onFileDragHover = { host.hovers.append($0) }
        main.onImportImages = { drop, completion in
            host.drops.append(drop)
            let links = drop.fileURLs.map { "![\($0.deletingPathExtension().lastPathComponent)](\($0.lastPathComponent))" }
                + (drop.imageData == nil ? [] : ["![Pasted image](Pasted image.png)"])
            if host.answersAtOnce { completion(links) } else { host.pending.append { _ in completion(links) } }
        }
        await editor.settle()
        return (editor, host)
    }

    private func pasteboard(_ urls: [URL]) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("pf-drop-\(UUID().uuidString)"))
        board.clearContents()
        board.writeObjects(urls.map { $0 as NSURL })
        return board
    }

    private func file(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/pf-drop/\(name)") }

    /// A drag whose pointer sits on the gap of the slot at `offset`.
    private func drag(_ board: NSPasteboard, toSlot offset: Int, in editor: MountedTableEditor) throws -> MockDraggingInfo {
        let slot = try #require(editor.main.dropSlotsNearViewport().first { $0.offset == offset })
        let point = NSPoint(x: editor.main.textContainerOrigin.x + 20, y: slot.y)
        return MockDraggingInfo(pasteboard: board, location: editor.main.convert(point, to: nil), window: editor.window)
    }

    private func indicator(in view: NSView) -> BlockDropIndicatorView? {
        view.subviews.compactMap { $0 as? BlockDropIndicatorView }.first { !$0.isHidden }
    }

    private func offset(of marker: String, in text: String) -> Int {
        (text as NSString).range(of: marker).location
    }

    @Test("an image drag over the text copies, under a 2 pt column-wide line in the label colour")
    func imageHover() async throws {
        let (editor, host) = try await mount()
        defer { editor.close() }
        let board = pasteboard([file("shot.png")])
        defer { board.releaseGlobally() }
        let b = offset(of: "B paragraph", in: Self.source)
        let info = try drag(board, toSlot: b, in: editor)

        #expect(editor.main.draggingEntered(info) == .copy)
        #expect(editor.main.fileDrag?.slot == b)
        #expect(host.hovers == [.images])
        let line = try #require(indicator(in: editor.main))
        let padding = editor.main.textContainer?.lineFragmentPadding ?? 0
        let columnWidth = (editor.main.textContainer?.size.width ?? 0) - 2 * padding
        #expect(line.frame.height == 2)
        #expect(abs(line.frame.minX - (editor.main.textContainerOrigin.x + padding)) < 0.5)
        #expect(abs(line.frame.width - columnWidth) < 0.5)
        // Centred in the gap between A's bottom and B's top.
        let slotY = try #require(editor.main.dropSlotsNearViewport().first { $0.offset == b }).y
        #expect(abs(line.frame.midY - slotY) <= 0.5)
        let bTop = try #require(editor.main.firstRect(forCharacterRange: NSRange(location: b, length: 1), actualRange: nil) as NSRect?)
        let bRect = editor.main.convert(editor.window.convertFromScreen(bTop), from: nil)
        #expect(line.frame.maxY <= bRect.minY + 0.5, "the line sits above B, in the gap")
        var expected: CGColor?
        line.effectiveAppearance.performAsCurrentDrawingAppearance {
            expected = NSColor.labelColor.withAlphaComponent(1).cgColor
        }
        #expect(line.layer?.backgroundColor == expected)

        editor.main.draggingExited(info)
        #expect(indicator(in: editor.main) == nil)
        #expect(host.hovers == [.images, nil])
        #expect(editor.main.string == Self.source)
    }

    @Test("a document-only drag forwards every file in order without changing note text",
          arguments: [["Other.md"], ["One.pdf", "Two.pdf", "Three.pdf"],
                      ["One.md", "Two.markdown", "Three.md"], ["One.pdf", "Two.md", "Three.pdf"]])
    func documentsOnly(names: [String]) async throws {
        let (editor, host) = try await mount()
        defer { editor.close() }
        let files = names.map(file)
        let board = pasteboard(files)
        defer { board.releaseGlobally() }
        let info = try drag(board, toSlot: offset(of: "B paragraph", in: Self.source), in: editor)

        #expect(editor.main.draggingEntered(info) == .copy)
        #expect(indicator(in: editor.main) == nil)
        #expect(host.hovers == [.documents])
        #expect(editor.main.prepareForDragOperation(info))
        #expect(editor.main.performDragOperation(info))
        editor.main.concludeDragOperation(info)
        #expect(host.documents == [files])
        #expect(host.drops.isEmpty)
        #expect(host.hovers == [.documents, nil])
        #expect(editor.main.string == Self.source)
    }

    @Test("a mixed drop inserts images at the slot and forwards every document",
          arguments: [["Other.md"], ["One.pdf", "Two.md", "Three.markdown"]])
    func mixedDrop(documents: [String]) async throws {
        let (editor, host) = try await mount()
        defer { editor.close() }
        let board = pasteboard([file("chart.png")] + documents.map(file))
        defer { board.releaseGlobally() }
        let info = try drag(board, toSlot: offset(of: "B paragraph", in: Self.source), in: editor)

        #expect(editor.main.draggingEntered(info) == .copy)
        #expect(host.hovers == [.images])
        #expect(editor.main.performDragOperation(info))
        editor.main.concludeDragOperation(info)
        #expect(host.documents == [documents.map(file)])
        #expect(host.drops.map(\.fileURLs) == [[file("chart.png")]])
        #expect(editor.main.string == "A paragraph\n\n![chart](chart.png)\n\nB paragraph\n\nC paragraph")
        #expect(indicator(in: editor.main) == nil)
        #expect(host.hovers == [.images, nil])
    }

    @Test("any other file is refused and nothing is reported")
    func otherFile() async throws {
        let (editor, host) = try await mount()
        defer { editor.close() }
        let board = pasteboard([file("archive.zip")])
        defer { board.releaseGlobally() }
        let info = try drag(board, toSlot: offset(of: "B paragraph", in: Self.source), in: editor)

        #expect(editor.main.draggingEntered(info) == [])
        #expect(editor.main.draggingUpdated(info) == [])
        #expect(indicator(in: editor.main) == nil)
        #expect(host.hovers.isEmpty)
        editor.main.draggingExited(info)
        #expect(host.hovers.isEmpty)
    }

    @Test("an inserted image stands as its own block: one Undo step, caret on the line after")
    func insertShape() async throws {
        let (editor, _) = try await mount()
        defer { editor.close() }
        let board = pasteboard([file("one.png"), file("two.png")])
        defer { board.releaseGlobally() }
        let c = offset(of: "C paragraph", in: Self.source)
        let info = try drag(board, toSlot: c, in: editor)
        _ = editor.main.draggingEntered(info)
        #expect(editor.main.performDragOperation(info))
        editor.main.concludeDragOperation(info)

        let expected = "A paragraph\n\nB paragraph\n\n![one](one.png)\n\n![two](two.png)\n\nC paragraph"
        #expect(editor.main.string == expected)
        #expect(editor.state.undo.undoActionName == "Add Images")
        let caret = editor.main.selectedRange()
        #expect(caret.length == 0)
        #expect((expected as NSString).substring(from: caret.location) == "\nC paragraph")
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
        #expect(!editor.state.undo.canUndo)
    }

    @Test("one image at the end of the note: blank line before, the caret after it")
    func insertAtEnd() async throws {
        let (editor, _) = try await mount()
        defer { editor.close() }
        let end = (Self.source as NSString).length
        #expect(editor.main.insertDroppedImages(["![x](x.png)"], at: end))
        #expect(editor.main.string == Self.source + "\n\n![x](x.png)\n")
        #expect(editor.state.undo.undoActionName == "Add Image")
        #expect(editor.main.selectedRange() == NSRange(location: (editor.main.string as NSString).length, length: 0))
    }

    @available(macOS 15.0, *)
    @Test("a completed import waits for native protected input and lands exactly once", arguments: ["main", "table", "writingTools"])
    func completedImportWaitsForProtectedInput(_ protection: String) async throws {
        let source = protection == "table"
            ? "A paragraph\n\n| H |\n| --- |\n| cell |\n\nC paragraph" : Self.source
        let (editor, host) = try await mount(source)
        defer { editor.close() }
        host.answersAtOnce = false
        editor.main.importImages(MarkdownImageDrop(fileURLs: [file("late.png")]),
                                 at: offset(of: "C paragraph", in: source))
        try #require(host.pending.count == 1)
        let input: NSTextView
        if protection == "table" {
            input = try editor.focusCell(inTableContaining: "| H", row: 1, column: 0)
        } else { input = editor.main }
        input.setSelectedRange(NSRange(location: 0, length: 0))
        editor.state.undo.beginUndoGrouping()
        if protection == "writingTools" {
            editor.coordinator.textViewWritingToolsWillBegin(editor.main)
        } else {
            input.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                                replacementRange: NSRange(location: NSNotFound, length: 0))
            try #require(input.hasMarkedText())
        }
        let provisional = input.string
        let marked = input.markedRange()
        let selection = input.selectedRange()
        host.pending.removeFirst()([])
        #expect(editor.main.pendingImageImports.count == 1,
                "completed links must remain owned while insertion is protected")
        #expect(!editor.main.string.contains("![late]"))
        #expect(input.string == provisional)
        #expect(input.markedRange() == marked)
        #expect(input.selectedRange() == selection)
        if protection == "writingTools" {
            editor.coordinator.textViewWritingToolsDidEnd(editor.main)
        } else {
            input.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        if editor.state.undo.groupingLevel > 0 { editor.state.undo.endUndoGrouping() }
        await editor.settle()
        let committed = protection == "main" ? "你" + source
            : protection == "table" ? source.replacingOccurrences(of: "| cell |", with: "| 你cell |") : source
        let expected = committed.replacingOccurrences(of: "C paragraph", with: "![late](late.png)\n\nC paragraph")
        #expect(editor.main.string == expected)
        #expect(editor.main.pendingImageImports.isEmpty)
        #expect(!input.hasMarkedText())
    }

    @Test("replacement and teardown retire completed imports retained during composition", arguments: ["replacement", "teardown"])
    func protectedCompletedImportRetiresWithItsDocument(_ boundary: String) async throws {
        let (editor, host) = try await mount()
        defer { if boundary != "teardown" { editor.close() } }
        host.answersAtOnce = false
        editor.main.importImages(MarkdownImageDrop(fileURLs: [file("late.png")]),
                                 at: offset(of: "C paragraph", in: Self.source))
        try #require(host.pending.count == 1)
        editor.main.setSelectedRange(NSRange(location: 0, length: 0))
        editor.state.undo.beginUndoGrouping()
        editor.main.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(editor.main.hasMarkedText())
        host.pending.removeFirst()([])
        #expect(editor.main.pendingImageImports.count == 1)
        let replacement = "Replacement document remains authoritative."
        if boundary == "replacement" {
            editor.state.text = replacement
            editor.wrapper.updateNativeView(editor.scroll, coordinator: editor.coordinator)
            editor.main.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        } else { editor.close() }
        if editor.state.undo.groupingLevel > 0 { editor.state.undo.endUndoGrouping() }
        await Task.yield()
        #expect(editor.main.pendingImageImports.isEmpty)
        #expect(indicator(in: editor.main) == nil)
        #expect(!editor.main.string.contains("![late]"))
        if boundary == "replacement" { #expect(editor.main.string == replacement) }
    }

    @Test("a slow import lands at its slot mapped through an edit made meanwhile")
    func mappedSlot() async throws {
        let (editor, host) = try await mount()
        defer { editor.close() }
        host.answersAtOnce = false
        let board = pasteboard([file("late.png")])
        defer { board.releaseGlobally() }
        let info = try drag(board, toSlot: offset(of: "C paragraph", in: Self.source), in: editor)
        _ = editor.main.draggingEntered(info)
        #expect(editor.main.performDragOperation(info))
        editor.main.concludeDragOperation(info)
        #expect(editor.main.string == Self.source)
        #expect(editor.main.pendingImageImports.count == 1)

        // Text typed above the slot meanwhile.
        let a = offset(of: "A paragraph", in: Self.source)
        #expect(editor.coordinator.replaceSourceRanges([NSRange(location: a, length: 0)], with: "New ",
                                                       expectedSource: editor.main.string, actionName: "Typing"))
        try #require(host.pending.count == 1)
        host.pending.removeFirst()([])
        #expect(editor.main.string == "New A paragraph\n\nB paragraph\n\n![late](late.png)\n\nC paragraph")
        #expect(editor.main.pendingImageImports.isEmpty)
    }

    @Test("a same-document reload retires a slow image import before its completion arrives")
    func reloadRetiresPendingImport() async throws {
        let (editor, host) = try await mount()
        defer { editor.close() }
        host.answersAtOnce = false
        let board = pasteboard([file("late.png")])
        defer { board.releaseGlobally() }
        let info = try drag(board, toSlot: offset(of: "B paragraph", in: Self.source), in: editor)
        _ = editor.main.draggingEntered(info)
        try #require(editor.main.performDragOperation(info))
        editor.main.concludeDragOperation(info)
        try #require(host.pending.count == 1)
        let progressDeadline = Date().addingTimeInterval(2)
        while indicator(in: editor.main)?.showsSpinner != true, Date() < progressDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(indicator(in: editor.main)?.showsSpinner == true,
                     "The outstanding import must own visible progress before reload")

        // External Reload updates the binding while retaining this document's ID.
        let documentID = editor.coordinator.documentId
        let reloaded = "Reloaded version from disk\n\nIts content stays authoritative."
        editor.state.text = reloaded
        editor.wrapper.updateNativeView(editor.scroll, coordinator: editor.coordinator)
        await editor.settle()
        try #require(editor.coordinator.documentId == documentID)
        try #require(editor.main.string == reloaded)
        try #require(!editor.state.undo.canUndo && !editor.state.undo.canRedo)
        #expect(editor.main.pendingImageImports.isEmpty)
        #expect(indicator(in: editor.main) == nil)

        host.pending.removeFirst()([])
        await editor.settle()
        #expect(editor.main.string == reloaded,
                "An import admitted before Reload must not edit the replacement source")
        #expect(!editor.state.undo.canUndo && !editor.state.undo.canRedo,
                "The retired import must not add history after Reload cleared it")
        #expect(editor.main.pendingImageImports.isEmpty)
        #expect(indicator(in: editor.main) == nil)
    }

    @Test("an image import inside a long contiguous list refuses an unproven block boundary")
    func longListImportRefusesUnprovenBoundary() async throws {
        let source = (0..<9_000).map { "- Contiguous list item \($0)" }.joined(separator: "\n")
        let (editor, _) = try await mount(source)
        defer { editor.close() }
        let middle = offset(of: "- Contiguous list item 5000", in: source)
        try #require(middle != NSNotFound)
        #expect(!editor.main.insertDroppedImages(["![late](late.png)"], at: middle),
                "An insertion inside an uninterrupted list must not invent a nearby boundary or jump to a distant one")
        #expect(editor.main.string == source)
        #expect(!editor.state.undo.canUndo && !editor.state.undo.canRedo)
    }

    @Test("image data with no file is imported as a drop")
    func imageData() async throws {
        let (editor, host) = try await mount()
        defer { editor.close() }
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        let board = NSPasteboard(name: NSPasteboard.Name("pf-drop-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.writeObjects([image])
        let info = try drag(board, toSlot: offset(of: "B paragraph", in: Self.source), in: editor)

        #expect(editor.main.draggingEntered(info) == .copy)
        #expect(editor.main.performDragOperation(info))
        editor.main.concludeDragOperation(info)
        let drop = try #require(host.drops.first)
        #expect(drop.fileURLs.isEmpty)
        #expect(drop.imageData.map { NSImage(data: $0) != nil } == true)
        #expect(editor.main.string == "A paragraph\n\n![Pasted image](Pasted image.png)\n\nB paragraph\n\nC paragraph")
    }

    @Test("a read-only note refuses images and still opens documents")
    func readOnly() async throws {
        let (editor, host) = try await mount()
        defer { editor.close() }
        editor.main.isEditable = false
        let images = pasteboard([file("shot.png")])
        defer { images.releaseGlobally() }
        let b = offset(of: "B paragraph", in: Self.source)
        let imageDrag = try drag(images, toSlot: b, in: editor)
        #expect(editor.main.draggingEntered(imageDrag) == [])
        #expect(indicator(in: editor.main) == nil)
        #expect(!editor.main.performDragOperation(imageDrag))
        editor.main.concludeDragOperation(imageDrag)
        #expect(host.drops.isEmpty)

        let mixed = pasteboard([file("shot.png"), file("Doc.pdf")])
        defer { mixed.releaseGlobally() }
        let mixedDrag = try drag(mixed, toSlot: b, in: editor)
        #expect(editor.main.draggingEntered(mixedDrag) == .copy)
        #expect(host.hovers == [.documents])
        #expect(editor.main.performDragOperation(mixedDrag))
        #expect(host.documents == [[file("Doc.pdf")]])
        #expect(host.drops.isEmpty)
        #expect(editor.main.string == Self.source)
    }

    @Test("a drag over a page-look gutter is the column's: same slot as at the column's left edge")
    func gutterForwarding() async throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.readingWidth = 240
        let (editor, host) = try await mount(configuration: configuration)
        defer { editor.close() }
        let container = try #require(editor.main.superview as? NativeTextViewContainer)
        #expect(container.registeredDraggedTypes.contains(.fileURL))
        try #require(editor.main.frame.minX > 20, "the column must leave a gutter")
        let board = pasteboard([file("shot.png")])
        defer { board.releaseGlobally() }
        let c = offset(of: "C paragraph", in: Self.source)
        let slot = try #require(editor.main.dropSlotsNearViewport().first { $0.offset == c })
        let inColumn = editor.main.convert(NSPoint(x: editor.main.textContainerOrigin.x, y: slot.y), to: nil)
        let inGutter = NSPoint(x: container.convert(NSPoint(x: 4, y: 0), to: nil).x, y: inColumn.y)
        let info = MockDraggingInfo(pasteboard: board, location: inGutter, window: editor.window)

        #expect(container.draggingEntered(info) == .copy)
        #expect(editor.main.fileDrag?.slot == c)
        #expect(indicator(in: editor.main) != nil)
        #expect(container.performDragOperation(info))
        container.concludeDragOperation(info)
        #expect(editor.main.string == "A paragraph\n\nB paragraph\n\n![shot](shot.png)\n\nC paragraph")
        #expect(host.hovers == [.images, nil])
    }

    @Test("paste over an image whose source is selected replaces it in one Undo step")
    func pasteReplacesSelectedImage() async throws {
        let source = "A\n\n![old](old.png)\n\nB"
        let (editor, _) = try await mount(source)
        defer { editor.close() }
        editor.main.onPasteImage = { _ in "![new](new.png)" }
        let board = NSPasteboard(name: NSPasteboard.Name("pf-paste-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.writeObjects([file("new.png") as NSURL])
        // The object selection (Phase 2) selects the image's whole token.
        editor.main.setSelectedRange((source as NSString).range(of: "![old](old.png)"))

        editor.state.undo.beginUndoGrouping()
        #expect(editor.main.paste(from: board))
        editor.state.undo.endUndoGrouping()
        #expect(editor.main.string == "A\n\n![new](new.png)\n\nB")
        editor.state.undo.undo()
        #expect(editor.main.string == source)
    }

    @Test("the import entry replays use lands like a drop")
    func controllerEntry() async throws {
        let (editor, host) = try await mount()
        defer { editor.close() }
        let slots = editor.state.controller.dropSlotsNearViewport
        let b = offset(of: "B paragraph", in: Self.source)
        #expect(slots.contains(b))
        editor.state.controller.importImages(MarkdownImageDrop(fileURLs: [file("r.png")]), at: b)
        #expect(host.drops.count == 1)
        #expect(editor.main.string == "A paragraph\n\n![r](r.png)\n\nB paragraph\n\nC paragraph")
    }
}
