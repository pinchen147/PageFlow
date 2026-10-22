import AppKit
import Testing
@testable import MarkdownEngine

/// the reference editor's commenting flow in a mounted editor (doc 25 §1–§6): the bar's
/// Comment and Add reaction, the composer, the rail and the cards' actions.
@MainActor
@Suite("Comment flow", .serialized)
struct CommentFlowTests {
    static let source = "# Plan\n\nShip the quick brown fox on Monday.\n\nThen measure the lazy dog twice.\n"

    /// A wide page-look editor: the rail has room.
    private func mount(_ source: String = CommentFlowTests.source) async throws -> MountedTableEditor {
        CommentPalette.skipsMotion = true
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        configuration.readingWidth = 600
        let editor = try MountedTableEditor(source: source, configuration: configuration)
        editor.coordinator.selectionBar?.requiresKeyWindow = false
        editor.window.setContentSize(NSSize(width: 1200, height: 800))
        await editor.settle()
        return editor
    }

    private func select(_ quote: String, in editor: MountedTableEditor) {
        editor.main.setSelectedRange((editor.main.string as NSString).range(of: quote))
    }

    private func comments(_ editor: MountedTableEditor) throws -> MarkdownCommentsController {
        try #require(editor.coordinator.comments)
    }

    /// Opens the composer on `quote`, types `body` and presses Enter.
    private func post(_ body: String, on quote: String, in editor: MountedTableEditor) async throws {
        select(quote, in: editor)
        let comments = try comments(editor)
        comments.beginComment()
        await editor.settle()
        let composer = try #require(comments.composer)
        composer.field.text = body
        composer.field.onSubmit?()
        await editor.settle()
    }

    @Test("comment navigation waits for marked input and rejects changed source", arguments: ["ni", "你"])
    func commentNavigationDefersThroughComposition(_ committed: String) async throws {
        let editor = try await mount("# First\nsecret\n# Last\nvisible\n")
        defer { editor.close() }
        try await post("Review this", on: "secret", in: editor)
        let comments = try comments(editor)
        let id = try #require(editor.state.controller.commentThreads.first?.id)
        comments.collapse(announce: false)
        editor.main.setSelectedRange(NSRange(location: 0, length: 0))
        try #require(editor.state.controller.performFoldingCommand(.toggleFold))
        editor.window.makeFirstResponder(editor.main)
        editor.main.setSelectedRange(NSRange(location: 24, length: 0))
        editor.state.undo.beginUndoGrouping()
        defer {
            editor.main.breakUndoCoalescing()
            editor.state.undo.endUndoGrouping()
        }
        editor.main.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(editor.main.hasMarkedText())
        let provisional = editor.main.string
        editor.state.controller.openCommentThread(id)
        #expect(editor.main.hasMarkedText())
        #expect(editor.main.string == provisional)
        #expect(editor.coordinator.foldSession.collapsedHeadings == [0])
        #expect(comments.store.focusID == nil)

        editor.main.insertText(committed, replacementRange: NSRange(location: NSNotFound, length: 0))
        await editor.settle()
        #expect(!editor.main.hasMarkedText())
        if committed == "ni" {
            #expect(editor.coordinator.foldSession.collapsedHeadings.isEmpty)
            #expect(comments.store.focusID == id)
            #expect(editor.main.lineFrame(at: 8) != nil)
        } else {
            #expect(editor.coordinator.foldSession.collapsedHeadings == [0])
            #expect(comments.store.focusID == nil)
        }
    }

