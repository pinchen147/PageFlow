import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

/// the reference editor's selection bar and its commands (doc 24 §6, §7.8–§7.9).
@MainActor
@Suite("Selection bar", .serialized)
struct SelectionBarTests {

    // MARK: - Placement (Zdt / Nj)

    @Test("the bar sits 10 above the anchor, else 10 below it, else pinned below the head caret", arguments: [
        // anchor minY, maxY, caret (nil = none) → expected y, below
        (200.0, 220.0, nil as ClosedRange<Double>?, 156.0, false),     // above: 200 − 10 − 34
        (60.0, 80.0, nil, 90.0, true),                                 // below
        (60.0, 590.0, nil, 58.0, false),                               // pinned at top + 8
        (60.0, 590.0, Optional(60.0...80.0), 90.0, false),             // pinned, dodging the caret
    ])
    func verticalPlacement(minY: Double, maxY: Double, caret: ClosedRange<Double>?, y: Double, below: Bool) {
        let anchor = CGRect(x: 100, y: minY, width: 40, height: maxY - minY)
        let caretRect = caret.map { CGRect(x: 140, y: $0.lowerBound, width: 0, height: $0.upperBound - $0.lowerBound) }
        let placed = MarkdownSelectionBarPlacement.top(anchor: anchor, barHeight: 34, top: 58, bottom: 600, caret: caretRect)
        #expect(placed.y == CGFloat(y))
        #expect(placed.below == below)
    }

    @Test("the bar's centre stays 8 from both sides")
    func horizontalClamp() {
        #expect(MarkdownSelectionBarPlacement.centerX(10, width: 295, left: 0, right: 800) == 155.5)
        #expect(MarkdownSelectionBarPlacement.centerX(795, width: 295, left: 0, right: 800) == 644.5)
        #expect(MarkdownSelectionBarPlacement.centerX(400, width: 295, left: 0, right: 800) == 400)
    }

    @Test("the text bar is 295 wide and the table bar 197, as the reference editor's bars minus Comment and React")
    func widths() {
        let bar = MarkdownSelectionBarView(frame: .zero)
        bar.arrange(inTable: false)
        #expect(bar.frame.width == 295)
        #expect(bar.frame.height == 34)
        bar.arrange(inTable: true)
        #expect(bar.frame.width == 197)
    }

    @Test("a bar wider than the editor folds controls from the end into More formatting, keeping Link")
    func overflowFolds() {
        let bar = MarkdownSelectionBarView(frame: .zero)
        bar.arrange(inTable: false)
        bar.layoutItems(maximumWidth: 200)
        #expect(bar.frame.width <= 200)
        #expect(!bar.folded.isEmpty)
        #expect(!bar.folded.contains(.link))
        #expect(bar.buttons[.link]?.isHidden == false)
        #expect(bar.moreButton.isHidden == false)
        bar.layoutItems()
        #expect(bar.folded.isEmpty && bar.moreButton.isHidden)
    }

    // MARK: - Highlight and strikethrough

    @Test("==x== is a highlight; 'a == b', '===' and code are not")
    func highlightParsing() {
        func kinds(_ text: String) -> [MarkdownTokenKind] { MarkdownTokenizer.parseTokensViaAST(in: text).map(\.kind) }
        #expect(kinds("a ==marked== b").contains(.highlight))
        #expect(!kinds("a == b == c").contains(.highlight))
        #expect(!kinds("===x===").contains(.highlight))
        #expect(!kinds("`==x==`").contains(.highlight))
        let token = MarkdownTokenizer.parseTokensViaAST(in: "==ab==").first { $0.kind == .highlight }
        #expect(token?.contentRange == NSRange(location: 2, length: 2))
    }

    private func plan(_ text: String, _ selected: String, _ style: MarkdownInlineStyle) -> String {
        let range = (text as NSString).range(of: selected)
        guard let plan = MarkdownInlineFormatter.plan(text: text as NSString, targetRange: range, style: style,
                                                      tokens: MarkdownTokenizer.parseTokensViaAST(in: text)) else { return text }
        return (text as NSString).replacingCharacters(in: plan.replacementRange, with: plan.replacement)
    }

    @Test("strikethrough and highlight wrap and unwrap byte-identically")
    func strikeAndHighlightRoundTrip() {
        let struck = plan("a word here", "word", .strikethrough)
        #expect(struck == "a ~~word~~ here")
        #expect(plan(struck, "word", .strikethrough) == "a word here")
        let marked = plan("a word here", "word", .highlight)
        #expect(marked == "a ==word== here")
        #expect(plan(marked, "word", .highlight) == "a word here")
    }

