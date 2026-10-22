import AppKit
import Testing
@testable import MarkdownEngine

/// the reference editor's comment anchors in a mounted editor (doc 25 §3): they follow
/// real edits, detach when their text goes, and paint gold under the text.
@MainActor
@Suite("Comment highlights", .serialized)
struct CommentHighlightTests {
    static let source = "# Notes\n\nThe quick brown fox jumps over the lazy dog.\n\nAnother paragraph with brown words.\n"

    private func mount(_ source: String = CommentHighlightTests.source) throws -> MountedTableEditor {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        return try MountedTableEditor(source: source, configuration: configuration)
    }

    /// Types `text` over `range` as one Undo step (the harness groups by hand).
    private func type(_ text: String, over range: NSRange, in editor: MountedTableEditor) {
        editor.state.undo.beginUndoGrouping()
        editor.main.setSelectedRange(range)
        editor.main.insertText(text, replacementRange: range)
        editor.state.undo.endUndoGrouping()
    }

    private func thread(on quote: String, in source: String) -> MarkdownCommentThread {
        let text = source as NSString
        let made = MarkdownCommentAnchoring.anchor(for: text.range(of: quote), in: text)
        return MarkdownCommentThread(anchor: made.anchor, root: MarkdownComment(body: "Note"))
    }

    @Test("loaded threads find their text, and the highlight paints at rest under it")
    func loadsAndPaints() async throws {
        let editor = try mount()
        defer { editor.close() }
        let thread = thread(on: "brown fox", in: Self.source)
        editor.state.controller.commentThreads = [thread]
        await editor.settle()
        let store = editor.state.controller.commentStore
        #expect(store.ranges[thread.id] == (Self.source as NSString).range(of: "brown fox"))
        let comments = try #require(editor.coordinator.comments)
        let paint = try #require(comments.highlights.paints[thread.id])
        #expect(paint.alpha == CommentPalette.restAlpha && !paint.underlined)
        #expect(paint.rects.count == 1)
        #expect(editor.main.subviews.first === comments.highlights)
    }

    @Test("typing at the anchor's edges leaves it; typing inside grows it")
    func typingMapsTheAnchor() async throws {
        let editor = try mount()
        defer { editor.close() }
        let thread = thread(on: "brown fox", in: Self.source)
        editor.state.controller.commentThreads = [thread]
        await editor.settle()
        let store = editor.state.controller.commentStore
        let start = try #require(store.ranges[thread.id]).location
        type("very ", over: NSRange(location: start, length: 0), in: editor)
        #expect(store.ranges[thread.id] == NSRange(location: start + 5, length: 9))
        type("es", over: NSRange(location: start + 5 + 9, length: 0), in: editor)
        #expect(store.ranges[thread.id] == NSRange(location: start + 5, length: 9))
        type("red ", over: NSRange(location: start + 5 + 6, length: 0), in: editor)
        #expect(store.ranges[thread.id] == NSRange(location: start + 5, length: 13))
        await editor.settle()
        #expect(editor.main.string.contains("very brown red foxes"))
    }

    @Test("deleting all of the text detaches the thread; Undo does not re-attach it")
    func deletingDetaches() async throws {
        let editor = try mount()
        defer { editor.close() }
        let thread = thread(on: "brown fox", in: Self.source)
        editor.state.controller.commentThreads = [thread]
        await editor.settle()
        let store = editor.state.controller.commentStore
        let range = try #require(store.ranges[thread.id])
        type("", over: NSRange(location: range.location - 1, length: range.length + 2), in: editor)
        #expect(store.ranges[thread.id] == nil)
        #expect(store.isDetached(thread))
        editor.state.undo.undo()
        await editor.settle()
        #expect(editor.main.string.contains("brown fox"))
        #expect(store.ranges[thread.id] == nil)
        // Saving marks it detached for good.
        let saved = editor.state.controller.commentThreadsForSaving(text: editor.main.string)
        #expect(saved.first?.detached == true)
    }

