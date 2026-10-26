import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Ordinary block dragging", .serialized)
struct OrdinaryBlockDragTests {
    private func source(for kind: String) -> String {
        switch kind {
        case "paragraph": "First line e\u{301} 😀\nSecond line"
        case "heading": "## Heading e\u{301} 😀"
        case "quote": "> Quoted line e\u{301} 😀\nLazy continuation\n> Another line\n>\n> > ```\n> > code\n> > ```\n>\n> paragraph\nlazy continuation"
        case "list": "- First e\u{301} 😀\n  continuation\n- [ ] Second\n  - Nested\n\n  Continued paragraph\n\n- Last"
        case "divider": "***"
        case "equation": "$$\na=b+c\n$$"
        default: "```swift\nlet value = 1\n```"
        }
    }

    @Test("ordinary blocks move and copy as exact whole blocks with Undo", arguments: ["paragraph", "heading", "quote", "list", "divider"])
    func moveAndCopy(_ rawKind: String) throws {
        let kind = try #require(BlockMovePasteboard.Kind(rawValue: rawKind))
        let block = source(for: rawKind)
        let original = "Lead\n\n" + block + "\n\nMiddle\n\nTail"
        let editor = try MountedTableEditor(source: original)
        defer { editor.close() }
        let range = (original as NSString).range(of: block)
        let payload = try #require(editor.coordinator.blockMovePayload(range: range, kind: kind))
        #expect(editor.coordinator.moveBlock(payload, to: (original as NSString).range(of: "Tail").location))
        let moved = "Lead\n\nMiddle\n\n" + block + "\n\nTail"
        #expect(editor.main.string.utf16.elementsEqual(moved.utf16))
        editor.state.undo.undo()
        #expect(editor.main.string.utf16.elementsEqual(original.utf16))
        #expect(!editor.state.undo.canUndo, "the whole move is one undo step")
        editor.state.undo.redo()
        #expect(editor.main.string.utf16.elementsEqual(moved.utf16))
        editor.state.undo.undo()
        #expect(editor.coordinator.moveBlock(payload, to: 0, copying: true))
        #expect(editor.main.string.utf16.elementsEqual((block + "\n\n" + original).utf16))
        editor.state.undo.undo()
        #expect(editor.main.string.utf16.elementsEqual(original.utf16))
    }

