//
//  ImageObjectSelectionTests.swift
//  MarkdownEngineTests
//
//  An image is selected as a whole (doc 26 §3, §11.1, §13.2): a click, an
//  arrow, Find, Undo or a programmatic caret selects it without showing its
//  Markdown or moving the text below; its keys act on the whole image.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Image object selection", .serialized)
struct ImageObjectSelectionTests {
    static let images = [
        "wide.png": TestImages.solid(CGSize(width: 1_344, height: 672)),
        "clear.png": TestImages.solid(CGSize(width: 672, height: 336), color: .clear),
    ]
    /// Lines touch, so arrows step straight from text into the image and out.
    static let source = "Para above sits over the image\n![Chart|336](wide.png)\nPara below"
    static let tokenText = "![Chart|336](wide.png)"

    private func mounted(_ source: String = Self.source) async throws -> MountedImageEditor {
        let editor = try MountedImageEditor(source: source, images: Self.images)
        await editor.settle()
        return editor
    }

    private func range(of needle: String, in editor: MountedImageEditor) -> NSRange {
        (editor.main.string as NSString).range(of: needle)
    }

    /// The image on the line of `marker` is selected as a whole and still drawn.
    private func expectSelected(_ marker: String, in editor: MountedImageEditor,
                                sourceLocation: SourceLocation = #_sourceLocation) throws {
        let token = try editor.imageToken(onLineOf: marker)
        #expect(editor.coordinator.objectSelection?.token == token.range, sourceLocation: sourceLocation)
        #expect(editor.main.selectedRange() == token.range, sourceLocation: sourceLocation)
        let index = try #require(editor.coordinator.parsedDocument(for: editor.main.string).tokens.firstIndex { $0.range == token.range })
        #expect(!editor.coordinator.activeTokenIndices.contains(index), "the reveal pass skips it", sourceLocation: sourceLocation)
        #expect(try editor.isCollapsed(onLineOf: marker), "no Markdown shows", sourceLocation: sourceLocation)
    }

    // MARK: - Entering