    @Test("Comment leads the bar, with no Add reaction; a code block's bar has only Comment")
    func barItems() async throws {
        let editor = try await mount("Text here.\n\n```\nlet x = 1\n```\n")
        defer { editor.close() }
        let bar = try #require(editor.coordinator.selectionBar)
        select("Text", in: editor)
        bar.update()
        #expect(bar.isShown)
        let visible = bar.bar.buttons.filter { !$0.value.isHidden }.map(\.key)
        #expect(visible.contains(.comment))
        #expect(!bar.bar.buttons.values.contains { $0.tooltip.localizedCaseInsensitiveContains("reaction") }, "no reactions on text")
        let commentX = try #require(bar.bar.buttons[.comment]).frame.minX
        #expect(bar.bar.buttons.values.filter { !$0.isHidden }.allSatisfy { $0.frame.minX >= commentX })
        #expect(bar.bar.buttons[.comment]?.isEnabled == true)
        select("let x", in: editor)
        bar.update()
        #expect(bar.isShown)
        #expect(Set(bar.bar.buttons.filter { !$0.value.isHidden }.map(\.key)) == [.comment])
    }

    @Test("the first comment floats its composer; Enter posts it and the rail seats")
    func firstComment() async throws {
        let editor = try await mount()
        defer { editor.close() }
        var persisted: [[MarkdownCommentThread]] = []
        editor.state.controller.onCommentThreadsChange = { persisted.append($0) }
        let comments = try comments(editor)
        select("quick brown fox", in: editor)
        comments.beginComment()
        await editor.settle()
        #expect(comments.composerFloats)
        #expect(editor.main.selectedRange().length == 0)
        #expect(comments.highlights.paints[MarkdownCommentsController.draftID] != nil)
        let composer = try #require(comments.composer)
        #expect(!composer.send.isEnabled)
        composer.field.text = "Is Monday realistic?"
        #expect(composer.send.isEnabled)
        composer.field.onSubmit?()
        await editor.settle()
        #expect(comments.composer == nil)
        let thread = try #require(editor.state.controller.commentThreads.first)
        #expect(thread.root.body == "Is Monday realistic?")
        #expect(thread.anchor.exact == "quick brown fox")
        #expect(persisted.count == 1)
        // The rail seats and the column ends 340 from the right.
        #expect(comments.railSeated)
        #expect(comments.rail.cards[thread.id] != nil)
        let clip = editor.scroll.contentView.bounds.width
        let textRight = editor.main.frame.minX + editor.main.textContainerOrigin.x + 600
        #expect(clip - textRight >= CommentRailView.keepout - 1)
        // The card stands level with its highlight.
        let card = try #require(comments.rail.cards[thread.id])
        let highlightTop = try #require(comments.highlights.paints[thread.id]?.rects.first?.minY)
        #expect(abs(card.frame.minY - highlightTop) < 1)
    }

    @Test("Escape discards the draft without asking and puts the caret after the text")
    func escapeDiscards() async throws {
        let editor = try await mount()
        defer { editor.close() }
        let comments = try comments(editor)
        select("lazy dog", in: editor)
        let end = NSMaxRange(editor.main.selectedRange())
        comments.beginComment()
        await editor.settle()
        comments.composer?.field.text = "half written"
        comments.composer?.onDiscard?()
        await editor.settle()
        #expect(comments.composer == nil && editor.state.controller.commentStore.draft == nil)
        #expect(editor.state.controller.commentThreads.isEmpty)
        #expect(editor.main.selectedRange() == NSRange(location: end, length: 0))
    }

    @Test("a second comment opens as a draft card in the rail, pinned at its anchor")
    func draftCardInRail() async throws {
        let editor = try await mount()
        defer { editor.close() }
        try await post("First", on: "quick brown fox", in: editor)
        let comments = try comments(editor)
        select("lazy dog", in: editor)
        comments.beginComment()
        await editor.settle()
        #expect(!comments.composerFloats)
        let composer = try #require(comments.composer)
        #expect(composer.superview === comments.rail)
        let draftTop = try #require(comments.highlights.paints[MarkdownCommentsController.draftID]?.rects.first?.minY)
        #expect(abs(composer.frame.minY - draftTop) < 1)
    }

