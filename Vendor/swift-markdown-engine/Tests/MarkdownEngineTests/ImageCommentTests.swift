import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Image comment UI", .serialized)
struct ImageCommentTests {
    @Test("image threads use an outside ring and keep their anchor through metadata edits")
    func imageComments() async throws {
        let source = "Before\n![Chart|336](wide.png)\nAfter"
        let editor = try MountedImageEditor(source: source, images: ["wide.png": TestImages.solid(CGSize(width: 640, height: 400))])
        defer { editor.close() }
        await editor.settle()
        editor.coordinator.configuration.showsSelectionBar = true
        editor.coordinator.reconcileSelectionBar(in: editor.scroll)
        let token = try editor.imageToken(onLineOf: "![")
        let anchor = MarkdownCommentAnchoring.anchor(for: token.range, in: source as NSString)
        let thread = MarkdownCommentThread(anchor: anchor.anchor, root: MarkdownComment(body: "Image note"))
        editor.state.controller.commentThreads = [thread]
        await editor.settle()
        let comments = try #require(editor.coordinator.comments)
        let paint = try #require(comments.paints(in: editor.main)[thread.id])
        #expect(paint.outline != nil)
        #expect(paint.outlineOffset == 3)
        #expect(paint.cornerRadius == 4)
        #expect(paint.alpha == 0)
        #expect(paint.rects == [try #require(editor.main.renderedImageRect(at: editor.imageAnchor(onLineOf: "![")))])
        #expect(MarkdownCommentsController.displayQuote("![Chart|336](wide.png)") == "[image]")
        editor.main.setSelectedRange(token.range)
        editor.coordinator.setImageAlignment(.right)
        editor.coordinator.setImageWidth(300, actionName: "Resize Image")
        editor.coordinator.setImageDescription("Updated chart")
        editor.coordinator.applyImageCrop(CGRect(x: 0, y: 0, width: 0.5, height: 1), fullWidth: 300)
        #expect(editor.state.controller.commentStore.ranges[thread.id] == editor.main.selectedRange())
        let saved = editor.state.controller.commentThreadsForSaving(text: editor.main.string)
        #expect(saved.first?.anchor.exact == "![Updated chart|right|crop=0,0,0.5,1|150](wide.png)")
        for _ in 0..<4 {
            editor.state.undo.undo()
            #expect(editor.state.controller.commentStore.ranges[thread.id] == editor.main.selectedRange())
        }
        #expect(editor.main.string == source)
        for _ in 0..<4 {
            editor.state.undo.redo()
            #expect(editor.state.controller.commentStore.ranges[thread.id] == editor.main.selectedRange())
        }
    }

    @Test("the image bar has six controls and crop entry leaves document layout fixed")
    func controlsAndOverlay() async throws {
        let bar = MarkdownSelectionBarView(frame: .zero)
        bar.showsComments = true
        bar.arrange(inTable: false, image: true)
        #expect(bar.frame.size == NSSize(width: 185, height: 34))
        #expect(bar.buttons[.crop]?.isHidden == false)
        #expect(bar.buttons[.alignCenter]?.isHidden == false)
        #expect(bar.buttons[.bold]?.isHidden == true)
        let editor = try MountedImageEditor(source: "Before\n![Chart|336](wide.png)\nAfter", images: ["wide.png": TestImages.solid(CGSize(width: 640, height: 400))])
        defer { editor.close() }
        await editor.settle()
        editor.main.setSelectedRange(try editor.imageToken(onLineOf: "![").range)
        editor.coordinator.configuration.showsSelectionBar = true
        editor.coordinator.reconcileSelectionBar(in: editor.scroll)
        editor.coordinator.selectionBar?.requiresKeyWindow = false
        editor.window.makeFirstResponder(editor.main)
        let before = try editor.lineTop(of: "After")
        let source = editor.main.string
        let controls = try #require(editor.coordinator.imageControls)
        controls.beginCrop()
        let crop = try #require(controls.cropView)
        #expect(editor.window.firstResponder === crop)
        #expect(crop.pixelReadout == "640 × 400")
        await editor.settle()
        #expect(try editor.lineTop(of: "After") == before)
        crop.close(applied: false)
        #expect(editor.main.string == source)
        #expect(controls.cropView == nil)
        #expect(editor.window.firstResponder === editor.main)
        #expect(editor.coordinator.selectionBar?.isShown == true)
    }
    @Test("a narrow image toolbar keeps its folded alignment actions available")
    func imageOverflow() async throws {
        let editor = try MountedImageEditor(source: "![Chart|right|336](wide.png)\nAfter", images: ["wide.png": TestImages.solid(CGSize(width: 640, height: 400))])
        defer { editor.close() }
        await editor.settle()
        editor.coordinator.configuration.showsSelectionBar = true
        editor.coordinator.reconcileSelectionBar(in: editor.scroll)
        editor.main.setSelectedRange(try editor.imageToken(onLineOf: "![").range)
        editor.window.makeFirstResponder(editor.main)
        let controller = try #require(editor.coordinator.selectionBar)
        controller.requiresKeyWindow = false
        controller.update()
        controller.bar.layoutItems(maximumWidth: 90)
        #expect(controller.bar.folded.contains(.alignLeft))
        #expect(controller.bar.moreButton.accessibilityPerformPress())
        let menu = try #require(editor.scroll.subviews.compactMap { $0 as? ChromeMenuView }.first)
        func key(_ code: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: editor.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
        menu.keyDown(with: try key(125))
        menu.keyDown(with: try key(36))
        #expect(editor.main.string == "![Chart|336](wide.png)\nAfter")
    }

}