    @Test("a click on a collapsed image selects it: no reveal, no layout shift, the ring around it")
    func clickSelects() async throws {
        let editor = try await mounted()
        defer { editor.close() }
        let below = try editor.lineTop(of: "Para below")
        let center = try editor.imageCenter(onLineOf: "![Chart")
        // The press, tracked to its mouse-up (a nested event loop would end the
        // test host; the image-select replay drives real window events).
        var queue = [try editor.mouseEvent(.leftMouseUp, at: center)]
        #expect(editor.main.routeMouseDownToBlocks(try editor.mouseEvent(.leftMouseDown, at: center)) {
            queue.isEmpty ? nil : queue.removeFirst()
        })
        try expectSelected("![Chart", in: editor)
        #expect(editor.window.firstResponder === editor.main)
        let storage = try #require(editor.main.textStorage)
        #expect(storage.attribute(.renderedBlockImage, at: try editor.imageAnchor(onLineOf: "![Chart"), effectiveRange: nil) != nil)
        await editor.settle()
        #expect(try editor.lineTop(of: "Para below") - below == 0)
        #expect(editor.main.string == Self.source)
        // The ring: 2 pt, 3 pt out from the image.
        let ring = try #require(editor.coordinator.imageChrome?.ring)
        let image = try #require(editor.main.renderedImageRect(at: try editor.imageAnchor(onLineOf: "![Chart")))
        #expect(!ring.isHidden && ring.superview === editor.main)
        #expect(ring.frame == image.insetBy(dx: -5, dy: -5))
        #expect(ring.hitTest(NSPoint(x: ring.frame.midX, y: ring.frame.midY)) == nil, "the ring takes no clicks")
    }

    @Test("double- and triple-clicks select the image as a click does")
    func multiClick() async throws {
        let editor = try await mounted()
        defer { editor.close() }
        let center = try editor.imageCenter(onLineOf: "![Chart")
        for count in [2, 3] {
            editor.main.setSelectedRange(NSRange(location: 0, length: 0))
            #expect(editor.main.routeMouseDownToBlocks(try editor.mouseEvent(.leftMouseDown, at: center, clickCount: count)) { nil })
            try expectSelected("![Chart", in: editor)
        }
    }

    @Test("an image drag presents once and yields remaining events without sweeping text")
    func dragKeepsSelection() async throws {
        let editor = try await mounted()
        defer { editor.close() }
        let center = try editor.imageCenter(onLineOf: "![Chart")
        let far = NSPoint(x: center.x + 40, y: center.y + 200)
        let down = try editor.mouseEvent(.leftMouseDown, at: center)
        let farDrag = try editor.mouseEvent(.leftMouseDragged, at: far)
        var queue = [try editor.mouseEvent(.leftMouseDragged, at: NSPoint(x: center.x + 1, y: center.y)),
                     farDrag, try editor.mouseEvent(.leftMouseUp, at: far)]
        var launch: (image: ObjectSelection, event: NSEvent, press: NSPoint)?
        var launches = 0
        var selectedAtLaunch: NSRange?
        let handled = editor.main.routeMouseDownToBlocks(down, dragPresenter: { image, event, press in
            launch = (image, event, press)
            launches += 1
            selectedAtLaunch = editor.main.selectedRange()
        }) { queue.isEmpty ? nil : queue.removeFirst() }
        #expect(handled)
        let presented = try #require(launch)
        let token = try editor.imageToken(onLineOf: "![Chart").range
        #expect(launches == 1)
        #expect(presented.image.token == token)
        #expect(presented.event === farDrag)
        #expect(presented.press == down.locationInWindow)
        #expect(selectedAtLaunch == token)
        #expect(queue.count == 1 && queue.first?.type == .leftMouseUp, "the presenter owns remaining mouse-up")
        try expectSelected("![Chart", in: editor)
        #expect(editor.main.string == Self.source)
        // Later fixtures pump AppKit's run loop. A replay records the OS boundary rather
        // than leaving a fabricated native drag for that unrelated turn to begin tracking.
        func pumpAppKit() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        pumpAppKit()
        let following = try await mounted("A later editor remains responsive")
        defer { following.close() }
        pumpAppKit()
        #expect(following.main.string == "A later editor remains responsive")
    }

    @Test("a click beside the image, on text, or with Shift is not the image's; a read-only editor selects nothing")
    func clicksElsewhere() async throws {
        let editor = try await mounted()
        defer { editor.close() }
        let image = try #require(editor.main.renderedImageRect(at: try editor.imageAnchor(onLineOf: "![Chart")))
        #expect(!editor.main.routeMouseDownToBlocks(try editor.mouseEvent(.leftMouseDown, at: NSPoint(x: image.maxX + 40, y: image.midY))) { nil })
        let text = try #require(editor.main.lineFrame(at: range(of: "Para below", in: editor).location))
        #expect(!editor.main.routeMouseDownToBlocks(try editor.mouseEvent(.leftMouseDown, at: NSPoint(x: text.minX + 5, y: text.midY))) { nil })
        #expect(!editor.main.routeMouseDownToBlocks(try editor.mouseEvent(.leftMouseDown, at: NSPoint(x: image.midX, y: image.midY),
                                                                         modifiers: .shift)) { nil })
        editor.main.isEditable = false
        #expect(!editor.main.routeMouseDownToBlocks(try editor.mouseEvent(.leftMouseDown, at: NSPoint(x: image.midX, y: image.midY))) { nil })
        #expect(editor.coordinator.objectSelection == nil)
    }

    @Test("↓ from the line above, ↑ from below, → at the end of the line above and ← at the start of the line below select the image")
    func arrowsSelect() async throws {
        let editor = try await mounted()
        defer { editor.close() }
        let below = try editor.lineTop(of: "Para below")
        let aboveEnd = range(of: "image\n", in: editor).location + 5
        let belowStart = range(of: "Para below", in: editor).location
        for (caret, key) in [(10, #selector(NSResponder.moveDown(_:))), (belowStart + 4, #selector(NSResponder.moveUp(_:))),
                             (aboveEnd, #selector(NSResponder.moveRight(_:))), (belowStart, #selector(NSResponder.moveLeft(_:)))] {
            editor.main.setSelectedRange(NSRange(location: caret, length: 0))
            #expect(editor.coordinator.objectSelection == nil)
            editor.press(key)
            try expectSelected("![Chart", in: editor)
            await editor.settle()
            #expect(try editor.lineTop(of: "Para below") - below == 0, "\(key)")
        }
        #expect(editor.main.string == Self.source)
    }

    @Test("↓ / → leave an image at the start of the next line, ↑ / ← at the end of the line before; nothing moves past the note's ends")
    func arrowsLeave() async throws {
        let editor = try await mounted()
        defer { editor.close() }
        let token = try editor.imageToken(onLineOf: "![Chart").range
        for (key, caret) in [(#selector(NSResponder.moveDown(_:)), NSMaxRange(token) + 1),
                             (#selector(NSResponder.moveRight(_:)), NSMaxRange(token) + 1),
                             (#selector(NSResponder.moveUp(_:)), token.location - 1),
                             (#selector(NSResponder.moveLeft(_:)), token.location - 1)] {
            editor.main.setSelectedRange(token)
            try expectSelected("![Chart", in: editor)
            editor.press(key)
            #expect(editor.main.selectedRange() == NSRange(location: caret, length: 0), "\(key)")
            #expect(editor.coordinator.objectSelection == nil)
            #expect(try editor.isCollapsed(onLineOf: "![Chart"))
        }

        let ends = try await mounted("![First|200](wide.png)\nmiddle\n![Last|200](wide.png)")
        defer { ends.close() }
        let first = try ends.imageToken(onLineOf: "![First").range
        ends.main.setSelectedRange(first)
        ends.press(#selector(NSResponder.moveUp(_:)))
        try expectSelected("![First", in: ends)
        let last = try ends.imageToken(onLineOf: "![Last").range
        ends.main.setSelectedRange(last)
        ends.press(#selector(NSResponder.moveDown(_:)))
        try expectSelected("![Last", in: ends)
    }

    @Test("↓ from an image onto an image right below selects the second")
    func twoImagesInARow() async throws {
        let editor = try await mounted("Top\n![One|200](wide.png)\n![Two|200](wide.png)\nBottom")
        defer { editor.close() }
        editor.main.setSelectedRange(try editor.imageToken(onLineOf: "![One").range)
        editor.press(#selector(NSResponder.moveDown(_:)))
        try expectSelected("![Two", in: editor)
        editor.press(#selector(NSResponder.moveUp(_:)))
        try expectSelected("![One", in: editor)
    }

    @Test("a programmatic caret in the token, a Find match in the alt text and the Undo of an alt edit select the image")
    func netCatchesEveryPath() async throws {
        let editor = try await mounted()
        defer { editor.close() }
        let token = try editor.imageToken(onLineOf: "![Chart").range
        editor.main.setSelectedRange(NSRange(location: token.location + 4, length: 0))
        try expectSelected("![Chart", in: editor)

        editor.main.setSelectedRange(NSRange(location: 0, length: 0))
        editor.main.setSelectedRange(range(of: "Chart", in: editor))   // what Find selects
        try expectSelected("![Chart", in: editor)

        // An alt edit (Phase 3's command shape) and its Undo.
        let alt = range(of: "Chart", in: editor)
        let edited = Self.source.replacingOccurrences(of: "Chart", with: "Graph")
        editor.state.undo.beginUndoGrouping()
        #expect(editor.coordinator.replaceSourceRanges([alt], with: "Graph", expectedSource: editor.main.string,
                                                       actionName: "Edit Alt Text", selectionAfter: token))
        editor.state.undo.endUndoGrouping()
        #expect(editor.main.string == edited)
        try expectSelected("![Graph", in: editor)
        editor.main.setSelectedRange(NSRange(location: 0, length: 0))
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
        try expectSelected("![Chart", in: editor)
        await editor.settle()
        try expectSelected("![Chart", in: editor)
    }

    @Test("an image that did not load keeps caret editing: its source shows")
    func unrenderedImage() async throws {
        let source = "Para above\n![Gone|center](missing.png)\nPara below"
        let editor = try await mounted(source)
        defer { editor.close() }
        let caret = NSRange(location: (source as NSString).range(of: "Gone").location + 2, length: 0)
        editor.main.setSelectedRange(caret)
        #expect(editor.coordinator.objectSelection == nil)
        #expect(editor.main.selectedRange() == caret)
        editor.press(#selector(NSResponder.moveDown(_:)))
        #expect(editor.coordinator.objectSelection == nil)
    }

    @Test("Backspace at the start of the next line and ⌦ at the end of the line before select the image; nothing is deleted")
    func backspaceSelects() async throws {
        let editor = try await mounted()
        defer { editor.close() }
        editor.main.setSelectedRange(NSRange(location: range(of: "Para below", in: editor).location, length: 0))
        editor.press(#selector(NSResponder.deleteBackward(_:)))
        try expectSelected("![Chart", in: editor)
        #expect(editor.main.string == Self.source)
        editor.main.setSelectedRange(NSRange(location: range(of: "image\n", in: editor).location + 5, length: 0))
        editor.press(#selector(NSResponder.deleteForward(_:)))
        try expectSelected("![Chart", in: editor)
        #expect(editor.main.string == Self.source)

        // With text, the line looks past one blank line; a blank line right after the image selects it too.
        let spaced = try await mounted("Above\n\n![Chart|336](wide.png)\n\nBelow")
        defer { spaced.close() }
        spaced.main.setSelectedRange(NSRange(location: (spaced.main.string as NSString).range(of: "Below").location, length: 0))
        spaced.press(#selector(NSResponder.deleteBackward(_:)))
        try expectSelected("![Chart", in: spaced)
        spaced.main.setSelectedRange(NSRange(location: NSMaxRange(try spaced.imageToken(onLineOf: "![Chart").range) + 1, length: 0))
        spaced.press(#selector(NSResponder.deleteBackward(_:)))
        try expectSelected("![Chart", in: spaced)
        #expect(spaced.main.string == "Above\n\n![Chart|336](wide.png)\n\nBelow")
    }

    // MARK: - Keys on a selected image

    @Test("Delete empties the image's line, caret on it, as one Undo step \"Delete Image\" that restores the selected image")
    func deleteImage() async throws {
        for key in [#selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)),
                    #selector(NSResponder.deleteWordBackward(_:))] {
            let source = "Para above\n  ![Chart|336](wide.png)\nPara below"
            let editor = try await mounted(source)
            defer { editor.close() }
            editor.main.setSelectedRange(try editor.imageToken(onLineOf: "![Chart").range)
            editor.press(key)
            #expect(editor.main.string == "Para above\n\nPara below", "the leading spaces go too; the break stays")
            #expect(editor.main.selectedRange() == NSRange(location: 11, length: 0))
            #expect(editor.coordinator.objectSelection == nil)
            #expect(editor.state.undo.undoActionName == "Delete Image")
            editor.state.undo.undo()
            #expect(editor.main.string == source)
            #expect(!editor.state.undo.canUndo, "one step")
            try expectSelected("![Chart", in: editor)
            await editor.settle()
            try expectSelected("![Chart", in: editor)
        }
    }

    @Test("typing replaces the image with the text in one Undo step")
    func typingReplaces() async throws {
        let editor = try await mounted()
        defer { editor.close() }
        editor.main.setSelectedRange(try editor.imageToken(onLineOf: "![Chart").range)
        editor.type("x")
        #expect(editor.main.string == Self.source.replacingOccurrences(of: Self.tokenText, with: "x"))
        #expect(editor.coordinator.objectSelection == nil)
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
        #expect(!editor.state.undo.canUndo)
        try expectSelected("![Chart", in: editor)
    }

    @Test("Tab, ⇧Tab and Escape change nothing; the image stays selected")
    func inertKeys() async throws {
        let editor = try await mounted()
        defer { editor.close() }
        editor.main.setSelectedRange(try editor.imageToken(onLineOf: "![Chart").range)
        for key in [#selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)),
                    #selector(NSResponder.cancelOperation(_:))] {
            editor.press(key)
            #expect(editor.main.string == Self.source, "\(key)")
            try expectSelected("![Chart", in: editor)
        }
        // Text formats do not wrap the image's Markdown.
        editor.state.undo.beginUndoGrouping()
        editor.coordinator.apply(.bold)
        editor.coordinator.applyInlineStyle(.italic)
        editor.coordinator.apply(.heading(level: 1))
        editor.state.undo.endUndoGrouping()
        #expect(editor.main.string == Self.source)
        try expectSelected("![Chart", in: editor)
    }

    @Test("Return makes a new paragraph after the image, caret on it")
    func returnAddsParagraph() async throws {
        let source = "Above\n\n![Chart|336](wide.png)\n\nBelow"
        let editor = try await mounted(source)
        defer { editor.close() }
        let token = try editor.imageToken(onLineOf: "![Chart").range
        editor.main.setSelectedRange(token)
        editor.press(#selector(NSResponder.insertNewline(_:)))
        #expect(editor.main.string == "Above\n\n![Chart|336](wide.png)\n\n\n\nBelow")
        #expect(editor.main.selectedRange() == NSRange(location: NSMaxRange(token) + 2, length: 0))
        #expect(editor.coordinator.objectSelection == nil)
        #expect(try editor.isCollapsed(onLineOf: "![Chart"))
        editor.type("Caption")
        #expect(editor.main.string == "Above\n\n![Chart|336](wide.png)\n\nCaption\n\nBelow")
    }

    @Test("⇧↓ and ⇧← extend a text range from the image's line: no reveal, the object selection ends")
    func shiftArrowsExtend() async throws {
        let editor = try await mounted()
        defer { editor.close() }
        let token = try editor.imageToken(onLineOf: "![Chart").range
        editor.main.setSelectedRange(token)
        editor.press(#selector(NSResponder.moveDownAndModifySelection(_:)))
        let down = editor.main.selectedRange()
        #expect(down.location <= token.location && NSMaxRange(down) > NSMaxRange(token), "past the token: \(down)")
        #expect(editor.coordinator.objectSelection == nil)
        #expect(try editor.isCollapsed(onLineOf: "![Chart"))

        editor.main.setSelectedRange(token)
        editor.press(#selector(NSResponder.moveLeftAndModifySelection(_:)))
        let left = editor.main.selectedRange()
        #expect(left.location == token.location - 1 && NSMaxRange(left) == NSMaxRange(token), "\(left)")
        #expect(editor.coordinator.objectSelection == nil)
        #expect(try editor.isCollapsed(onLineOf: "![Chart"))
        #expect(editor.main.string == Self.source)
    }

    @Test("selecting anything else ends the object selection and hides the ring")
    func leaving() async throws {
        let editor = try await mounted()
        defer { editor.close() }
        var writingTools: Int?
        if #available(macOS 15.0, *) { writingTools = editor.main.writingToolsBehavior.rawValue }
        editor.main.setSelectedRange(try editor.imageToken(onLineOf: "![Chart").range)
        let ring = try #require(editor.coordinator.imageChrome?.ring)
        #expect(!ring.isHidden)
        if #available(macOS 15.0, *) {
            #expect(editor.main.writingToolsBehavior == .none, "Writing Tools never rewrites the image's Markdown")
        }
        editor.main.selectAll(nil)
        #expect(editor.coordinator.objectSelection == nil)
        #expect(ring.isHidden)
        if #available(macOS 15.0, *) { #expect(editor.main.writingToolsBehavior.rawValue == writingTools, "restored") }
        #expect(try editor.isCollapsed(onLineOf: "![Chart"), "⌘A shows no Markdown")
        editor.main.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(editor.coordinator.objectSelection == nil)
    }

    @Test("an `![[…]]` embed is selected as a whole too")
    func embedSelects() async throws {
        let source = "Para above\n![[wide.png|300|center]]\nPara below"
        let editor = try await mounted(source)
        defer { editor.close() }
        let below = try editor.lineTop(of: "Para below")
        #expect(editor.main.routeMouseDownToBlocks(try editor.mouseEvent(.leftMouseDown, at: try editor.imageCenter(onLineOf: "![[wide"))) { nil })
        try expectSelected("![[wide", in: editor)
        editor.main.setSelectedRange(NSRange(location: 3, length: 0))
        editor.press(#selector(NSResponder.moveDown(_:)))
        try expectSelected("![[wide", in: editor)
        await editor.settle()
        #expect(try editor.lineTop(of: "Para below") == below)
    }

    @Test("a right-click on an image selects it before the menu")
    func rightClickSelects() async throws {
        let editor = try await mounted()
        defer { editor.close() }
        let event = try editor.mouseEvent(.rightMouseDown, at: try editor.imageCenter(onLineOf: "![Chart"))
        _ = editor.coordinator.textView(editor.main, menu: NSMenu(), for: event, at: 0)
        try expectSelected("![Chart", in: editor)
    }

    // MARK: - Paint, pointer, accessibility

    @Test("a transparent image, object-selected, shows no selection band; selected as text, it does")
    func selectionPaint() async throws {
        let source = "Para above\n![Clear](clear.png)\nPara below"
        let editor = try await mounted(source)
        defer { editor.close() }
        editor.window.makeFirstResponder(editor.main)
        let anchor = try editor.imageAnchor(onLineOf: "![Clear")
        let rect = try #require(editor.main.renderedImageRect(at: anchor))
        func centrePixels() throws -> [NSColor] {
            editor.main.displayIfNeeded()
            let bitmap = try editor.snapshot(rect)
            let scale = CGFloat(bitmap.pixelsWide) / rect.width
            return [(0.3, 0.3), (0.5, 0.5), (0.7, 0.6)].compactMap { fx, fy in
                bitmap.colorAt(x: Int(fx * rect.width * scale), y: Int(fy * rect.height * scale))?.usingColorSpace(.sRGB)
            }
        }
        // Control: selected as text (⌘A), the band shows through the transparent image.
        editor.main.selectAll(nil)
        let band = try centrePixels()
        try #require(band.count == 3 && band.allSatisfy { $0.alphaComponent > 0.5 && $0.brightnessComponent < 0.97 },
                     "the band shows through: \(band)")
        editor.main.setSelectedRange(try editor.imageToken(onLineOf: "![Clear").range)
        try expectSelected("![Clear", in: editor)
        for pixel in try centrePixels() {
            #expect(pixel.brightnessComponent > 0.99 && pixel.saturationComponent < 0.01, "page colour, no band: \(pixel)")
        }
    }

    @Test("the pointer over an image is an arrow in an editable note")
    func imageCursor() async throws {
        let editor = try await mounted()
        defer { editor.close() }
        let center = try editor.imageCenter(onLineOf: "![Chart")
        #expect(editor.main.applyImageCursor(for: try editor.mouseEvent(.mouseMoved, at: center)))
        let text = try #require(editor.main.lineFrame(at: 2))
        #expect(!editor.main.applyImageCursor(for: try editor.mouseEvent(.mouseMoved, at: NSPoint(x: text.minX + 4, y: text.midY))))
    }

    @Test("VoiceOver reads a selected image as its description and hears \"<description>, image\"")
    func accessibility() async throws {
        let source = "Para above\n![Q3 \\| 2024|center|336](wide.png)\nPara below"
        let editor = try await mounted(source)
        defer { editor.close() }
        MarkdownTableEditingSession.lastAnnouncement = nil
        editor.main.setSelectedRange(try editor.imageToken(onLineOf: "![Q3").range)
        #expect(editor.main.accessibilitySelectedText() == "Q3 | 2024")
        try await Task.sleep(for: .milliseconds(250))
        #expect(MarkdownTableEditingSession.lastAnnouncement == "Q3 | 2024, image")
        editor.main.setSelectedRange(NSRange(location: 2, length: 3))
        #expect(editor.main.accessibilitySelectedText() == "ra ")
    }
}