    @Test("clicking a card opens it; a reply posts; ⌥⌘M at the caret cycles to it")
    func openAndReply() async throws {
        let editor = try await mount()
        defer { editor.close() }
        try await post("First", on: "quick brown fox", in: editor)
        let comments = try comments(editor)
        let id = try #require(editor.state.controller.commentThreads.first?.id)
        let card = try #require(comments.rail.cards[id])
        comments.cardClicked(card)
        await editor.settle()
        #expect(editor.state.controller.commentStore.focusID == id)
        #expect(card.isExpanded && card.replyField != nil)
        #expect(comments.highlights.paints[id]?.underlined == true)
        comments.card(card, reply: "Second thoughts")
        await editor.settle()
        #expect(editor.state.controller.commentThreads.first?.replies.map(\.body) == ["Second thoughts"])
        comments.collapse(announce: true)
        #expect(editor.state.controller.commentStore.focusID == nil)
        // ⌥⌘M with the caret inside the commented text opens it.
        let range = try #require(editor.state.controller.commentStore.ranges[id])
        editor.main.setSelectedRange(NSRange(location: range.location + 2, length: 0))
        comments.commandComment()
        #expect(editor.state.controller.commentStore.focusID == id)
    }

    @Test("resolving hides the thread and its highlight; Reopen brings it back")
    func resolveAndReopen() async throws {
        let editor = try await mount()
        defer { editor.close() }
        try await post("First", on: "quick brown fox", in: editor)
        let comments = try comments(editor)
        let id = try #require(editor.state.controller.commentThreads.first?.id)
        comments.cardResolve(try #require(comments.rail.cards[id]))
        await editor.settle()
        #expect(editor.state.controller.commentThreads.first?.resolved == true)
        #expect(comments.highlights.paints[id] == nil)
        #expect(!comments.railSeated)
        editor.state.controller.commentStore.update(id) { $0.resolved = false }
        await editor.settle()
        #expect(comments.highlights.paints[id] != nil)
    }

    @Test("a reaction a note already holds shows as a chip; its pill removes it")
    func savedReaction() async throws {
        let editor = try await mount()
        defer { editor.close() }
        let comments = try comments(editor)
        editor.state.controller.commentThreads = [MarkdownCommentThread(
            anchor: MarkdownCommentAnchor(prefix: "", exact: "lazy dog", suffix: ""), reactionOnly: true,
            root: MarkdownComment(body: "\u{1F44D}")
        )]
        await editor.settle()
        let thread = try #require(editor.state.controller.commentThreads.first)
        #expect(thread.reactionOnly && thread.root.body == "\u{1F44D}")
        let card = try #require(comments.rail.cards[thread.id])
        // A chip: its pill, no time or body, 42 tall.
        #expect(card.isChip)
        #expect(card.fittingHeight() == 42)
        comments.card(card, toggle: "\u{1F44D}", on: thread.root.id)
        #expect(editor.state.controller.commentThreads.isEmpty)
    }

    @Test("edit saves and marks edited; deleting the root deletes the thread")
    func editAndDelete() async throws {
        let editor = try await mount()
        defer { editor.close() }
        try await post("Frist", on: "quick brown fox", in: editor)
        let comments = try comments(editor)
        let thread = try #require(editor.state.controller.commentThreads.first)
        let card = try #require(comments.rail.cards[thread.id])
        comments.card(card, saveEdit: "First", of: thread.root.id)
        let edited = try #require(editor.state.controller.commentThreads.first?.root)
        #expect(edited.body == "First" && edited.edited)
        comments.card(card, confirmDelete: thread.root.id)
        #expect(editor.state.controller.commentThreads.isEmpty)
        await editor.settle()
        #expect(comments.highlights.paints.isEmpty)
    }

    @Test("the list shows open threads with quotes; resolved fold under All; detached say was on")
    func listMode() async throws {
        let editor = try await mount()
        defer { editor.close() }
        var modes: [MarkdownCommentsMode] = []
        editor.state.controller.onCommentsModeChange = { modes.append($0) }
        try await post("Keep", on: "quick brown fox", in: editor)
        try await post("Gone soon", on: "lazy dog", in: editor)
        let comments = try comments(editor)
        let store = editor.state.controller.commentStore
        let threads = editor.state.controller.commentThreads
        // Resolve the first; delete the text of the second (it detaches).
        store.update(threads[0].id) { $0.resolved = true }
        let range = try #require(store.ranges[threads[1].id])
        editor.state.undo.beginUndoGrouping()
        editor.main.insertText("", replacementRange: range)
        editor.state.undo.endUndoGrouping()
        editor.state.controller.commentsMode = .list
        await editor.settle()
        #expect(modes == [.list])
        let panel = try #require(comments.listPanel)
        #expect(panel.superview === editor.scroll)
        #expect(abs(panel.frame.width - CommentListPanel.width) < 0.5)
        // Open filter by default: the detached open thread, saying where it was.
        #expect(Set(panel.cards.keys) == [threads[1].id])
        #expect(panel.cards[threads[1].id]?.quote?.detached == true)
        #expect(panel.cards[threads[1].id]?.quote?.text == "lazy dog")
        // All: open rows, then the resolved fold.
        store.filter = .all
        comments.refresh()
        #expect(Set(panel.cards.keys) == [threads[1].id])
        comments.resolvedFoldOpen = true
        comments.refresh()
        #expect(Set(panel.cards.keys) == [threads[0].id, threads[1].id])
        // The edge handle resizes the docked list within 240–600; the column follows.
        panel.resizeHandle.onResize?(400, false)
        #expect(abs(panel.frame.width - 400) < 0.5)
        #expect(editor.main.commentLaneReserve == 420)
        panel.resizeHandle.onResize?(CommentListPanel.width, true)
        #expect(abs(panel.frame.width - CommentListPanel.width) < 0.5)
        // Close goes back to the margin.
        panel.closeButton.onPress?()
        #expect(editor.state.controller.commentsMode == .margin)
        #expect(comments.listPanel == nil)
    }

    @Test("hidden comments paint nothing and seat no rail; showing brings them back")
    func hiddenMode() async throws {
        let editor = try await mount()
        defer { editor.close() }
        try await post("Note", on: "quick brown fox", in: editor)
        let comments = try comments(editor)
        editor.state.controller.commentsMode = .hidden
        await editor.settle()
        #expect(comments.highlights.paints.isEmpty)
        #expect(!comments.railSeated && comments.rail.superview == nil)
        #expect(editor.main.commentLaneReserve == 0)
        editor.state.controller.commentsMode = .margin
        await editor.settle()
        #expect(comments.railSeated && !comments.highlights.paints.isEmpty)
    }

    @Test("a narrow page keeps a 64 pt icon lane; a chip opens the cluster's peek; typing closes it")
    func narrowLane() async throws {
        let editor = try await mount()
        defer { editor.close() }
        try await post("One", on: "quick brown fox", in: editor)
        try await post("Two", on: "lazy dog", in: editor)
        let comments = try comments(editor)
        // 600 measure + 368 = 968: a 900 wide editor is narrow.
        editor.window.setContentSize(NSSize(width: 900, height: 800))
        await editor.settle()
        #expect(comments.isWide == false)
        #expect(comments.iconLaneSeated && comments.iconLane.superview != nil)
        #expect(editor.main.commentLaneReserve == CommentIconLaneView.keepout)
        #expect(comments.rail.superview == nil)
        #expect(comments.iconLane.chips.count == 2)
        #expect(comments.iconLane.chips.first?.cluster?.count == 1)
        let id = try #require(editor.state.controller.commentThreads.first?.id)
        comments.iconLane.chips.first?.onPress?()
        await editor.settle()
        let peek = try #require(comments.peek)
        #expect(peek.cards.map(\.threadID) == [id])
        #expect(peek.cards.first?.isExpanded == true)
        #expect(peek.frame.width <= CommentPeekView.maximumWidth)
        // Typing in the document closes it.
        editor.state.undo.beginUndoGrouping()
        editor.main.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        editor.state.undo.endUndoGrouping()
        await editor.settle()
        #expect(comments.peek == nil && editor.state.controller.commentStore.focusID == nil)
    }

    @Test("clusters join anchors less than 32 apart and count threads and replies")
    func clusters() {
        let clusters = CommentIconLaneView.clusters([("a", 100, 1), ("b", 120, 3), ("c", 160, 1)])
        #expect(clusters.map(\.ids) == [["a", "b"], ["c"]])
        #expect(clusters.map(\.count) == [4, 1])
    }

    @Test("cards take the keyboard: arrows move, Enter opens then replies, Escape closes then returns to the text")
    func cardKeyboard() async throws {
        let editor = try await mount()
        defer { editor.close() }
        try await post("One", on: "quick brown fox", in: editor)
        try await post("Two", on: "lazy dog", in: editor)
        let comments = try comments(editor)
        let ids = editor.state.controller.commentThreads.map(\.id)
        func key(_ code: UInt16, _ characters: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: editor.window.windowNumber,
                             context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        let first = try #require(comments.rail.cards[ids[0]])
        editor.window.makeFirstResponder(first)
        #expect(first.showsFocusRing)
        #expect(editor.state.controller.commentStore.activeID == ids[0])
        first.keyDown(with: key(125, "\u{F701}"))
        let second = try #require(comments.rail.cards[ids[1]])
        #expect(editor.window.firstResponder === second)
        second.keyDown(with: key(126, "\u{F700}"))
        #expect(editor.window.firstResponder === first)
        first.keyDown(with: key(36, "\r"))
        await editor.settle()
        #expect(editor.state.controller.commentStore.focusID == ids[0])
        let open = try #require(comments.rail.cards[ids[0]])
        open.keyDown(with: key(36, "\r"))
        await editor.settle()
        #expect(open.replyField?.hasFocus == true)
        editor.window.makeFirstResponder(open)
        open.keyDown(with: key(53, "\u{1b}"))
        await editor.settle()
        #expect(editor.state.controller.commentStore.focusID == nil)
        let closed = try #require(comments.rail.cards[ids[0]])
        editor.window.makeFirstResponder(closed)
        closed.keyDown(with: key(53, "\u{1b}"))
        #expect(editor.window.firstResponder === editor.main)
        let range = try #require(editor.state.controller.commentStore.ranges[ids[0]])
        #expect(editor.main.selectedRange() == NSRange(location: NSMaxRange(range), length: 0))
    }

    @Test("the table's Comment outlines the whole table and seats its card")
    func tableComment() async throws {
        let source = "Intro line.\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\nAfter the table.\n"
        let editor = try await mount(source)
        defer { editor.close() }
        let comments = try comments(editor)
        let token = try #require(editor.coordinator.parsedDocument(for: editor.main.string).tokens.first { $0.kind == .table })
        comments.beginTableComment(token.range)
        await editor.settle()
        #expect(comments.highlights.paints[MarkdownCommentsController.draftID]?.outline != nil)
        let composer = try #require(comments.composer)
        composer.field.text = "Numbers check out?"
        composer.field.onSubmit?()
        await editor.settle()
        let thread = try #require(editor.state.controller.commentThreads.first)
        #expect(thread.table)
        let paint = try #require(comments.highlights.paints[thread.id])
        #expect(paint.outline != nil && paint.rects.count == 1)
        #expect(comments.rail.cards[thread.id] != nil)
    }

    @Test("a long thread caps at min(456, 55 % of the viewport + 16) and scrolls inside with See more")
    func cardHeightCap() async throws {
        let editor = try await mount()
        defer { editor.close() }
        try await post("First", on: "quick brown fox", in: editor)
        let comments = try comments(editor)
        let id = try #require(editor.state.controller.commentThreads.first?.id)
        let long = (1...40).map { "Line \($0) of a long reply." }.joined(separator: "\n")
        let card = try #require(comments.rail.cards[id])
        comments.cardClicked(card)
        await editor.settle()
        for _ in 0..<3 { comments.card(card, reply: long) }
        // A short window: the cap (55 % of the viewport + 16) is well under the thread.
        editor.window.setContentSize(NSSize(width: 1200, height: 500))
        await editor.settle()
        let shown = try #require(comments.rail.cards[id])
        let cap = min(456, editor.scroll.contentView.bounds.height * 0.55 + 16)
        #expect(abs(shown.frame.height - cap) < 1)
        let seeMore = try #require(shown.subviews.first { ($0 as? CommentTextButton)?.title.hasSuffix("See more") == true })
        #expect(!seeMore.isHidden)
    }

    @Test("full-width text keeps the rail too: the wrap ends 340 short of the right edge, and widens back")
    func fullWidthRail() async throws {
        CommentPalette.skipsMotion = true
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        let editor = try MountedTableEditor(source: Self.source, configuration: configuration)
        defer { editor.close() }
        editor.coordinator.selectionBar?.requiresKeyWindow = false
        editor.window.setContentSize(NSSize(width: 1200, height: 800))
        await editor.settle()
        let wrapBefore = try #require(editor.main.textContainer?.size.width)
        try await post("Wide", on: "quick brown fox", in: editor)
        let comments = try comments(editor)
        #expect(comments.railSeated)
        let inset = editor.main.textContainerInset.width
        let wrap = try #require(editor.main.textContainer?.size.width)
        #expect(abs(wrap - (editor.main.frame.width - inset * 2 - CommentRailView.keepout)) < 1)
        let id = try #require(editor.state.controller.commentThreads.first?.id)
        let card = try #require(comments.rail.cards[id])
        let cardInText = card.convert(card.bounds, to: editor.main)
        #expect(cardInText.minX >= editor.main.textContainerOrigin.x + wrap)
        // Narrow: the icon lane, 88 reserved.
        editor.window.setContentSize(NSSize(width: 900, height: 800))
        await editor.settle()
        #expect(comments.iconLaneSeated)
        #expect(abs((editor.main.textContainer?.size.width ?? 0) - (editor.main.frame.width - inset * 2 - CommentIconLaneView.keepout)) < 1)
        // Hidden: the wrap is the editor's again.
        editor.state.controller.commentsMode = .hidden
        editor.window.setContentSize(NSSize(width: 1200, height: 800))
        await editor.settle()
        #expect(abs((editor.main.textContainer?.size.width ?? 0) - wrapBefore) < 1)
    }

    static let tableSource = "Intro line.\n\n| Name | Note |\n| --- | --- |\n| Apples | crisp and red |\n| Pears | soft |\n\nAfter the table.\n"

    @Test("a range of selected cells takes a comment; each cell is filled over the table")
    func cellRangeComment() async throws {
        let editor = try await mount(Self.tableSource)
        defer { editor.close() }
        let comments = try comments(editor)
        _ = try editor.focusCell(inTableContaining: "| Name", row: 1, column: 0)
        let session = editor.coordinator.tableEditingSession
        session.setCellSelection(TableCellSelection(anchor: CellCoord(row: 1, column: 0), head: CellCoord(row: 2, column: 0)))
        let target = try #require(comments.commentTarget)
        #expect(target.cells)
        #expect((editor.main.string as NSString).substring(with: target.range).hasPrefix("Apples"))
        comments.beginComment()
        await editor.settle()
        let composer = try #require(comments.composer)
        composer.field.text = "Check the fruit"
        composer.field.onSubmit?()
        await editor.settle()
        let thread = try #require(editor.state.controller.commentThreads.first)
        #expect(thread.cells && !thread.table)
        let paint = try #require(comments.currentPaints[thread.id])
        #expect(paint.overTable && paint.rects.count == 2)
        #expect(comments.tableHighlights.paints[thread.id] != nil)
        #expect(comments.highlights.paints[thread.id] == nil)
        #expect(comments.rail.cards[thread.id] != nil)
    }

    @Test("text selected in a cell takes a comment on just that text")
    func textInCellComment() async throws {
        let editor = try await mount(Self.tableSource)
        defer { editor.close() }
        let comments = try comments(editor)
        let cell = try editor.focusCell(inTableContaining: "| Name", row: 1, column: 1)
        #expect(cell.string == "crisp and red")
        cell.setSelectedRange(NSRange(location: 0, length: 5))
        let target = try #require(comments.commentTarget)
        #expect(!target.cells)
        #expect((editor.main.string as NSString).substring(with: target.range) == "crisp")
        comments.beginComment()
        await editor.settle()
        let composer = try #require(comments.composer)
        composer.field.text = "Which apple?"
        composer.field.onSubmit?()
        await editor.settle()
        let thread = try #require(editor.state.controller.commentThreads.first)
        let paint = try #require(comments.currentPaints[thread.id])
        #expect(paint.overTable && paint.rects.count == 1)
        // Just the word, not the cell.
        let range = try #require(editor.state.controller.commentStore.ranges[thread.id])
        let table = try #require(comments.table(holding: range, in: editor.main))
        let geometry = try #require(editor.coordinator.tableEditingSession.geometry(forTableAt: table.range))
        #expect(paint.rects[0].width < geometry.cellRects[1][1].width - 20)
    }

    @Test("Copy link copies the note's address with #thread-id, and the link opens the comment")
    func copyAndOpenLink() async throws {
        let editor = try await mount()
        defer { editor.close() }
        try await post("Linked", on: "lazy dog", in: editor)
        let comments = try comments(editor)
        let controller = editor.state.controller
        let id = try #require(controller.commentThreads.first?.id)
        controller.commentLinkBase = URL(fileURLWithPath: "/tmp/notes/plan.md")
        var toasts: [String] = []
        controller.onCommentsToast = { toasts.append($0) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pf-comments-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        comments.copyLink(base: try #require(controller.commentLinkBase), threadID: id, pasteboard: pasteboard)
        let link = try #require(pasteboard.string(forType: .string))
        #expect(link == "file:///tmp/notes/plan.md#thread-\(id)")
        #expect(toasts == ["Link copied"])
        #expect(MarkdownEditorController.commentThreadID(inFragment: URL(string: link)?.fragment) == id)
        #expect(MarkdownEditorController.commentThreadID(inFragment: "heading") == nil)
        controller.openCommentThread(id)
        #expect(controller.commentStore.focusID == id)
        // A resolved thread opens in the list, under All.
        comments.collapse(announce: false)
        controller.commentStore.update(id) { $0.resolved = true }
        controller.openCommentThread(id)
        #expect(controller.commentsMode == .list)
        #expect(comments.listPanel?.cards[id] != nil)
    }

    @Test("⌥⇧C hides and shows comments only while the keyboard is outside the text")
    func hideChord() async throws {
        let editor = try await mount()
        defer { editor.close() }
        try await post("Chord", on: "lazy dog", in: editor)
        let comments = try comments(editor)
        let number = editor.window.windowNumber
        func chord(_ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                          windowNumber: number, context: nil, characters: characters,
                                          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        }
        let optionShiftC = try chord("Ç", 8, [.option, .shift])
        editor.window.makeFirstResponder(editor.main)
        #expect(!comments.handlesHideChord(optionShiftC, inWindow: number))
        let card = try #require(comments.rail.cards.values.first)
        editor.window.makeFirstResponder(card)
        #expect(comments.handlesHideChord(optionShiftC, inWindow: number))
        #expect(editor.state.controller.commentsMode == .hidden)
        #expect(comments.handlesHideChord(optionShiftC, inWindow: number))
        #expect(editor.state.controller.commentsMode == .margin)
        #expect(!comments.handlesHideChord(optionShiftC, inWindow: number + 1))
        #expect(!comments.handlesHideChord(try chord("c", 8, [.option]), inWindow: number), "another chord")
        // Rebound to a chord with ⌘, it works in the text too.
        var configuration = editor.coordinator.configuration
        configuration.keyBindings[.toggleComments] = [MarkdownKeyChord("h", command: true, shift: true)]
        editor.coordinator.configuration = configuration
        editor.window.makeFirstResponder(editor.main)
        #expect(!comments.handlesHideChord(optionShiftC, inWindow: number), "the old chord no longer hides")
        #expect(comments.handlesHideChord(try chord("H", 4, [.command, .shift]), inWindow: number))
        #expect(editor.state.controller.commentsMode == .hidden)
    }

    @Test("a wide table stops 308 short of the edge beside a card, and runs into the lane when cards are clear")
    func wideTableAndRail() async throws {
        let wide = "| Column one heading | Column two heading | Column three heading | Column four heading | Column five heading | Column six heading |\n| --- | --- | --- | --- | --- | --- |\n| a fairly long value | another long value | yet another value | still more text here | the fifth column | the sixth column |\n"
        let filler = (1...30).map { "Paragraph \($0) of filler text for the note." }.joined(separator: "\n\n")
        let source = "Comment near here.\n\n" + wide + "\n" + filler + "\n\nFar away words at the end.\n"
        let editor = try await mount(source)
        defer { editor.close() }
        let comments = try comments(editor)
        let container = try #require(editor.main.superview)
        try await post("Near", on: "Comment near", in: editor)
        await editor.settle()
        let overlay = try #require(editor.main.wideTableOverlays.values.first)
        #expect(editor.main.commentTableKeepout == CommentRailView.tableKeepout)
        #expect(abs(overlay.frame.width - (container.bounds.width - 308)) < 1, "a card beside it: blocked")
        // Move the only thread far away: the table is freed into the lane.
        let id = try #require(editor.state.controller.commentThreads.first?.id)
        editor.state.controller.commentStore.remove(id)
        try await post("Far", on: "Far away words", in: editor)
        await editor.settle()
        comments.refresh()
        await editor.settle()
        #expect(abs(overlay.frame.width - container.bounds.width) < 1, "every card clear: freed")
    }

    @Test("the reference editor's click-away: a drag to new text moves an empty draft, a plain click drops it, typed text keeps it")
    func clickAwayReanchor() async throws {
        let editor = try await mount()
        defer { editor.close() }
        let comments = try comments(editor)
        func mouseDown() throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 5, y: 5), modifierFlags: [], timestamp: 0,
                                            windowNumber: editor.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        select("quick brown fox", in: editor)
        comments.beginComment()
        await editor.settle()
        // A drag that selects other text: the empty draft moves there.
        comments.documentMouseDown(try mouseDown())
        select("lazy dog", in: editor)
        comments.documentMouseUp()
        let moved = try #require(editor.state.controller.commentStore.draft)
        #expect((editor.main.string as NSString).substring(with: moved.range) == "lazy dog")
        #expect(comments.composer != nil)
        // With text in it, a click elsewhere keeps the draft where it is.
        comments.composer?.field.text = "Kept"
        comments.documentMouseDown(try mouseDown())
        select("Ship the", in: editor)
        comments.documentMouseUp()
        #expect(editor.state.controller.commentStore.draft?.range == moved.range)
        // Empty again, a plain click (no selection) drops it.
        comments.composer?.field.text = ""
        comments.documentMouseDown(try mouseDown())
        editor.main.setSelectedRange(NSRange(location: 3, length: 0))
        comments.documentMouseUp()
        #expect(editor.state.controller.commentStore.draft == nil && comments.composer == nil)
    }
}