    @Test("bolding the commented words keeps the comment on them")
    func formatKeepsAnchor() async throws {
        let editor = try mount()
        defer { editor.close() }
        let thread = thread(on: "brown fox", in: Self.source)
        editor.state.controller.commentThreads = [thread]
        await editor.settle()
        let store = editor.state.controller.commentStore
        editor.main.setSelectedRange(try #require(store.ranges[thread.id]))
        editor.state.undo.beginUndoGrouping()
        editor.coordinator.applyInlineStyle(.bold)
        editor.state.undo.endUndoGrouping()
        await editor.settle()
        #expect(editor.main.string.contains("**brown fox**"))
        let range = try #require(store.ranges[thread.id])
        #expect((editor.main.string as NSString).substring(with: range) == "brown fox")
    }

    @Test("the lit thread paints at 45 % and the open one is underlined")
    func litAndOpen() async throws {
        let editor = try mount()
        defer { editor.close() }
        let first = thread(on: "brown fox", in: Self.source)
        let second = thread(on: "brown words", in: Self.source)
        editor.state.controller.commentThreads = [first, second]
        await editor.settle()
        let store = editor.state.controller.commentStore
        let comments = try #require(editor.coordinator.comments)
        store.focusID = first.id
        comments.refresh()
        #expect(comments.highlights.paints[first.id]?.alpha == CommentPalette.activeAlpha)
        #expect(comments.highlights.paints[first.id]?.underlined == true)
        #expect(comments.highlights.paints[second.id]?.alpha == CommentPalette.restAlpha)
        // Hovering another thread takes the lit paint; the open one keeps its underline.
        store.activeID = second.id
        comments.refresh()
        #expect(comments.highlights.paints[second.id]?.alpha == CommentPalette.activeAlpha)
        #expect(comments.highlights.paints[first.id]?.alpha == CommentPalette.restAlpha)
        #expect(comments.highlights.paints[first.id]?.underlined == true)
        // Hidden comments paint nothing.
        store.mode = .hidden
        comments.refresh()
        #expect(comments.highlights.paints.isEmpty)
    }

    @Test("a host reload of the same text keeps every anchor")
    func reloadKeepsAnchors() async throws {
        let editor = try mount()
        defer { editor.close() }
        let thread = thread(on: "lazy dog", in: Self.source)
        editor.state.controller.commentThreads = [thread]
        await editor.settle()
        let edited = "A new first line.\n\n" + Self.source
        editor.state.text = edited
        editor.wrapper.updateNativeView(editor.scroll, coordinator: editor.coordinator)
        await editor.settle()
        let range = try #require(editor.state.controller.commentStore.ranges[thread.id])
        #expect((editor.main.string as NSString).substring(with: range) == "lazy dog")
    }

    @Test("a comment inside a code block is left showing through the block's fill")
    func codeBlockHoles() async throws {
        let source = "Intro.\n\n```\nlet answer = 42\n```\n\nOutro.\n"
        let editor = try mount(source)
        defer { editor.close() }
        let thread = thread(on: "answer", in: source)
        editor.state.controller.commentThreads = [thread]
        await editor.settle()
        let comments = try #require(editor.coordinator.comments)
        let range = try #require(editor.state.controller.commentStore.ranges[thread.id])
        #expect(comments.paintedRanges(intersecting: NSRange(location: 0, length: (source as NSString).length)) == [range])
        #expect(comments.codeBlockComments[thread.id] == range)
        editor.state.controller.commentStore.update(thread.id) { $0.resolved = true }
        await editor.settle()
        #expect(comments.codeBlockComments.isEmpty)
    }

    @Test("two overlapping threads compound as CSS spans do: 1 − 0.8² = 36 % gold over white")
    func overlapCompounds() throws {
        let view = CommentHighlightView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        view.appearance = NSAppearance(named: .aqua)
        view.apply([
            "a": .init(rects: [NSRect(x: 0, y: 0, width: 30, height: 20)], alpha: CommentPalette.restAlpha, underlined: false),
            "b": .init(rects: [NSRect(x: 10, y: 0, width: 30, height: 20)], alpha: CommentPalette.restAlpha, underlined: false),
        ], animated: false)
        let layer = try #require(view.layer)
        let context = try #require(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        layer.render(in: context)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        func pixel(_ x: Int) -> (Double, Double, Double) {
            let offset = 10 * context.bytesPerRow + x * 4
            return (Double(data[offset]), Double(data[offset + 1]), Double(data[offset + 2]))
        }
        // CSS: each span blends 20 % gold (#fab219) over what is under it.
        func over(_ base: Double, _ gold: Double) -> Double { 0.8 * base + 0.2 * gold }
        let one = (over(255, 250), over(255, 178), over(255, 25))
        let two = (over(one.0, 250), over(one.1, 178), over(one.2, 25))
        let single = pixel(5), double = pixel(20)
        #expect(abs(single.1 - one.1) <= 2 && abs(single.2 - one.2) <= 2, "one thread: \(single) vs \(one)")
        #expect(abs(double.1 - two.1) <= 2 && abs(double.2 - two.2) <= 2, "two threads: \(double) vs \(two)")
    }
}