    @Test("native grips receive hits inside the top inset without covering heading fold controls", arguments: ["paragraph", "heading", "quote", "list", "divider", "code", "equation"])
    func nativeGrips(_ rawKind: String) async throws {
        let kind = try #require(BlockMovePasteboard.Kind(rawValue: rawKind))
        let block = source(for: rawKind)
        let original = "Lead\n\n" + block + "\n\nFollowing paragraph\n\nTail"
        for pageLook in [false, true] {
            var configuration = MarkdownEditorConfiguration.default
            configuration.showsSelectionBar = true
            configuration.textInsets = TextInsets(horizontal: 24, vertical: 0)
            configuration.readingWidth = pageLook ? 672 : nil
            configuration.safeAreaInsets = SafeAreaInsets(top: 90, leading: 0, trailing: 0, bottom: 0)
            let editor = try MountedTableEditor(source: original, configuration: configuration)
            defer { editor.close() }
            editor.window.setContentSize(NSSize(width: 1000, height: 650))
            await editor.settle()
            // Scroll the visible block into the reserved top band. AppKit's
            // clip view otherwise draws this content but refuses its hits.
            editor.scroll.contentView.scroll(to: .zero)
            editor.scroll.reflectScrolledClipView(editor.scroll.contentView)
            editor.main.textLayoutManager?.textViewportLayoutController.layoutViewport()
            let layout = try #require(editor.main.textLayoutManager)
            let content = try #require(layout.textContentManager)
            let range = (original as NSString).range(of: block)
            let location = try #require(content.location(layout.documentRange.location, offsetBy: range.location))
            let fragment = try #require(layout.textLayoutFragment(for: location))
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: editor.main.textContainerOrigin.x, dy: editor.main.textContainerOrigin.y)
            let mover = editor.coordinator.blockMover
            mover.hover(at: NSPoint(x: frame.minX + 35, y: frame.minY + 8))
            let entry = try #require(mover.hovered)
            #expect(entry.kind == kind)
            #expect(entry.range == range, "a grip owns the complete container, including continuations")
            let point = NSPoint(x: entry.grip.midX, y: entry.grip.midY)
            let windowPoint = editor.main.convert(point, to: nil)
            let root = try #require(editor.window.contentView)
            let hit = root.hitTest(root.superview?.convert(windowPoint, from: nil) ?? windowPoint)
            #expect(hit?.accessibilityLabel() == "Drag to move " + kind.title.lowercased(),
                    "the rendered grip must receive the native hit in layout \(pageLook)")
            #expect(editor.main.string.utf16.elementsEqual(original.utf16))
            #expect(!editor.state.undo.canUndo)
            let slots = editor.main.dropSlotsNearViewport(movingBlocks: true).map(\.offset)
            #expect(!slots.contains { $0 > range.location && $0 < NSMaxRange(range) },
                    "drop slots must not split a whole container")
        }
    }

    @Test("heading grips align vertically with native fold chevrons", arguments: 1...6)
    func headingGripAlignment(_ level: Int) async throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        let source = String(repeating: "#", count: level) + " A heading long enough to wrap across several lines in this window\n\nBody"
        let editor = try MountedTableEditor(source: source, configuration: configuration)
        defer { editor.close() }
        await editor.settle()
        for collapsed in [false, true] {
            if collapsed {
                #expect(editor.coordinator.performFolding(.toggleFold, heading: 0))
                await editor.settle()
            }
            editor.coordinator.foldControls?.refresh()
            let chevron = try #require(editor.coordinator.foldControls?.accessibilityControls.first {
                $0.accessibilityRole() == .disclosureTriangle
            })
            let origin = editor.main.textContainerOrigin
            editor.coordinator.blockMover.hover(at: NSPoint(x: origin.x + 35, y: chevron.frame.midY))
            let entry = try #require(editor.coordinator.blockMover.hovered)
            #expect(entry.kind == .heading)
            #expect(abs(entry.grip.midY - chevron.frame.midY) < 0.5,
                    "drag grip and chevron share a visual center at heading level \(level), collapsed \(collapsed)")
            #expect(!entry.grip.intersects(chevron.frame))
        }
        #expect(editor.main.string == source)
        #expect(!editor.state.undo.canUndo)
    }

    @Test("heading controls reveal together only on hover or keyboard focus", arguments: [false, true])
    func headingControlsHover(_ collapsed: Bool) async throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        let source = "# Heading\n\nBody\n\n# Next\n\nTail"
        let editor = try MountedTableEditor(source: source, configuration: configuration)
        defer { editor.close() }
        await editor.settle()
        if collapsed {
            #expect(editor.coordinator.performFolding(.toggleFold, heading: 0))
            await editor.settle()
        }
        editor.coordinator.foldControls?.refresh()
        let chevron = try #require(editor.coordinator.foldControls?.accessibilityControls.first {
            $0.accessibilityRole() == .disclosureTriangle
        })
        func hasInk() throws -> Bool {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 24,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            context.cgContext.clear(chevron.bounds)
            chevron.draw(chevron.bounds)
            return (0..<24).contains { y in
                (0..<24).contains { x in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01 }
            }
        }
        func move(to point: NSPoint) throws {
            let event = try #require(NSEvent.mouseEvent(with: .mouseMoved,
                location: editor.main.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: editor.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            editor.main.mouseMoved(with: event)
        }
        let mover = editor.coordinator.blockMover
        mover.hide()
        #expect(try !hasInk(), "a caret in the heading does not pin its chevron")
        try move(to: NSPoint(x: editor.main.textContainerOrigin.x + 35, y: chevron.frame.midY))
        let heading = try #require(mover.hovered)
        #expect(heading.kind == .heading)
        for point in [NSPoint(x: heading.grip.midX, y: heading.grip.midY),
                      NSPoint(x: chevron.frame.midX, y: chevron.frame.midY)] {
            try move(to: point)
            #expect(mover.hovered?.range == heading.range)
            #expect(try hasInk(), "both controls stay visible across their shared gutter")
        }
        try move(to: NSPoint(x: editor.main.bounds.maxX + 100, y: chevron.frame.midY))
        #expect(mover.hovered == nil)
        #expect(try !hasInk(), "collapsed headings also hide their chevron when hover leaves")
        #expect(editor.window.makeFirstResponder(chevron))
        #expect(try hasInk(), "keyboard focus keeps the folding action visible")
        #expect(editor.main.string == source)
        #expect(!editor.state.undo.canUndo)
    }

    @Test("the top inset forwards visible text but preserves blank space and scrollbars")
    func insetHitBoundaries() async throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        configuration.safeAreaInsets = SafeAreaInsets(top: 90, leading: 0, trailing: 0, bottom: 0)
        let editor = try MountedTableEditor(source: String(repeating: "Paragraph with text.\n\n", count: 100), configuration: configuration)
        defer { editor.close() }
        // A real host can place the scroll view away from its parent's origin.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 650))
        editor.window.contentView = host
        editor.scroll.frame = NSRect(x: 31, y: 23, width: 360, height: 580)
        host.addSubview(editor.scroll)
        await editor.settle()
        let root = try #require(editor.window.contentView)
        func hit(_ point: NSPoint) -> NSView? {
            let windowPoint = editor.main.convert(point, to: nil)
            return root.hitTest(root.superview?.convert(windowPoint, from: nil) ?? windowPoint)
        }
        editor.scroll.contentView.scroll(to: .zero)
        editor.scroll.reflectScrolledClipView(editor.scroll.contentView)
        #expect(hit(NSPoint(x: editor.main.textContainerOrigin.x + 40, y: 8)) === editor.main)
        editor.scroll.contentView.scroll(to: NSPoint(x: 0, y: -90))
        editor.scroll.reflectScrolledClipView(editor.scroll.contentView)
        #expect(hit(NSPoint(x: editor.main.textContainerOrigin.x + 40, y: -70)) === editor.scroll,
                "empty clearance before the document must not become a text hit")
        let scroller = try #require(editor.scroll.verticalScroller)
        scroller.isHidden = false
        scroller.alphaValue = 1
        let center = scroller.convert(NSPoint(x: scroller.bounds.midX, y: scroller.bounds.midY), to: editor.main)
        #expect(hit(center) === scroller, "native scrollbar hits retain priority")
    }

    @Test("drag grips leave document text clickable at small side margins", arguments: [CGFloat(0), 24, 30])
    func textHitBesideGrip(_ margin: CGFloat) async throws {
        for readingWidth: CGFloat? in [nil, 672] {
            var configuration = MarkdownEditorConfiguration.default
            configuration.showsSelectionBar = true
            configuration.textInsets = TextInsets(horizontal: margin, vertical: 0)
            configuration.readingWidth = readingWidth
            let editor = try MountedTableEditor(source: "A paragraph to select\n\nTail", configuration: configuration)
            defer { editor.close() }
            editor.window.setContentSize(NSSize(width: 1000, height: 650))
            await editor.settle()
            let origin = editor.main.textContainerOrigin
            editor.coordinator.blockMover.hover(at: NSPoint(x: origin.x + 35, y: origin.y + 8))
            let entry = try #require(editor.coordinator.blockMover.hovered)
            #expect(entry.grip.maxX <= origin.x, "the whole grip belongs outside the text column")
            let root = try #require(editor.window.contentView)
            for x in [origin.x + 1, entry.grip.midX] {
                let point = editor.main.convert(NSPoint(x: x, y: origin.y + 8), to: nil)
                let hit = root.hitTest(root.superview?.convert(point, from: nil) ?? point)
                if x > origin.x { #expect(hit === editor.main) }
                else { #expect(hit?.accessibilityLabel() == "Drag to move paragraph") }
            }
        }
    }

    @Test("the first heading grip stays reachable with overlay scrollbars", arguments: [CGFloat(0), 90])
    func firstHeadingBesideScroller(_ topInset: CGFloat) async throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        configuration.textInsets = TextInsets(horizontal: 24, vertical: 0)
        configuration.safeAreaInsets = SafeAreaInsets(top: topInset, leading: 0, trailing: 0, bottom: 0)
        let source = "# First heading\n\n" + String(repeating: "Paragraph with text.\n\n", count: 100)
        let editor = try MountedTableEditor(source: source, configuration: configuration)
        defer { editor.close() }
        editor.scroll.scrollerStyle = .overlay
        await editor.settle()
        editor.scroll.flashScrollers()
        let scroller = try #require(editor.scroll.verticalScroller)
        scroller.alphaValue = 1
        scroller.isHidden = false
        let origin = editor.main.textContainerOrigin
        editor.coordinator.blockMover.hover(at: NSPoint(x: origin.x + 35, y: origin.y + 8))
        let grip = try #require(editor.coordinator.blockMover.hovered).grip
        let scrollerFrame = scroller.convert(scroller.bounds, to: editor.main)
        #expect(!grip.intersects(scrollerFrame), "scrollbar must not intercept any part of the grip")
        let root = try #require(editor.window.contentView)
        let point = editor.main.convert(NSPoint(x: grip.midX, y: grip.midY), to: nil)
        let hit = root.hitTest(root.superview?.convert(point, from: nil) ?? point)
        #expect(hit?.accessibilityLabel() == "Drag to move heading", "actual native hit: \(String(describing: hit))")
    }

    @Test("a narrow heading keeps its grip separate from source and folding", arguments: [false, true])
    func narrowHeadingGrip(_ pageLook: Bool) async throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        configuration.textInsets = TextInsets(horizontal: 0, vertical: 0)
        configuration.readingWidth = pageLook ? 672 : nil
        let source = "## " + String(repeating: "Long heading ", count: 12) + "\n\nBody"
        let editor = try MountedTableEditor(source: source, configuration: configuration)
        defer { editor.close() }
        await editor.settle()
        let origin = editor.main.textContainerOrigin
        editor.coordinator.blockMover.hover(at: NSPoint(x: origin.x + 35, y: origin.y + 8))
        let entry = try #require(editor.coordinator.blockMover.hovered)
        #expect(entry.kind == .heading)
        #expect(!entry.grip.intersects(entry.rect))
        let fold = NSRect(x: max(0, origin.x - 30), y: entry.grip.minY, width: 24, height: 24)
        #expect(!entry.grip.intersects(fold))
        let root = try #require(editor.window.contentView)
        let point = editor.main.convert(NSPoint(x: entry.grip.midX, y: entry.grip.midY), to: nil)
        let hit = root.hitTest(root.superview?.convert(point, from: nil) ?? point)
        #expect(hit?.accessibilityLabel() == "Drag to move heading")
    }

    @Test("a container ending in a heading leaves the following top-level paragraph alone", arguments: ["> Title\n> ===", "- Title\n  ===", "> > Title\n> > ===", "> # Heading", "> ---", "> ```\n> code", "> ```\n> - ```\n> plain", "- ```swift\n  code\n  ```", "> | A | B |\n> | --- | --- |\n> | 1 | 2 |", "- # Heading", "- Item\n\n  ```swift\n  let x = 1\n  ```"])
    func nonParagraphChild(_ block: String) async throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        let editor = try MountedTableEditor(source: block + "\nOutside\n\nTail", configuration: configuration)
        defer { editor.close() }
        await editor.settle()
        let mover = editor.coordinator.blockMover
        mover.hover(at: NSPoint(x: editor.main.textContainerOrigin.x + 35, y: editor.main.textContainerOrigin.y + 8))
        let entry = try #require(mover.hovered)
        #expect(entry.range == NSRange(location: 0, length: block.utf16.count))
        let payload = try #require(editor.coordinator.blockMovePayload(range: entry.range, kind: entry.kind))
        #expect(editor.coordinator.moveBlock(payload, to: (editor.main.string as NSString).range(of: "Tail").location))
        #expect(editor.main.string == "Outside\n\n" + block + "\n\nTail")
    }

    @Test("ordered list padding does not absorb an outside paragraph", arguments: ["1. First", "10. First", "-    First"])
    func orderedListBoundary(_ block: String) async throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        let source = block + "\n\n  Outside\n\nTail"
        let editor = try MountedTableEditor(source: source, configuration: configuration)
        defer { editor.close() }
        await editor.settle()
        editor.coordinator.blockMover.hover(at: NSPoint(x: editor.main.textContainerOrigin.x + 35, y: editor.main.textContainerOrigin.y + 8))
        #expect(try #require(editor.coordinator.blockMover.hovered).range == NSRange(location: 0, length: block.utf16.count))
    }

    @Test("a list fence keeps a long blank child without consuming following content")
    func blankListChild() async throws {
        let block = "- ```swift\n" + String(repeating: "\n", count: 5_001) + "  code\n  ```"
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        let editor = try MountedTableEditor(source: block + "\nOutside\n\nTail", configuration: configuration)
        defer { editor.close() }
        await editor.settle()
        editor.coordinator.blockMover.hover(at: NSPoint(x: editor.main.textContainerOrigin.x + 35, y: editor.main.textContainerOrigin.y + 8))
        #expect(try #require(editor.coordinator.blockMover.hovered).range == NSRange(location: 0, length: block.utf16.count))
    }

    @Test("marked input hides native drop slots until committed")
    func compositionDropSlots() async throws {
        let editor = try MountedTableEditor(source: "- List\n\nTail")
        defer { editor.close() }
        await editor.settle()
        editor.state.undo.beginUndoGrouping()
        editor.main.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0),
                                  replacementRange: NSRange(location: 0, length: editor.main.string.utf16.count))
        #expect(editor.main.hasMarkedText())
        #expect(editor.main.dropSlotsNearViewport(movingBlocks: true).isEmpty)
        editor.main.unmarkText()
        editor.state.undo.endUndoGrouping()
    }

    @Test("typing cannot expose a truncated grip for a very long paragraph")
    func longParagraphAfterTyping() async throws {
        let block = String(repeating: "line\n", count: 5_001) + "last"
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        let editor = try MountedTableEditor(source: block + "\n\nTail", configuration: configuration)
        defer { editor.close() }
        await editor.settle()
        editor.state.undo.beginUndoGrouping()
        editor.main.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        editor.state.undo.endUndoGrouping()
        let mover = editor.coordinator.blockMover
        mover.hover(at: NSPoint(x: editor.main.textContainerOrigin.x + 35, y: editor.main.textContainerOrigin.y + 8))
        if let entry = mover.hovered {
            #expect(entry.range == NSRange(location: 0, length: block.utf16.count + 1),
                    "a pending index may hide the grip, but never advertise a partial source")
        }
        try await Task.sleep(for: .milliseconds(250))
        await editor.settle()
        mover.hover(at: NSPoint(x: editor.main.textContainerOrigin.x + 35, y: editor.main.textContainerOrigin.y + 8))
        #expect(try #require(mover.hovered).range == NSRange(location: 0, length: block.utf16.count + 1))
    }

    @Test("inactive code and rendered diagrams reveal a gutter handle on native hover", arguments: ["code", "diagram"])
    func inactiveFenceHover(_ kind: String) async throws {
        struct Diagram: BlockDiagramRenderer {
            func render(source: String, language: String, maxWidth: CGFloat,
                        fontSize: CGFloat, theme: MarkdownEditorTheme) -> DiagramRenderResult? {
                let size = CGSize(width: 240, height: 160)
                return DiagramRenderResult(image: NSImage(size: size), size: size)
            }
        }
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        configuration.services.diagram = Diagram()
        let code = "```swift\nlet value = 1\n```"
        let diagram = "```mermaid\nflowchart LR\n A --> B\n```"
        let source = "Lead\n\n" + code + "\n\n" + diagram + "\n\nTail"
        let editor = try MountedTableEditor(source: source, configuration: configuration)
        defer { editor.close() }
        editor.window.setContentSize(NSSize(width: 1000, height: 650))
        await editor.settle()
        let mover = editor.coordinator.blockMover
        let origin = editor.main.textContainerOrigin
        mover.hover(at: NSPoint(x: origin.x + 35, y: origin.y + 8))
        let gutterX = try #require(mover.hovered).grip.minX
        mover.hide()
        let selectedBefore = editor.main.selectedRange()
        let block = kind == "code" ? code : diagram
        let expectedRange = (source as NSString).range(of: block)
        let visual: NSRect
        if kind == "diagram" {
            let storage = try #require(editor.main.textStorage)
            var anchor: Int?
            storage.enumerateAttribute(.markdownBlockKind, in: expectedRange) { value, span, stop in
                if value as? String == "diagram" { anchor = span.location; stop.pointee = true }
            }
            let imageAnchor = try #require(anchor)
            visual = try #require(editor.main.renderedImageRect(at: imageAnchor))
        } else {
            let layout = try #require(editor.main.textLayoutManager)
            let content = try #require(layout.textContentManager)
            let offset = (source as NSString).range(of: "let value").location
            let location = try #require(content.location(layout.documentRange.location, offsetBy: offset))
            visual = try #require(layout.textLayoutFragment(for: location)).layoutFragmentFrame
                .offsetBy(dx: origin.x, dy: origin.y)
        }
        // The left side of the document row must work even when a centered
        // diagram starts much farther right. No click enters either fence.
        for point in [NSPoint(x: origin.x + 35, y: visual.midY), NSPoint(x: visual.midX, y: visual.midY)] {
            mover.hide()
            let windowPoint = editor.main.convert(point, to: nil)
            let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: windowPoint,
                modifierFlags: [], timestamp: 0, windowNumber: editor.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            editor.main.mouseMoved(with: event)
            let entry = try #require(mover.hovered)
            #expect(entry.kind.rawValue == kind)
            #expect(entry.range == expectedRange)
            #expect(entry.grip.minX == gutterX, "fenced blocks share the paragraph gutter")
            if kind == "diagram" { #expect(entry.rect == visual, "the drag preview keeps the rendered diagram bounds") }
            let root = try #require(editor.window.contentView)
            let gripPoint = editor.main.convert(NSPoint(x: entry.grip.midX, y: entry.grip.midY), to: nil)
            let hit = root.hitTest(root.superview?.convert(gripPoint, from: nil) ?? gripPoint)
            #expect(hit?.accessibilityLabel() == (kind == "code" ? "Drag to move code block" : "Drag to move diagram"))
        }
        #expect(editor.main.selectedRange() == selectedBefore)
        #expect(editor.main.string == source)
        #expect(!editor.state.undo.canUndo)
    }

    @Test("an image adjacent to prose retains its own grip")
    func imageInsideParagraph() async throws {
        struct Images: EmbeddedImageProvider {
            func image(for reference: EmbeddedImageRequest) -> NSImage? { NSImage(size: NSSize(width: 160, height: 80)) }
            func fingerprint() -> AnyHashable { "adjacent-image" }
        }
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        configuration.services.images = Images()
        let source = "Before\n![alt](pic.png)\nAfter\n\nTail"
        let editor = try MountedTableEditor(source: source, configuration: configuration)
        defer { editor.close() }
        await editor.settle()
        let range = (source as NSString).range(of: "![alt](pic.png)")
        editor.main.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        editor.coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: editor.main))
        await editor.settle()
        let storage = try #require(editor.main.textStorage)
        var anchor: Int?
        storage.enumerateAttribute(.renderedBlockImage, in: range) { value, span, stop in
            if value != nil { anchor = span.location; stop.pointee = true }
        }
        let imageAnchor = try #require(anchor)
        let rect = try #require(editor.main.renderedImageRect(at: imageAnchor))
        editor.coordinator.blockMover.hover(at: NSPoint(x: rect.midX, y: rect.midY))
        let entry = try #require(editor.coordinator.blockMover.hovered)
        #expect(entry.kind == .image)
        #expect(entry.range == range)
    }
}