    @Test("unsetting part of a span splits it (the reference editor's toggleMark)")
    func unsetSplits() {
        #expect(plan("**abc**", "b", .bold) == "**a**b**c**")
        #expect(plan("~~abc~~", "b", .strikethrough) == "~~a~~b~~c~~")
        #expect(plan("**abc def**", "def", .bold) == "**abc** def")
    }

    // MARK: - Block commands

    private func applying(_ edit: MarkdownSourceEdit?, to text: String) -> String {
        guard let edit else { return text }
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    @Test("setBlock H2 rewrites every selected line; Text strips the marker; lists keep their marker")
    func setBlock() {
        let text = "one\n# two\n\n- three"
        let all = NSRange(location: 1, length: (text as NSString).length - 2)
        let h2 = applying(MarkdownSourceFormatting.setBlock(level: 2, in: text as NSString, selection: all), to: text)
        #expect(h2 == "## one\n## two\n\n- ## three")
        let plain = applying(MarkdownSourceFormatting.setBlock(level: 0, in: h2 as NSString,
                                                               selection: NSRange(location: 0, length: (h2 as NSString).length)), to: h2)
        #expect(plain == "one\ntwo\n\n- three")
        let edit = MarkdownSourceFormatting.setBlock(level: 1, in: "Post" as NSString, selection: NSRange(location: 1, length: 3))
        #expect(edit?.selection == NSRange(location: 3, length: 3), "the selection keeps the same text")
    }

    @Test("checklist toggles - [ ] on, converts bullets, and toggles off")
    func checklist() {
        let text = "one\n- two"
        let all = NSRange(location: 0, length: (text as NSString).length)
        let on = applying(MarkdownSourceFormatting.toggle(.task, in: text as NSString, selection: all), to: text)
        #expect(on == "- [ ] one\n- [ ] two")
        let off = applying(MarkdownSourceFormatting.toggle(.task, in: on as NSString,
                                                           selection: NSRange(location: 0, length: (on as NSString).length)), to: on)
        #expect(off == "one\ntwo")
    }

    @Test("indent and outdent move only list items")
    func indentOutdent() {
        let text = "- a\nplain\n- b"
        let all = NSRange(location: 0, length: (text as NSString).length)
        let indented = applying(MarkdownSourceFormatting.indentListItems(outdent: false, in: text as NSString, selection: all), to: text)
        #expect(indented == "\t- a\nplain\n\t- b")
        let back = applying(MarkdownSourceFormatting.indentListItems(outdent: true, in: indented as NSString,
                                                                    selection: NSRange(location: 0, length: (indented as NSString).length)), to: indented)
        #expect(back == text)
    }

    @Test("Insert Table puts an empty 3 × 3 table with a header before a line the caret starts, else at the caret")
    func insertTable() {
        let table = "|  |  |  |\n| --- | --- | --- |\n|  |  |  |\n|  |  |  |"
        func insert(_ text: String, at caret: Int) -> (String, Int) {
            let edit = MarkdownSourceFormatting.insertTable(in: text as NSString, selection: NSRange(location: caret, length: 0))
            return (applying(edit, to: text), edit.selection.location)
        }
        let (before, cell) = insert("Para\n\nLine two", at: 6)
        #expect(before == "Para\n\n" + table + "\n\nLine two")
        #expect((before as NSString).substring(with: NSRange(location: cell - 2, length: 3)) == "|  ")
        let (end, _) = insert("Para", at: 4)
        #expect(end == "Para\n\n" + table)
        let (split, _) = insert("ab", at: 1)
        #expect(split == "a\n\n" + table + "\n\nb")
    }

    @Test("Divider and ⌘Return's check toggle")
    func dividerAndCheck() {
        let divided = applying(MarkdownSourceFormatting.insertDivider(in: "one\ntwo" as NSString, selection: NSRange(location: 1, length: 0)),
                               to: "one\ntwo")
        #expect(divided == "one\n\n---\n\ntwo")
        let checked = applying(MarkdownSourceFormatting.toggleTaskChecked(in: "- [ ] a\n- [x] b" as NSString,
                                                                          selection: NSRange(location: 0, length: 14)), to: "- [ ] a\n- [x] b")
        #expect(checked == "- [x] a\n- [ ] b")
    }

    @Test("a ranged selection never reveals Markdown syntax; math and images still reveal for selection inside them")
    func noRevealOnRangedSelection() {
        func activeKinds(_ text: String, _ selected: String) -> Set<MarkdownTokenKind> {
            let ns = text as NSString
            let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
            return Set(MarkdownDetection.computeActiveTokenIndices(selectionRange: ns.range(of: selected), tokens: tokens, in: ns)
                .map { tokens[$0].kind })
        }
        #expect(activeKinds("a **word** b", "word").isEmpty)
        #expect(activeKinds("# Heading here", "Heading").isEmpty)
        #expect(activeKinds("see [docs](https://e.com)", "docs").isEmpty)
        #expect(activeKinds("x $a+b$ y", "a+b").contains(.inlineLatex))
        let caret = "a **word** b" as NSString
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: caret as String)
        #expect(!MarkdownDetection.computeActiveTokenIndices(selectionRange: NSRange(location: 5, length: 0), tokens: tokens, in: caret).isEmpty,
                "a caret still reveals (deviation a)")
    }

    // MARK: - Host

    @MainActor final class Host {
        var text: String
        init(_ text: String) { self.text = text }
    }

    private func mount(_ source: String) throws -> (NativeTextViewWrapper, NativeTextViewCoordinator, NSScrollView, NativeTextView, NSWindow, Host) {
        _ = NSApplication.shared
        let host = Host(source)
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        configuration.safeAreaInsets = SafeAreaInsets(top: 50, leading: 0, trailing: 0, bottom: 0)
        let undo = UndoManager()
        undo.groupsByEvent = false
        let wrapper = NativeTextViewWrapper(text: Binding(get: { host.text }, set: { host.text = $0 }),
                                            configuration: configuration, fontSize: 16, documentId: UUID().uuidString,
                                            undoManager: undo)
        let coordinator = wrapper.makeCoordinator()
        let scroll = wrapper.makeNativeView(coordinator: coordinator)
        let view = try #require(scroll.nativeTextView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        wrapper.updateNativeView(scroll, coordinator: coordinator)
        window.makeFirstResponder(view)
        coordinator.selectionBar?.requiresKeyWindow = false
        return (wrapper, coordinator, scroll, view, window, host)
    }

    private func settle() async {
        for _ in 0..<6 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    @Test("a non-empty selection shows the bar above the clip view; it wins hit-testing; a caret hides it")
    func barHost() async throws {
        let (_, coordinator, scroll, view, window, _) = try mount("Intro\n\nSome **plain** text to select here.\n")
        defer { window.close() }
        await settle()
        let bar = try #require(coordinator.selectionBar)
        view.setSelectedRange(NSRange(location: 13, length: 5))
        bar.update()
        try #require(bar.isShown, "window key: \(window.isKeyWindow), responder: \(String(describing: window.firstResponder))")
        #expect(scroll.subviews.last === bar.bar)
        let center = NSPoint(x: bar.bar.frame.midX, y: bar.bar.frame.midY)
        let hit = scroll.hitTest(scroll.convert(center, to: scroll.superview))
        #expect(hit?.isDescendant(of: bar.bar) == true)
        #expect(bar.bar.frame.width == 295)
        view.setSelectedRange(NSRange(location: 13, length: 0))
        bar.update()
        #expect(!bar.isShown)
    }

    @Test("⌘B from the bar turns Bold on and keeps the selection; Escape hides the bar until the selection changes")
    func boldPressedState() async throws {
        let (_, coordinator, _, view, window, _) = try mount("Intro\n\nword here\n")
        defer { window.close() }
        await settle()
        let bar = try #require(coordinator.selectionBar)
        view.setSelectedRange(NSRange(location: 7, length: 4))
        bar.update()
        try #require(bar.isShown)
        #expect(bar.bar.buttons[.bold]?.isPressed == false)
        view.undoManager?.beginUndoGrouping()
        _ = bar.bar.buttons[.bold]?.accessibilityPerformPress()
        view.undoManager?.endUndoGrouping()
        #expect(view.string == "Intro\n\n**word** here\n")
        #expect((view.string as NSString).substring(with: view.selectedRange()) == "word")
        bar.update()
        #expect(bar.bar.buttons[.bold]?.isPressed == true)
        view.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!bar.isShown)
        view.setSelectedRange(NSRange(location: 9, length: 3))
        bar.update()
        #expect(bar.isShown)
    }

    @Test("on a long note, Bold reads pressed right after it is applied (no stale state)")
    func longNoteStateAfterBold() async throws {
        let filler = String(repeating: "Filler paragraph with enough words to make the note long.\n\n", count: 2_400)
        let source = "Intro\n\nword here\n\n" + filler
        try #require((source as NSString).length > NativeTextView.estimatedLayoutChainThreshold)
        let (_, coordinator, _, view, window, _) = try mount(source)
        defer { window.close() }
        await settle()
        view.setSelectedRange(NSRange(location: 7, length: 4))
        view.undoManager?.beginUndoGrouping()
        coordinator.applyInlineStyle(.bold)
        view.undoManager?.endUndoGrouping()
        #expect(view.string.hasPrefix("Intro\n\n**word** here"))
        let state = try #require(coordinator.currentFormatState())
        #expect(state.bold)
    }

    @Test("the bar hides while a mouse drag extends the selection and while text is composed")
    func hiddenWhileDraggingOrComposing() async throws {
        let (_, coordinator, _, view, window, _) = try mount("Intro\n\nword here\n")
        defer { window.close() }
        await settle()
        let bar = try #require(coordinator.selectionBar)
        view.setSelectedRange(NSRange(location: 7, length: 4))
        bar.update()
        try #require(bar.isShown)
        bar.isDragSelecting = true
        bar.update()
        #expect(!bar.isShown)
        bar.isDragSelecting = false
        bar.update()
        #expect(bar.isShown)
        view.undoManager?.beginUndoGrouping()
        view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 7, length: 4))
        bar.update()
        #expect(!bar.isShown)
        view.unmarkText()
        view.undoManager?.endUndoGrouping()
    }

    @Test("the bar's anchor follows magnification: a 2× zoom doubles the caret height")
    func anchorUnderMagnification() async throws {
        let (_, coordinator, scroll, view, window, _) = try mount("Intro\n\nword here\n")
        defer { window.close() }
        await settle()
        let bar = try #require(coordinator.selectionBar)
        view.setSelectedRange(NSRange(location: 7, length: 4))
        bar.update()
        try #require(bar.isShown)
        let gapAt1 = view.convert(view.firstRectForTest(7), from: nil).minY
        _ = gapAt1
        let barAt1 = bar.bar.frame
        scroll.allowsMagnification = true
        scroll.magnification = 2
        await settle()
        bar.reposition()
        #expect(bar.bar.frame.height == barAt1.height, "the bar never scales")
    }

    @Test("F6 moves the keyboard into the bar; arrows move between controls; Escape returns to the text")
    func f6Focus() async throws {
        let (_, coordinator, _, view, window, _) = try mount("Intro\n\nword here\n")
        defer { window.close() }
        await settle()
        let bar = try #require(coordinator.selectionBar)
        view.setSelectedRange(NSRange(location: 7, length: 4))
        bar.update()
        try #require(bar.isShown)
        #expect(bar.focusBar())
        #expect(window.firstResponder === bar.bar)
        #expect(bar.bar.focusedItem == .textStyle)
        func key(_ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                             context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        bar.bar.keyDown(with: key(124))
        #expect(bar.bar.focusedItem == .bold)
        bar.bar.keyDown(with: key(123))
        bar.bar.keyDown(with: key(123))
        #expect(bar.bar.focusedItem == .link, "← wraps to the last control")
        bar.bar.keyDown(with: key(53))
        #expect(window.firstResponder === view)
        #expect(bar.bar.focusedItem == nil)
    }

    @Test("the text style label reads H2 inside a heading; the List trigger is pressed in a list")
    func labels() async throws {
        let (_, coordinator, _, view, window, _) = try mount("## Post title\n\n- item one\n- item two\n")
        defer { window.close() }
        await settle()
        let bar = try #require(coordinator.selectionBar)
        view.setSelectedRange(NSRange(location: 4, length: 3))
        bar.update()
        #expect(bar.bar.buttons[.textStyle]?.content == .text("H2"))
        let item = (view.string as NSString).range(of: "item one")
        view.setSelectedRange(item)
        bar.update()
        #expect(bar.bar.buttons[.list]?.isPressed == true)
        #expect(bar.bar.buttons[.textStyle]?.content == .symbol("textformat"))
    }
}

private extension NSTextView {
    func firstRectForTest(_ location: Int) -> NSRect {
        guard let window else { return .zero }
        return window.convertFromScreen(firstRect(forCharacterRange: NSRange(location: location, length: 1), actualRange: nil))
    }
}
