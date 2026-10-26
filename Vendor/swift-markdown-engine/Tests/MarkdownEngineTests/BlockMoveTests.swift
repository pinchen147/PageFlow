import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Block moves", .serialized)
struct BlockMoveTests {
    @Test("an upward code move never pins the source block being removed")
    func upwardMovePastRasterKeepsSurvivingSourceStill() async throws {
        struct Formula: LatexRenderer {
            func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? {
                let size = CGSize(width: 180, height: 48)
                return LatexRenderResult(image: NSImage(size: size), size: size, baselineOffset: 12)
            }
        }
        var configuration = MarkdownEditorConfiguration.default
        configuration.services.latex = Formula()
        let padding = (0..<40).map { "Leading paragraph \($0).\n\n" }.joined()
        let block = "```swift\nlet one = 1\nlet two = 2\nlet three = 3\n```"
        // No blank paragraph separates the raster destination from the dragged
        // block: that code is the first readable source after the destination.
        let source = padding + "$$E=mc^2$$\n" + block + "\n\nSurviving witness paragraph.\n\n"
            + String(repeating: "Following paragraph.\n\n", count: 40)
        let editor = try MountedTableEditor(source: source, configuration: configuration)
        defer { editor.close() }
        await editor.settle()
        let target = padding.utf16.count
        let range = (source as NSString).range(of: block)
        let layout = try #require(editor.main.textLayoutManager)
        let content = try #require(layout.textContentManager)
        func fragment(at offset: Int) throws -> NSTextLayoutFragment {
            let location = try #require(content.location(content.documentRange.location, offsetBy: offset))
            return try #require(layout.textLayoutFragment(for: location))
        }
        editor.main.scrollRangeToVisible(NSRange(location: target, length: 1))
        await editor.settle()
        let targetY = try fragment(at: target).layoutFragmentFrame.minY + editor.main.textContainerOrigin.y
        editor.scroll.contentView.scroll(to: NSPoint(x: editor.scroll.contentView.bounds.minX, y: targetY - 40))
        editor.scroll.reflectScrolledClipView(editor.scroll.contentView)
        await editor.settle()
        let witness = "Surviving witness paragraph."
        func witnessY() throws -> CGFloat {
            let offset = (editor.main.string as NSString).range(of: witness).location
            let frame = try fragment(at: offset).layoutFragmentFrame
            return frame.minY + editor.main.textContainerOrigin.y - editor.main.visibleRect.minY
        }
        let before = try witnessY()
        try #require(before > 0 && before + 30 < editor.main.visibleRect.height)
        let payload = try #require(editor.coordinator.blockMovePayload(range: range, kind: .code))
        #expect(editor.coordinator.moveBlock(payload, to: target))
        await editor.settle()
        #expect(abs(try witnessY() - before) <= 1,
                "a surviving source paragraph must not inherit the deleted code block's old viewport position")
        editor.state.undo.undo()
        #expect(editor.main.string == source)
    }

    @Test("complete equation and fence moves render only local images through undo and redo")
    func boundedBlockRestyling() async throws {
        final class ImageRequests: EmbeddedImageProvider, @unchecked Sendable {
            private let lock = NSLock()
            private var names: [String] = []
            func image(for reference: EmbeddedImageRequest) -> NSImage? {
                lock.lock(); names.append(reference.name); lock.unlock()
                return nil
            }
            func reset() { lock.lock(); names.removeAll(); lock.unlock() }
            var farRequests: [String] {
                lock.lock(); defer { lock.unlock() }
                return names.filter { $0.hasPrefix("far-") }
            }
            func fingerprint() -> AnyHashable { 0 }
        }
        for (kind, block) in [(BlockMovePasteboard.Kind.equation, "$$\na=b\n\nc=d\n$$"),
                              (.code, "```swift\nlet a=1\n\nlet b=2\n```")] {
            let images = ImageRequests()
            var configuration = MarkdownEditorConfiguration.default
            configuration.services.images = images
            let padding = String(repeating: "An unrelated paragraph remains outside the edited blocks and the visible viewport.\n\n", count: 2_000)
            let distant = (0..<16).map { "![far \($0)](far-\($0).png)" }.joined(separator: "\n\n")
            let source = "Lead\n\n" + block + "\n\nMiddle\n\nTarget\n\n" + padding + distant
            let editor = try MountedTableEditor(source: source, configuration: configuration)
            defer { editor.close() }
            await editor.settle()
            let range = (source as NSString).range(of: block)
            let payload = try #require(editor.coordinator.blockMovePayload(range: range, kind: kind))
            images.reset()
            #expect(editor.coordinator.moveBlock(payload, to: (source as NSString).range(of: "Target").location))
            let moved = editor.main.string
            func signature(_ tokens: [MarkdownToken]) -> [String] {
                tokens.map { "\($0.kind):\($0.range):\($0.contentRange):\($0.markerRanges)" }
            }
            #expect(signature(try #require(editor.coordinator.cachedParsedDocument).tokens)
                == signature(MarkdownTokenizer.parseTokensViaAST(in: moved, memoizing: false)))
            #expect(images.farRequests.isEmpty, "moving a closed block must not render unrelated offscreen images")
            images.reset()
            editor.state.undo.undo()
            #expect(editor.main.string == source)
            #expect(signature(try #require(editor.coordinator.cachedParsedDocument).tokens)
                == signature(MarkdownTokenizer.parseTokensViaAST(in: source, memoizing: false)))
            #expect(images.farRequests.isEmpty, "Undo inherits the bounded complete-block scope")
            images.reset()
            editor.state.undo.redo()
            #expect(editor.main.string == moved)
            #expect(images.farRequests.isEmpty, "Redo inherits the bounded complete-block scope")
            images.reset()
            #expect(editor.coordinator.replaceSourceRanges([(moved as NSString).range(of: block)], with: "",
                expectedSource: moved, actionName: "Generic replacement", reflowsParagraphChain: false))
            #expect(!images.farRequests.isEmpty, "arbitrary delimiter replacements retain conservative restyling")
        }
    }

    @Test("copying closed math after an unmatched opener preserves fresh whole-document semantics")
    func unmatchedMathCopy() async throws {
        for opening in ["$$unclosed", ">                    $$unclosed"] {
        var source = "Lead\n\n" + opening + "\n\nTarget\n\nend"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        await editor.settle()
        if opening.hasPrefix(">") {
            let marker = (source as NSString).range(of: ">")
            #expect(editor.coordinator.replaceSourceRanges([marker], with: "", expectedSource: source,
                actionName: "Remove quote", reflowsParagraphChain: false))
            source = (source as NSString).replacingCharacters(in: marker, with: "")
        }
        let equation = "$$\nx\n$$"
        let payload = BlockMovePasteboard(source: equation, range: NSRange(location: 0, length: equation.utf16.count),
            kind: .equation, document: "foreign", editor: "foreign", baseFolder: nil)
        #expect(editor.coordinator.moveBlock(payload, to: (source as NSString).range(of: "Target").location))
        func signature(_ tokens: [MarkdownToken]) -> [String] {
            tokens.map { "\($0.kind):\($0.range):\($0.contentRange):\($0.markerRanges)" }
        }
        #expect(signature(try #require(editor.coordinator.cachedParsedDocument).tokens)
            == signature(MarkdownTokenizer.parseTokensViaAST(in: editor.main.string, memoizing: false)))
        editor.state.undo.undo()
        #expect(editor.main.string == source)
        #expect(signature(try #require(editor.coordinator.cachedParsedDocument).tokens)
            == signature(MarkdownTokenizer.parseTokensViaAST(in: source, memoizing: false)))
        }
    }

    @Test("identity and hash protect the source; another editor copies and rebases images")
    func identity() throws {
        let source = "![photo](attachments/x.png)"
        let payload = BlockMovePasteboard(source: source, range: NSRange(location: 0, length: source.utf16.count),
                                         kind: .image, document: "doc", editor: "editor", baseFolder: URL(fileURLWithPath: "/notes/a"))
        #expect(payload.isLocal(document: "doc", editor: "editor"))
        #expect(!payload.isLocal(document: "doc", editor: "other"))
        #expect(payload.matches(source as NSString))
        #expect(!payload.matches("![other](attachments/x.png)" as NSString))
        #expect(payload.rebasedSource(to: URL(fileURLWithPath: "/notes")) == "![photo](a/attachments/x.png)")
        #expect(payload.rebasedSource(to: URL(fileURLWithPath: "/elsewhere")) == "![photo](/notes/a/attachments/x.png)")
    }

    @Test("a rejected destination leaves source bytes and undo history untouched")
    func rejectedInsertion() throws {
        final class RejectInsert: NSObject, NSTextViewDelegate {
            func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
                replacementString?.isEmpty == true
            }
        }
        let source = "![alt](x.png)\n\nB\n\nC"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        let range = (source as NSString).range(of: "![alt](x.png)")
        let payload = try #require(editor.coordinator.blockMovePayload(range: range, kind: .image))
        let admission = RejectInsert()
        editor.main.delegate = admission
        #expect(!editor.coordinator.moveBlock(payload, to: (source as NSString).length))
        #expect(editor.main.string == source)
        #expect(!editor.state.undo.canUndo)
        editor.main.delegate = editor.coordinator
    }

    @Test("rebasing preserves literal percent and Markdown URL delimiters in file names")
    func encodedFileNames() {
        let source = "![a](attachments/literal%2520name%23%3F%3C%3E%5C%3A.png)"
        let payload = BlockMovePasteboard(source: source, range: NSRange(location: 0, length: source.utf16.count),
            kind: .image, document: "doc", editor: "editor", baseFolder: URL(fileURLWithPath: "/notes"))
        #expect(payload.rebasedSource(to: URL(fileURLWithPath: "/target")) == "![a](/notes/attachments/literal%2520name%23%3F%3C%3E%5C%3A.png)")
    }

    @Test("rebasing decodes Markdown escapes and never treats an encoded colon as a scheme")
    func escapedFileNames() {
        for (source, expected) in [
            ("![a](literal%3Aname.png)", "![a](/notes/literal%3Aname.png)"),
            (#"![a](a\(b\).png)"#, "![a](/notes/a%28b%29.png)"),
            (#"![a](a\)b.png)"#, "![a](/notes/a%29b.png)"),
            (#"![a `]` b](shot.png)"#, #"![a `]` b](/notes/shot.png)"#),
            (#"![a `]` b](<shot.png> "title (kept)")"#, #"![a `]` b](</notes/shot.png> "title (kept)")"#),
        ] {
            let payload = BlockMovePasteboard(source: source, range: NSRange(location: 0, length: source.utf16.count),
                kind: .image, document: "doc", editor: "editor", baseFolder: URL(fileURLWithPath: "/notes"))
            #expect(payload.rebasedSource(to: URL(fileURLWithPath: "/target")) == expected)
        }
    }

    @Test("a moved image retains its whole line's indentation and trailing spaces")
    func indentedImage() throws {
        let source = "A\n\n  ![alt](x.png) \n\nB\n\nC"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        let payload = try #require(editor.coordinator.blockMovePayload(range: (source as NSString).range(of: "![alt](x.png)"), kind: .image))
        #expect(editor.coordinator.moveBlock(payload, to: (source as NSString).range(of: "C").location))
        #expect(editor.main.string == "A\n\nB\n\n  ![alt](x.png) \n\nC")
        editor.state.undo.undo()
        #expect(editor.main.string == source)
    }

    @Test("images under a paragraph move alone; move, undo and redo preserve exact bytes")
    func imageMove() throws {
        let source = "Intro\n![alt](x.png)\n\nB\n\nC"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        let range = (source as NSString).range(of: "![alt](x.png)")
        let payload = try #require(editor.coordinator.blockMovePayload(range: range, kind: .image))
        #expect(editor.coordinator.moveBlock(payload, to: (source as NSString).range(of: "C").location))
        #expect(editor.main.string == "Intro\nB\n\n![alt](x.png)\n\nC")
        #expect(editor.state.undo.undoActionName == "Move Image")
        editor.state.undo.undo()
        #expect(editor.main.string == source)
        editor.state.undo.redo()
        #expect(editor.main.string == "Intro\nB\n\n![alt](x.png)\n\nC")
    }

    @Test("copy keeps the source and source edits reject a local move")
    func copyAndStale() throws {
        let source = "![alt](x.png)\n\nB"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        let range = (source as NSString).range(of: "![alt](x.png)")
        let payload = try #require(editor.coordinator.blockMovePayload(range: range, kind: .image))
        #expect(editor.coordinator.moveBlock(payload, to: (source as NSString).length, copying: true))
        #expect(editor.main.string == source + "\n\n![alt](x.png)\n")
        #expect(editor.state.undo.undoActionName == "Duplicate Image")
        editor.state.undo.undo()
        _ = editor.coordinator.replaceSourceRanges([range], with: "![new](x.png)", expectedSource: source, actionName: "Edit")
        let changed = editor.main.string
        #expect(!editor.coordinator.moveBlock(payload, to: changed.utf16.count))
        #expect(editor.main.string == changed)
    }

    @Test("no landing inside code, math, tables, lists or the moved block boundaries")
    func protectedSlots() throws {
        let source = "```swift\na\n\nb\n```\n\n$$\nx\n\ny\n$$\n\n- one\n- two\n\nEnd"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        let range = try #require(editor.coordinator.parsedDocument(for: source).tokens.first { $0.kind == .codeBlock }).range
        let payload = try #require(editor.coordinator.blockMovePayload(range: range, kind: .code))
        for text in ["b", "y", "- two"] {
            #expect(!editor.coordinator.moveBlock(payload, to: (source as NSString).range(of: text).location))
        }
        #expect(!editor.coordinator.moveBlock(payload, to: 0))
        #expect(editor.main.string == source)
    }
    @Test("each block kind moves intact through blank interiors and undo")
    func allKinds() throws {
        let fixtures: [(BlockMovePasteboard.Kind, String, MarkdownTokenKind)] = [
            (.code, "```swift\na\n\nb\n```", .codeBlock),
            (.diagram, "```mermaid\ngraph TD\nA-->B\n```", .codeBlock),
            (.equation, "$$\nx\n\ny\n$$", .blockLatex),
            (.table, "| a | b |\n| - | - |\n| 1 | 2 |", .table),
        ]
        for (kind, block, tokenKind) in fixtures {
            let source = "A\n\n" + block + "\n\nB\n\nC"
            let editor = try MountedTableEditor(source: source)
            defer { editor.close() }
            let token = try #require(editor.coordinator.parsedDocument(for: source).tokens.first { $0.kind == tokenKind })
            let payload = try #require(editor.coordinator.blockMovePayload(range: token.range, kind: kind))
            #expect(editor.coordinator.moveBlock(payload, to: (source as NSString).range(of: "C", options: .backwards).location))
            #expect(editor.main.string == "A\n\nB\n\n" + block + "\n\nC")
            if kind != .table {
                #expect(editor.main.selectedRange() == NSRange(location: 6 + block.utf16.count + 1, length: 0),
                        "the caret starts the empty line immediately after the moved block")
            }
            editor.state.undo.undo()
            #expect(editor.main.string == source)
            editor.state.undo.redo()
            #expect(editor.main.string == "A\n\nB\n\n" + block + "\n\nC")
        }
    }

    @Test("commented image follows move, undo and redo; option copies do not clone threads")
    func imageComment() throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        let source = "![alt](x.png)\n\nB\n\nC"
        let editor = try MountedTableEditor(source: source, configuration: configuration)
        defer { editor.close() }
        let store = editor.state.controller.commentStore
        let range = (source as NSString).range(of: "![alt](x.png)")
        let thread = MarkdownCommentThread(anchor: MarkdownCommentAnchoring.selector(for: range, in: source as NSString),
                                           root: MarkdownComment(body: "Keep attached"))
        store.add(thread, range: range)
        let payload = try #require(editor.coordinator.blockMovePayload(range: range, kind: .image))
        #expect(editor.coordinator.moveBlock(payload, to: (source as NSString).length))
        #expect(store.ranges[thread.id] == (editor.main.string as NSString).range(of: "![alt](x.png)"))
        editor.state.undo.undo()
        #expect(store.ranges[thread.id] == range)
        editor.state.undo.redo()
        #expect(store.ranges[thread.id] == (editor.main.string as NSString).range(of: "![alt](x.png)"))
        let moved = try #require(store.ranges[thread.id])
        let copied = try #require(editor.coordinator.blockMovePayload(range: moved, kind: .image))
        #expect(editor.coordinator.moveBlock(copied, to: 0, copying: true))
        #expect(store.threads.count == 1)
        #expect(store.ranges[thread.id]?.location != 0)
    }

    @Test("moving code retains the commented occurrence across blank separators through Undo and Redo",
          arguments: ["\n\nAfter", "\n \t\nAfter"], [true, false])
    func identicalCommentContextsPreserveMovedOffset(_ separator: String, _ duplicateQuote: Bool) throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        let repeated = String(repeating: "a", count: 40) + "target" + String(repeating: "b", count: 40)
        let first = duplicateQuote ? repeated : repeated.replacingOccurrences(of: "target", with: "other!")
        let block = "```text\n" + first + "\n" + repeated + "\n```"
        let source = "Before\n\n" + block + separator
        let editor = try MountedTableEditor(source: source, configuration: configuration)
        defer { editor.close() }
        let store = editor.state.controller.commentStore
        let original = (source as NSString).range(of: "target", options: .backwards)
        let thread = MarkdownCommentThread(anchor: MarkdownCommentAnchoring.selector(for: original, in: source as NSString),
                                           root: MarkdownComment(body: "The second identical occurrence"))
        store.add(thread, range: original)
        let payload = try #require(editor.coordinator.blockMovePayload(range: (source as NSString).range(of: block), kind: .code))
        try #require(editor.coordinator.moveBlock(payload, to: source.utf16.count))
        let moved = editor.main.string
        #expect(moved == "Before\n\nAfter\n\n" + block)
        let movedRange = (moved as NSString).range(of: "target", options: .backwards)
        #expect(store.ranges[thread.id] == movedRange)
        let later = MarkdownCommentThread(anchor: MarkdownCommentAnchoring.selector(for: movedRange, in: moved as NSString),
                                          root: MarkdownComment(body: "Added after the move"))
        store.add(later, range: movedRange)
        editor.state.undo.undo()
        #expect(editor.main.string == source)
        #expect(store.ranges[thread.id] == original)
        #expect(store.ranges[later.id] == original)
        editor.state.undo.redo()
        #expect(editor.main.string == moved)
        #expect(store.ranges[thread.id] == movedRange)
        #expect(store.ranges[later.id] == movedRange)
    }

    @Test("foreign payload copies instead of deleting an identically positioned target block")
    func foreignEditor() throws {
        let source = "![alt](attachments/x.png)"
        let payload = BlockMovePasteboard(source: source, range: NSRange(location: 0, length: source.utf16.count),
                                         kind: .image, document: "other", editor: "other", baseFolder: URL(fileURLWithPath: "/notes"))
        let editor = try MountedTableEditor(source: "Target")
        defer { editor.close() }
        #expect(editor.coordinator.moveBlock(payload, to: 6))
        #expect(editor.main.string == "Target\n\n![alt](/notes/attachments/x.png)\n")
        editor.state.undo.undo()
        #expect(editor.main.string == "Target")
    }

    @Test("native drag routing shows monochrome feedback, refuses own boundaries, then applies the drop")
    func nativeDrop() async throws {
        let source = "![alt](x.png)\n\nB\n\nC"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        await editor.settle()
        let range = (source as NSString).range(of: "![alt](x.png)")
        let payload = try #require(editor.coordinator.blockMovePayload(range: range, kind: .image))
        let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        payload.write(to: item)
        board.writeObjects([item])
        let slots = editor.main.dropSlotsNearViewport()
        let own = try #require(slots.first { $0.offset == 0 })
        let drag = MockDraggingInfo(pasteboard: board,
            location: editor.main.convert(NSPoint(x: editor.main.textContainerOrigin.x + 20, y: own.y), to: nil), window: editor.window)
        drag.draggingSourceOperationMask = [.copy, .move]
        #expect(editor.main.draggingEntered(drag).isEmpty)
        let destination = try #require(slots.first { $0.offset == (source as NSString).range(of: "C").location })
        drag.draggingLocation = editor.main.convert(NSPoint(x: editor.main.textContainerOrigin.x + 20, y: destination.y), to: nil)
        #expect(editor.main.draggingUpdated(drag) == .move)
        let feedback = try #require(editor.coordinator.blockMover.dropSession?.indicator)
        #expect(feedback.frame.height == 4)
        feedback.effectiveAppearance.performAsCurrentDrawingAppearance {
            #expect(feedback.layer?.backgroundColor == NSColor.labelColor.withAlphaComponent(1).cgColor)
        }
        #expect(editor.main.prepareForDragOperation(drag))
        #expect(editor.main.performDragOperation(drag))
        #expect(editor.main.string == "B\n\n![alt](x.png)\n\nC")
        editor.main.concludeDragOperation(drag)
        #expect(editor.coordinator.blockMover.dropSession == nil)
    }

    @Test("the code hover grip tracks the viewport and a real press selects fences")
    func codeGrip() async throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        let source = "A\n\n```swift\nlet x = 1\n\nlet y = 2\n```\n\nEnd"
        let editor = try MountedTableEditor(source: source, configuration: configuration)
        defer { editor.close() }
        await editor.settle()
        let code = try #require(editor.coordinator.parsedDocument(for: source).tokens.first { $0.kind == .codeBlock })
        let screen = editor.main.firstRect(forCharacterRange: NSRange(location: code.range.location, length: 1), actualRange: nil)
        let rect = editor.main.convert(editor.window.convertFromScreen(screen), from: nil)
        let mover = editor.coordinator.blockMover
        mover.hover(at: NSPoint(x: rect.minX + 20, y: rect.minY + 3))
        let hovered = try #require(mover.hovered)
        #expect(hovered.range == code.range)
        #expect(hovered.kind == .code)
        #expect(hovered.grip.size == CGSize(width: 26, height: 26))
        let point = editor.main.convert(NSPoint(x: hovered.grip.midX, y: hovered.grip.midY), to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: editor.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 1,
            windowNumber: editor.window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        var events = [up]
        mover.press(down) { events.isEmpty ? nil : events.removeFirst() }
        #expect(editor.main.selectedRange() == code.range)
        #expect(editor.main.string == source)
    }

}

/// The table handle's drag (doc 24 §5.7.6): the source block moves between
/// top-level blocks as one Undo step and comes back with every cell selected.
@MainActor
@Suite("Table block move", .serialized)
struct TableMoveTests {
    static let table = "| t | u |\n| - | - |\n| 1 | 2 |"

    private func range(_ editor: MountedTableEditor) throws -> NSRange {
        try #require(editor.coordinator.parsedDocument(for: editor.main.string).tokens.first { $0.kind == .table }).range
    }

    private func move(_ editor: MountedTableEditor, _ range: NSRange, to target: Int) -> Bool {
        guard let payload = editor.coordinator.blockMovePayload(range: range, kind: .table) else { return false }
        return editor.coordinator.moveBlock(payload, to: target)
    }

    @Test("a table moves down, up and to the end as one Undo step each, with every cell selected after")
    func moves() async throws {
        let source = "A\n\n" + Self.table + "\n\nB\n\nC"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        let ns = source as NSString
        #expect(move(editor, try range(editor), to: ns.range(of: "C").location))
        #expect(editor.main.string == "A\n\nB\n\n" + Self.table + "\n\nC")
        let session = editor.coordinator.tableEditingSession
        #expect(session.cellSelection == TableCellSelection(anchor: CellCoord(row: 0, column: 0), head: CellCoord(row: 1, column: 1)))
        editor.state.undo.undo()
        #expect(editor.main.string == source)
        #expect(move(editor, try range(editor), to: 0))
        #expect(editor.main.string == Self.table + "\n\nA\n\nB\n\nC")
        editor.state.undo.undo()
        #expect(editor.main.string == source)
        #expect(move(editor, try range(editor), to: ns.length))
        #expect(editor.main.string == "A\n\nB\n\nC\n\n" + Self.table)
        editor.state.undo.undo()
        #expect(editor.main.string == source)
    }

    @Test("a drop on the table's own place changes nothing and adds no Undo step")
    func ownPlace() async throws {
        let source = "A\n\n" + Self.table + "\n\nB"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        let table = try range(editor)
        #expect(!move(editor, table, to: table.location))
        #expect(!move(editor, table, to: (source as NSString).range(of: "B").location))
        #expect(editor.main.string == source)
        #expect(!editor.state.undo.canUndo)
    }

    @Test("a handle press without movement is a click: every cell selected")
    func handleClick() async throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        let source = "A\n\n" + Self.table + "\n\nB"
        let editor = try MountedTableEditor(source: source, configuration: configuration)
        defer { editor.close() }
        await editor.settle()
        let chrome = try #require(editor.coordinator.tableChrome)
        let anchor = (source as NSString).range(of: "| t").location
        let image = try #require(editor.main.tableImageRect(at: anchor))
        chrome.hover(at: NSPoint(x: image.minX + 10, y: image.minY + 10))
        try #require(chrome.table != nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: editor.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: editor.window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        var queue = [up]
        chrome.pressHandle(down) { queue.isEmpty ? nil : queue.removeFirst() }
        #expect(editor.coordinator.tableEditingSession.cellSelection
            == TableCellSelection(anchor: CellCoord(row: 0, column: 0), head: CellCoord(row: 1, column: 1)))
    }
}
